// meshyy — agent detection and quick-action offers (design doc §5.3, §7.3, M5/M6).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// The clock is a parameter, so every one of these is deterministic. The original
// a+Terminal monitor used Task.sleep, which is why its behaviour was only ever
// tested at the edges.

import Foundation
import Testing
@testable import MeshyyCore

private let claudeCode = AgentProfile(
    id: "claude-code",
    displayName: "Claude Code",
    detectionMarkers: ["esc to interrupt"],
    quietInterval: .seconds(2),
    burstThreshold: 200,
    quickActions: [
        QuickActionDefinition(
            id: "approve",
            label: "Yes",
            matches: ["do you want", "1. yes"],
            sends: Array("1\r".utf8)
        ),
        QuickActionDefinition(
            id: "deny",
            label: "No",
            matches: ["do you want", "no, and tell claude"],
            sends: Array("\u{1B}".utf8)
        ),
    ]
)

private func burst(_ count: Int = 400) -> [UInt8] {
    Array(String(repeating: "x", count: count).utf8)
}

@Suite("Agent activity")
struct AgentActivityTests {

    // MARK: - Status heuristic

    @Test("A sustained burst reads as working; quiet then reads as waiting")
    func burstThenQuiet() {
        var monitor = AgentActivityMonitor(candidates: [claudeCode])
        let start = ContinuousClock().now

        #expect(monitor.observe(burst(), now: start).status == .working)
        #expect(monitor.status == .working)

        // Not yet quiet.
        #expect(monitor.tick(now: start.advanced(by: .seconds(1))).status == nil)
        #expect(monitor.status == .working)

        // Quiet for the interval.
        #expect(monitor.tick(now: start.advanced(by: .seconds(2))).status == .waiting)
        #expect(monitor.status == .waiting)
    }

    @Test("A keystroke echo never reaches the burst threshold")
    func keystrokesAreNotWork() {
        var monitor = AgentActivityMonitor(candidates: [claudeCode])
        let start = ContinuousClock().now
        for index in 0..<20 {
            let changes = monitor.observe(
                Array("a".utf8),
                now: start.advanced(by: .milliseconds(index * 10))
            )
            #expect(changes.status == nil, "a single character must not read as working")
        }
        #expect(monitor.status == .none)
    }

