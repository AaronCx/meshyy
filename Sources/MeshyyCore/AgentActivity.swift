// meshyy — agent status from the output stream (design doc §4, §5.3, M5).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// A port of a+Terminal's `AgentActivityMonitor`, per design doc §4: "the agent
// detection logic lifted out of a+Terminal (AgentActivityMonitor, stripANSI,
// endsAtShellPrompt). One implementation, compiled for iOS and macOS."
//
// Two deliberate changes from the original, both recorded in docs/provenance.md:
//
//   1. No actor isolation. The original is `@MainActor`, which is right for a view
//      model and wrong for a daemon.
//   2. Time is a parameter, not `Task.sleep`. The original schedules a quiet timer;
//      here the caller advances the clock, so the burst/quiet heuristic is tested
//      deterministically instead of with sleeps. The daemon supplies the real clock.
//
// Agent identity stays DATA. The monitor is handed candidate profiles and never
// names one itself — that is what lets a new agent be a profile entry rather than
// a code change, and it is what makes §7.3's quick actions possible at all.

import Foundation

/// One agent meshyy knows how to recognise, and what can be answered in one tap.
public struct AgentProfile: Sendable, Equatable, Codable {
    /// Stable identifier, e.g. "claude-code".
    public var id: String
    /// What a UI calls it.
    public var displayName: String
    /// Substrings that identify this agent in the output. Matched
    /// case-insensitively against ANSI-stripped text. Empty means the generic
    /// profile: the heuristic runs but no name is claimed.
    public var detectionMarkers: [String]
    /// Quiet period after which sustained output is read as "waiting".
    public var quietInterval: Duration
    /// Bytes inside one quiet window that read as "working". A keystroke echo is a
    /// handful of bytes and never reaches this.
    public var burstThreshold: Int
    /// One-tap actions (design doc §7.3).
    public var quickActions: [QuickActionDefinition]

    public init(
        id: String,
        displayName: String,
        detectionMarkers: [String] = [],
        quietInterval: Duration = .seconds(2),
        burstThreshold: Int = 200,
        quickActions: [QuickActionDefinition] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.detectionMarkers = detectionMarkers
        self.quietInterval = quietInterval
        self.burstThreshold = burstThreshold
        self.quickActions = quickActions
    }

    /// The generic profile: run the heuristic, claim no name.
    public static let generic = AgentProfile(id: "generic", displayName: "Agent")

    // Duration is not Codable, so the interval crosses a profile file as
    // milliseconds. Spelled out rather than left to a custom Duration extension so
    // the JSON shape is obvious to anyone hand-writing a profile.
    enum CodingKeys: String, CodingKey {
        case id, displayName, detectionMarkers, quietIntervalMilliseconds
        case burstThreshold, quickActions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        detectionMarkers = try container.decodeIfPresent(
            [String].self, forKey: .detectionMarkers
        ) ?? []
        let milliseconds = try container.decodeIfPresent(
            Int.self, forKey: .quietIntervalMilliseconds
        ) ?? 2000
        quietInterval = .milliseconds(milliseconds)
        burstThreshold = try container.decodeIfPresent(Int.self, forKey: .burstThreshold) ?? 200
        quickActions = try container.decodeIfPresent(
            [QuickActionDefinition].self, forKey: .quickActions
        ) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(detectionMarkers, forKey: .detectionMarkers)
        try container.encode(Int(quietInterval.milliseconds), forKey: .quietIntervalMilliseconds)
        try container.encode(burstThreshold, forKey: .burstThreshold)
        try container.encode(quickActions, forKey: .quickActions)
    }
}

/// A one-tap action, as declared by a profile (design doc §7.3).
///
/// `sends` lives here — in local profile data — and deliberately never on the
/// wire. The daemon tells a client *which* actions are available by id and label;
/// what a tap actually sends comes from the client's own copy of this. Otherwise a
/// remote that draws a convincing fake permission prompt would get to choose the
/// keystrokes, which is a one-tap confused deputy.
public struct QuickActionDefinition: Sendable, Equatable, Codable {
    public var id: String
    public var label: String
    /// Substrings that must be present in the recent output for this action to be
    /// offered. All must match, so a profile can require both a prompt and its
    /// specific option.
    public var matches: [String]
    /// Bytes a tap sends — byte for byte what the user's own keystroke would send.
    public var sends: [UInt8]

    public init(id: String, label: String, matches: [String], sends: [UInt8]) {
        self.id = id
        self.label = label
        self.matches = matches
        self.sends = sends
    }

    /// The wire form: id and label only.
    public var advertised: QuickAction {
        QuickAction(id: id, label: label)
    }
}

/// Derives agent status from the output stream. Never inspects commands.
///
/// Heuristic, unchanged from a+Terminal: a sustained burst inside one quiet window
/// means **working**; quiet for the interval means **waiting**; and a quiet window
/// that ends at a bare shell prompt means the agent is gone, so status clears.
public struct AgentActivityMonitor: Sendable {
    public enum Status: String, Sendable, Equatable {
        case none
        case working
        case waiting
    }