    /// The case the original heuristic got wrong for minutes at a time: inside a
    /// multiplexer, redraws splice escape codes through the text, so a marker rarely
    /// lands as a contiguous substring. Status must not depend on it.
    @Test("Status works even when no marker ever matches")
    func statusWithoutMarker() {
        var monitor = AgentActivityMonitor(candidates: [claudeCode])
        let start = ContinuousClock().now
        #expect(monitor.observe(burst(), now: start).status == .working)
        #expect(monitor.detected?.id == "claude-code",
                "a single explicit profile is named up front, without waiting for a marker")
    }

    @Test("A marker upgrades the generic profile to the real name")
    func markerUpgradesName() {
        var monitor = AgentActivityMonitor(candidates: [claudeCode, .generic])
        let start = ContinuousClock().now

        // Generic first: heuristic active, no name claimed.
        #expect(monitor.observe(burst(), now: start).status == .working)
        #expect(monitor.detected == nil, "with a generic fallback no name is claimed yet")

        let changes = monitor.observe(
            Array("(esc to interrupt)".utf8),
            now: start.advanced(by: .milliseconds(100))
        )
        #expect(changes.detected != nil)
        #expect(monitor.detected?.displayName == "Claude Code")
    }

    @Test("A marker split across two reads is still matched")
    func markerSplitAcrossReads() {
        var monitor = AgentActivityMonitor(candidates: [claudeCode, .generic])
        let start = ContinuousClock().now
        monitor.observe(Array("... esc to in".utf8), now: start)
        monitor.observe(Array("terrupt)".utf8), now: start.advanced(by: .milliseconds(10)))
        #expect(monitor.detected?.id == "claude-code")
    }

    @Test("A marker matches through interleaved escape sequences")
    func markerThroughEscapes() {
        var monitor = AgentActivityMonitor(candidates: [claudeCode, .generic])
        // What a tmux redraw actually looks like: cursor moves spliced through text.
        let noisy = "esc\u{1B}[1;5H to \u{1B}[Kinterrupt"
        monitor.observe(Array(noisy.utf8), now: ContinuousClock().now)
        #expect(monitor.detected?.id == "claude-code",
                "stripANSI must run before matching, or a multiplexer hides every marker")
    }

    /// A quiet window ending at a bare shell prompt means the agent is gone, so
    /// status clears rather than sitting on "waiting" forever.
    @Test("Quiet at a bare shell prompt clears the status")
    func quietAtPromptClears() {
        var monitor = AgentActivityMonitor(candidates: [claudeCode])
        let start = ContinuousClock().now
        monitor.observe(burst(), now: start)
        #expect(monitor.status == .working)

        monitor.observe(Array("\r\nuser@host ~ $ ".utf8), now: start.advanced(by: .milliseconds(10)))
        let changes = monitor.tick(now: start.advanced(by: .seconds(3)))
        #expect(changes.status == .none, "a bare prompt means nothing is waiting for input")
        #expect(monitor.status == .none)
    }

    @Test("A prompt terminator is recognised through escape noise", arguments: [
        ("\u{1B}[0m$ ", true),
        ("\u{1B}]0;title\u{07}% ", true),
        ("# ", true),
        ("│ esc to interrupt │", false),
        ("╰──────────────────╯", false),
        ("", false),
    ])
    func promptDetection(sample: (String, Bool)) {
        #expect(AgentActivityMonitor.endsAtShellPrompt(sample.0) == sample.1,
                "\(sample.0.debugDescription)")
    }

    // MARK: - Quick actions (design doc §7.3)

    @Test("Actions are offered only when every match is present")
    func actionsRequireAllMatches() {
        var monitor = AgentActivityMonitor(candidates: [claudeCode])
        let now = ContinuousClock().now

        // The prompt text alone is not enough.
        var changes = monitor.observe(Array("Do you want to proceed?".utf8), now: now)
        #expect(changes.actions == nil || changes.actions?.isEmpty == true)

        // With the option, the approve action becomes offerable.
        changes = monitor.observe(
            Array("\r\n  1. Yes\r\n".utf8),
            now: now.advanced(by: .milliseconds(10))
        )
        #expect(monitor.offeredActions.map(\.id) == ["approve"],
                "only the action whose matches are all present may be offered")
    }

    @Test("Both actions are offered when the full prompt is on screen")
    func fullPromptOffersBoth() {
        var monitor = AgentActivityMonitor(candidates: [claudeCode])
        let prompt = """
            Do you want to proceed?
              1. Yes
              2. No, and tell Claude what to do differently
            """
        monitor.observe(Array(prompt.utf8), now: ContinuousClock().now)
        #expect(Set(monitor.offeredActions.map(\.id)) == ["approve", "deny"])
    }

    /// Design doc §7.3: the offer is withdrawn on a clear or an alt-screen
    /// transition, because the text it was based on is gone.
    @Test("A screen change withdraws the offer")
    func screenChangeWithdraws() {
        var monitor = AgentActivityMonitor(candidates: [claudeCode])
        monitor.observe(
            Array("Do you want to proceed?\r\n  1. Yes\r\n".utf8),
            now: ContinuousClock().now
        )
        #expect(!monitor.offeredActions.isEmpty)

        let changes = monitor.screenChanged()
        #expect(changes.actions == [], "a clear must withdraw the offer")
        #expect(monitor.offeredActions.isEmpty)
    }

    @Test("Actions match through escape sequences, as a real TUI emits them")
    func actionsMatchThroughEscapes() {
        var monitor = AgentActivityMonitor(candidates: [claudeCode])
        // Claude Code draws its prompt inside a box with colour runs.
        let boxed = "\u{1B}[1m│\u{1B}[0m Do you want to proceed?\r\n"
            + "\u{1B}[32m│\u{1B}[0m   1. Yes\r\n"
        monitor.observe(Array(boxed.utf8), now: ContinuousClock().now)
        #expect(monitor.offeredActions.map(\.id) == ["approve"])
    }

    /// The security property. The wire form carries an id and a label; the bytes a
    /// tap sends live only in the local profile. A remote that forges the frame
    /// cannot choose the keystrokes.
    @Test("The advertised form of an action carries no keystrokes")
    func advertisedFormCarriesNoBytes() {
        let action = claudeCode.quickActions[0]
        let advertised = action.advertised
        #expect(advertised.id == action.id)
        #expect(advertised.label == action.label)
        // QuickAction has exactly two fields; the wire test in ControlFrameTests
        // pins that. Here we pin that the bytes stayed behind.
        #expect(!action.sends.isEmpty, "the definition must carry bytes")
        #expect(Mirror(reflecting: advertised).children.count == 2,
                "QuickAction must never gain a field that could carry sendable bytes")
    }

    @Test("A profile with no quick actions never offers any")
    func noActionsMeansNoOffers() {
        var monitor = AgentActivityMonitor(candidates: [.generic])
        monitor.observe(Array("Do you want to proceed?\r\n 1. Yes\r\n".utf8),
                        now: ContinuousClock().now)
        #expect(monitor.offeredActions.isEmpty)
    }

    // MARK: - Profile serialisation

    @Test("A profile round-trips through JSON, so profiles can be data")
    func profileRoundTrips() throws {
        let encoded = try JSONEncoder().encode(claudeCode)
        let decoded = try JSONDecoder().decode(AgentProfile.self, from: encoded)
        #expect(decoded == claudeCode)
        #expect(decoded.quietInterval == .seconds(2), "Duration survives as milliseconds")
    }

    @Test("A minimal profile decodes with sensible defaults")
    func minimalProfileDecodes() throws {
        let json = Data(#"{"id":"x","displayName":"X"}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentProfile.self, from: json)
        #expect(decoded.detectionMarkers.isEmpty)
        #expect(decoded.quietInterval == .seconds(2))
        #expect(decoded.burstThreshold == 200)
        #expect(decoded.quickActions.isEmpty)
    }

    @Test("reset returns the monitor to its initial state")
    func resetClears() {
        var monitor = AgentActivityMonitor(candidates: [claudeCode])
        let now = ContinuousClock().now
        monitor.observe(burst(), now: now)
        monitor.observe(Array("Do you want to proceed?\r\n 1. Yes".utf8), now: now)
        #expect(monitor.status == .working)
        #expect(!monitor.offeredActions.isEmpty)

        monitor.reset()
        #expect(monitor.status == .none)
        #expect(monitor.offeredActions.isEmpty)
    }
}

@Suite("Quick action resolution")
struct QuickActionResolutionTests {

    /// The §7.3 property, stated as a test: an id is only meaningful against local
    /// profile data. There is no path from a wire frame to a keystroke.
    @Test("An advertised action carries no way to derive its keystrokes")
    func wireFormIsNotSufficient() {
        let advertised = claudeCode.quickActions[0].advertised
        // Everything the wire gives you.
        let fromWire = (advertised.id, advertised.label)
        // The bytes are recoverable only by looking them up locally.
        let local = claudeCode.quickActions.first { $0.id == fromWire.0 }
        #expect(local?.sends == Array("1\r".utf8))
        // And an id nobody declared resolves to nothing at all.
        #expect(claudeCode.quickActions.first { $0.id == "injected-by-remote" } == nil)
    }

    @Test("Resolution is exact: a near-miss id does not fall through to another action")
    func resolutionIsExact() {
        let ids = claudeCode.quickActions.map(\.id)
        #expect(ids == ["approve", "deny"])
        for candidate in ["approv", "approvee", "APPROVE", "", "deny "] {
            #expect(claudeCode.quickActions.first { $0.id == candidate } == nil,
                    "\(candidate.debugDescription) must not resolve")
        }
    }
}