    /// Bytes of raw tail kept for marker matching.
    static let markerTailBytes = 128
    /// Wider, because a prompt trails escape-heavy redraws.
    static let promptTailBytes = 256
    /// Wider still: a quick-action prompt is a multi-line block.
    static let actionTailBytes = 2048

    /// As the last non-whitespace character of the stripped tail, these read as a
    /// bare shell prompt. Conservative on purpose — an agent TUI never ends an idle
    /// frame with a bare POSIX terminator.
    public static let promptTerminators: Set<Character> = ["%", "$", "#"]

    public private(set) var status: Status = .none
    /// The profile whose marker matched, or an explicit pick. Drives the label.
    public private(set) var detected: AgentProfile?
    /// Actions currently offerable (design doc §7.3).
    public private(set) var offeredActions: [QuickActionDefinition] = []

    private let candidates: [AgentProfile]
    private let markerCandidates: [AgentProfile]
    private let explicitAgent: AgentProfile?
    /// The heuristic runs whenever ANY agent is configured, not only for the
    /// generic case. Inside a multiplexer, redraws splice escape codes through the
    /// text, so a marker like "esc to interrupt" rarely lands as a contiguous
    /// substring — which previously left a specific-agent session with no status
    /// for minutes, or ever.
    private let alwaysActive: Bool

    private var agentSeen: Bool
    private var burstBytes = 0
    private var lastOutputAt: ContinuousClock.Instant?
    private var carryBytes: [UInt8] = []
    private var promptTail: [UInt8] = []
    private var actionTail: [UInt8] = []

    public init(candidates: [AgentProfile]) {
        self.candidates = candidates
        markerCandidates = candidates.filter { !$0.detectionMarkers.isEmpty }
        let hasGeneric = candidates.contains { $0.detectionMarkers.isEmpty }
        alwaysActive = !candidates.isEmpty
        // Exactly one real agent and no generic fallback is an explicit pick, so its
        // name is known up front without waiting for a marker.
        explicitAgent = (!hasGeneric && markerCandidates.count == 1 && candidates.count == 1)
            ? markerCandidates[0]
            : nil
        agentSeen = !candidates.isEmpty
        detected = explicitAgent
    }

    private var activeQuiet: Duration { detected?.quietInterval ?? .seconds(2) }
    private var activeBurst: Int { detected?.burstThreshold ?? 200 }

    /// What changed, so a caller only emits frames when something actually moved.
    public struct Changes: Sendable, Equatable {
        public var status: Status?
        public var detected: AgentProfile??
        public var actions: [QuickActionDefinition]?

        public var isEmpty: Bool { status == nil && detected == nil && actions == nil }
    }

    /// Feeds output. `now` is the current instant; the caller owns the clock.
    public mutating func observe(_ bytes: [UInt8], now: ContinuousClock.Instant) -> Changes {
        promptTail = Array((promptTail + bytes).suffix(Self.promptTailBytes))
        actionTail = Array((actionTail + bytes).suffix(Self.actionTailBytes))
        lastOutputAt = now

        var changes = Changes()

        // Keep scanning until a named profile latches, so "Agent" upgrades to the
        // real name once a marker appears.
        if detected == nil, !markerCandidates.isEmpty, let match = scanForMarker(bytes) {
            detected = match
            agentSeen = true
            changes.detected = .some(match)
        }

        guard agentSeen else { return changes }

        burstBytes += bytes.count
        if status != .working, burstBytes >= activeBurst {
            status = .working
            changes.status = .working
        }

        if let updated = recomputeActions() { changes.actions = updated }
        return changes
    }

    /// Advances the clock with no output, which is how quiet is detected.
    public mutating func tick(now: ContinuousClock.Instant) -> Changes {
        var changes = Changes()
        guard let last = lastOutputAt, now - last >= activeQuiet else { return changes }

        burstBytes = 0
        lastOutputAt = now // one transition per quiet window, not one per tick

        guard status != .none else { return changes }

        if tailShowsIdleShellPrompt() {
            // The burst was a login banner, a MOTD, or a multiplexer redraw — or the
            // agent has exited. The session is sitting at a bare shell prompt, so
            // nothing is waiting for input. Clear, and un-latch a name the marker
            // scan may have picked up from banner text (an explicit pick keeps its
            // name).
            if detected != explicitAgent {
                detected = explicitAgent
                changes.detected = .some(explicitAgent)
            }
            status = .none
            changes.status = .none
            if !offeredActions.isEmpty {
                offeredActions = []
                changes.actions = []
            }
        } else if status == .working {
            status = .waiting
            changes.status = .waiting
        }
        return changes
    }

    /// Withdraws every offer and resets the burst window.
    ///
    /// Called on a full clear or an alt-screen transition (design doc §7.3): the
    /// text a match was based on is gone, so the offer must go with it.
    public mutating func screenChanged() -> Changes {
        actionTail = []
        promptTail = []
        guard !offeredActions.isEmpty else { return Changes() }
        offeredActions = []
        var changes = Changes()
        changes.actions = []
        return changes
    }

    public mutating func reset() {
        status = .none
        detected = explicitAgent
        agentSeen = alwaysActive
        burstBytes = 0
        lastOutputAt = nil
        carryBytes = []
        promptTail = []
        actionTail = []
        offeredActions = []
    }

    // MARK: - Matching

    /// Prefers the longest matching marker, so a chunk carrying markers for two
    /// agents names the one that matched most specifically rather than whichever
    /// profile happens to come first.
    private mutating func scanForMarker(_ bytes: [UInt8]) -> AgentProfile? {
        let text = Self.stripANSI(String(decoding: carryBytes + bytes, as: UTF8.self)).lowercased()
        var best: (candidate: AgentProfile, length: Int)?
        for candidate in markerCandidates {
            for marker in candidate.detectionMarkers where text.contains(marker.lowercased()) {
                if best == nil || marker.count > best!.length {
                    best = (candidate, marker.count)
                }
            }
        }
        if let best {
            carryBytes = []
            return best.candidate
        }
        // Carry a tail so a marker split across two reads is still reassembled.
        carryBytes = Array((carryBytes + bytes).suffix(Self.markerTailBytes))
        return nil
    }

    /// Recomputes offerable actions. Returns nil when nothing changed.
    private mutating func recomputeActions() -> [QuickActionDefinition]? {
        let profile = detected ?? candidates.first { !$0.quickActions.isEmpty }
        guard let profile, !profile.quickActions.isEmpty else {
            guard !offeredActions.isEmpty else { return nil }
            offeredActions = []
            return []
        }

        let haystack = Self.stripANSI(String(decoding: actionTail, as: UTF8.self)).lowercased()
        let matched = profile.quickActions.filter { action in
            !action.matches.isEmpty && action.matches.allSatisfy {
                haystack.contains($0.lowercased())
            }
        }
        guard matched != offeredActions else { return nil }
        offeredActions = matched
        return matched
    }

    private func tailShowsIdleShellPrompt() -> Bool {
        Self.endsAtShellPrompt(String(decoding: promptTail, as: UTF8.self))
    }

    /// True when the ANSI-stripped tail ends at a bare shell prompt.
    public static func endsAtShellPrompt(_ tail: String) -> Bool {
        let stripped = stripANSI(tail)
        guard let last = stripped.reversed().first(where: { !$0.isWhitespace }) else {
            return false
        }
        return promptTerminators.contains(last)
    }

    /// Removes CSI (`ESC [ … final`), OSC (`ESC ] … BEL` / `ESC \`) and
    /// two-character escapes, so matching sees what the user sees.
    public static func stripANSI(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var scalars = text.unicodeScalars[...]
        while let scalar = scalars.first {
            scalars = scalars.dropFirst()
            guard scalar.value == 0x1B else {
                result.append(scalar)
                continue
            }
            guard let introducer = scalars.first else { break }
            scalars = scalars.dropFirst()
            switch introducer {
            case "[":
                // CSI: skip parameter and intermediate bytes up to a final byte.
                while let byte = scalars.first {
                    scalars = scalars.dropFirst()
                    if (0x40...0x7E).contains(byte.value) { break }
                }
            case "]":
                // OSC: terminated by BEL or ESC-backslash.
                var previous: UnicodeScalar?
                while let byte = scalars.first {
                    scalars = scalars.dropFirst()
                    if byte.value == 0x07 { break }
                    if previous?.value == 0x1B, byte == "\\" { break }
                    previous = byte
                }
            default:
                break // two-character escape; the introducer was already consumed
            }
        }
        return String(result)
    }
}

extension AgentProfile {
    /// The built-in agents, shared by daemon and client.
    ///
    /// One table on purpose: the daemon OFFERS actions from it (id + label on
    /// the wire, never bytes), and a client RESOLVES a tapped id against it
    /// locally — so a forged offer, or a fake prompt provoking a real one,
    /// still cannot choose what a tap sends. Splitting the table would let
    /// the two ends drift until a tap resolves to nothing, which reads to
    /// the user as a dead button.
    public static var defaults: [AgentProfile] {
        [
            AgentProfile(
                id: "claude-code",
                displayName: "Claude Code",
                detectionMarkers: ["esc to interrupt", "claude code"],
                quickActions: [
                    QuickActionDefinition(
                        id: "approve-once",
                        label: "Yes",
                        matches: ["do you want", "1. yes"],
                        sends: Array("1\r".utf8)
                    ),
                    QuickActionDefinition(
                        id: "approve-always",
                        label: "Yes, always",
                        matches: ["do you want", "2. yes, and don't ask again"],
                        sends: Array("2\r".utf8)
                    ),
                    QuickActionDefinition(
                        id: "deny",
                        label: "No",
                        // The escape key is what Claude Code itself documents on
                        // screen, so this is the same keystroke a user would send.
                        matches: ["do you want", "no, and tell claude"],
                        sends: Array("\u{1B}".utf8)
                    ),
                ]
            ),
            // Empty markers: the burst/quiet heuristic runs from the start and
            // reports status for ANY agent, with no name claimed.
            AgentProfile.generic,
        ]
    }
}
