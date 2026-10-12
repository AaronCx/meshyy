// meshyy — shared instruments for the scroll suites: the app-side belief model,
// the app's synthesis and swipe-routing replicas, the event log, and an isolated
// tmux server.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Promoted out of ScrollModeBeliefTests.swift unchanged in behaviour so the
// SSH-oracle suite (ScrollOracleOrderingTests.swift) measures with exactly the
// same model rather than a copy that can drift.

import Darwin
import Foundation
import MeshyyCore
@testable import MeshyyKit

// MARK: - The app-side belief model

/// What a+Terminal's emulator would believe after the same ordered event
/// stream. SwiftTerm rules for the modes ScrollBridge reads:
///   `?1000h/?1002h/?1003h` set mouseMode; ANY `l` of that family clears it —
///   and so does `?1006l`, which SwiftTerm treats as "mouse off", not merely
///   "SGR encoding off". Alt screen follows 1049/1047/47.
struct EmulatorBelief {
    private var scanner = ScreenScanner()
    private(set) var mouseOn = false
    private(set) var alt = false
    /// DECCKM (`?1`): what a+Terminal's arrow-key route reads to pick
    /// `ESC O A` over `ESC [ A`. Tracked separately; it changes nothing above.
    private(set) var applicationCursor = false

    mutating func feed(_ bytes: [UInt8]) {
        for event in scanner.scan(bytes, startingAt: 0) {
            switch event {
            case .altScreen(let active, _):
                alt = active
            case .mode(let mode, let active):
                switch mode {
                case 1000, 1002, 1003:
                    mouseOn = active
                case 1006 where !active:
                    mouseOn = false
                case 1:
                    applicationCursor = active
                default:
                    break
                }
            case .fullClear:
                break
            }
        }
    }
}

/// a+Terminal's `MeshyyTransport.modeEscapes(active:)`, replicated byte for
/// byte so this suite measures what the SHIPPING app would feed its emulator
/// when a `modes` control frame arrives. If the app implementation changes,
/// change this replica with it — the pair is what the measurements are about.
/// (Current shape: 1006 settles FIRST, because SwiftTerm reads `?1006l` as
/// "mouse off" and a trailing reset would cancel the family arming.)
/// Keep in sync with a+Terminal MeshyyTransport.swift `modeEscapes(active:)` —
/// and `AppScrollBridge` below with a+Terminal ScrollBridge.swift.
func appModeEscapes(active: Set<Int>) -> [UInt8] {
    var out = "\u{1B}[?1006\(active.contains(1006) ? "h" : "l")"
    let mouseFamily: [Int] = [1000, 1002, 1003]
    if mouseFamily.contains(where: active.contains) {
        for mode in mouseFamily where active.contains(mode) {
            out += "\u{1B}[?\(mode)h"
        }
    } else {
        for mode in mouseFamily {
            out += "\u{1B}[?\(mode)l"
        }
    }
    for mode in [1, 1004, 2004] {
        out += "\u{1B}[?\(mode)\(active.contains(mode) ? "h" : "l")"
    }
    return Array(out.utf8)
}

/// One recorded session event with its arrival instant, so wrongness has a
/// measurable duration rather than only an ordering.
struct StampedEvent {
    let at: Date
    let event: MeshyySessionEvent
}

/// Collects a session's events with timestamps and can replay them into a
/// belief. Recomputing from the full ordered log on every poll is deliberate:
/// it makes the belief a pure function of arrival order, immune to the test's
/// own scheduling.
final class BeliefLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stamped: [StampedEvent] = []

    func attach(to session: MeshyySession) async {
        let stream = await session.events
        Task { [weak self] in
            for await event in stream {
                self?.append(event)
            }
        }
    }

    private func append(_ event: MeshyySessionEvent) {
        lock.withLock { stamped.append(StampedEvent(at: Date(), event: event)) }
    }

    var all: [StampedEvent] { lock.withLock { stamped } }

    /// The app-side belief after replaying every event so far, in order:
    /// `.output` feeds the emulator, `.modes` feeds the app's synthesis.
    /// `.screenMode` is deliberately NOT applied — the shipping app ignores it
    /// (MeshyyTransport: "not this type's business"), and one of these tests
    /// exists to show what that costs.
    var belief: EmulatorBelief {
        var current = EmulatorBelief()
        for entry in all {
            switch entry.event {
            case .output(let bytes):
                current.feed(bytes)
            case .modes(let active):
                current.feed(appModeEscapes(active: active))
            case .geometryReset:
                current.feed(TerminalGeometry.reset)
            default:
                break
            }
        }
        return current
    }

    /// Belief from output bytes ALONE — what an emulator would hold if the
    /// modes frames did not exist (or never reached it). The distance between
    /// this and `belief` is exactly what the modes synthesis is worth.
    var beliefFromOutputOnly: EmulatorBelief {
        var current = EmulatorBelief()
        for entry in all {
            if case .output(let bytes) = entry.event {
                current.feed(bytes)
            }
        }
        return current
    }

    var modesFrames: [Set<Int>] {
        all.compactMap {
            if case .modes(let active) = $0.event { return active } else { return nil }
        }
    }

    var text: String {
        String(decoding: all.compactMap {
            if case .output(let bytes) = $0.event { return bytes } else { return nil }
        }.flatMap { $0 }, as: UTF8.self)
    }

    var summary: String {
        all.map { entry in
            switch entry.event {
            case .output(let bytes): "output(\(bytes.count)B)"
            case .modes(let active): "modes(\(active.sorted()))"
            case .screenMode(let alt): "screen(alt:\(alt))"
            case .geometryReset: "geometryReset"
            case .screenRebuilt: "rebuilt"
            case .termios: "termios"
            case .agent: "agent"
            case .quickActions: "qa"
            case .ended(let reason): "ended(\(reason))"
            case .exited: "exited"
            case .failed(let reason): "FAILED(\(reason))"
            case .reconnecting: "reconnecting"
            }
        }.joined(separator: " ")
    }

    @discardableResult
    func wait(
        timeout: TimeInterval = 30,
        until predicate: @Sendable @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return predicate()
    }
}

/// Every DEC private-mode set/reset in a log's output, per event, in order —
/// the diagnostic for "who armed this and when".
func decModeInventory(_ log: BeliefLog) -> [String] {
    var inventory: [String] = []
    for (index, entry) in log.all.enumerated() {
        guard case .output(let bytes) = entry.event else {
            if case .modes(let active) = entry.event {
                inventory.append("#\(index) FRAME modes\(active.sorted())")
            }
            continue
        }
        let text = String(decoding: bytes, as: UTF8.self)
        var found: [String] = []
        var search = text[...]
        while let start = search.range(of: "\u{1B}[?") {
            let rest = search[start.upperBound...]
            if let end = rest.firstIndex(where: { $0 == "h" || $0 == "l" }) {
                found.append("?\(rest[..<end])\(rest[end])")
                search = rest[rest.index(after: end)...]
            } else { break }
        }
        if !found.isEmpty {
            inventory.append("#\(index) output(\(bytes.count)B) \(found.joined(separator: " "))")
        }
    }
    return inventory
}

// MARK: - The isolated tmux server

/// An isolated tmux server (its own -L socket, its own conf) so these tests
/// can never touch a real session on this machine.
struct ScrollTmux {
    /// Homebrew on Apple silicon, Homebrew on Intel, then PATH — so a CI runner
    /// that `brew install`s tmux runs these suites instead of skipping them.
    static let path: String = {
        var candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += searchPath.split(separator: ":").map { "\($0)/tmux" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/opt/homebrew/bin/tmux"
    }()
    static var available: Bool { FileManager.default.isExecutableFile(atPath: path) }
    static let unavailableReason = "tmux not found in /opt/homebrew/bin, /usr/local/bin or PATH"

    let label: String
    let confPath: String

    init(mouse: Bool) throws {
        label = "mshy-scroll-\(UUID().uuidString.prefix(8).lowercased())"
        confPath = "/tmp/\(label).conf"
        // status off keeps the outer stream small and deterministic-ish; the
        // default shell is pinned because the daemon's test child is /bin/sh
        // with a minimal environment.
        let conf = """
        set -g mouse \(mouse ? "on" : "off")
        set -g status off
        set -g escape-time 0
        set -g default-shell /bin/sh
        """
        try conf.write(toFile: confPath, atomically: true, encoding: .utf8)
    }

    var attachCommand: String {
        "\(Self.path) -L \(label) -f \(confPath) new -A -s p\n"
    }

    /// Runs a command INSIDE the pane without typing into it, so the flapper
    /// can be driven precisely.
    func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.path)
        process.arguments = ["-L", label] + arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// tmux's own record of the inner pane — the INNER truth the outer stream
    /// is derived from.
    func paneMouseFlag() -> String? {
        run(["display", "-p", "-t", "p", "#{mouse_any_flag}"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plain attach to the existing session `p` — what a second client types.
    var attachExistingCommand: String {
        "\(Self.path) -L \(label) attach -t p\n"
    }

    /// Starts session `p` DETACHED, so any number of clients can come and go
    /// without one of them owning the server's lifetime.
    @discardableResult
    func startDetached(cols: Int = 80, rows: Int = 24) -> Bool {
        _ = run(["-f", confPath, "new-session", "-d", "-s", "p",
                 "-x", "\(cols)", "-y", "\(rows)"])
        return hasSession
    }

    var hasSession: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.path)
        process.arguments = ["-L", label, "has-session", "-t", "p"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The OUTCOME of a swipe as tmux itself reports it: whether the pane is in
    /// copy mode, and how far up it is scrolled (`nil` outside copy mode, where
    /// tmux prints an empty `scroll_position`).
    func scrollState() -> (inMode: Int, scrollPosition: Int?) {
        let raw = run(["display", "-p", "-t", "p", "#{pane_in_mode} #{scroll_position}"]) ?? ""
        let fields = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        let inMode = fields.first.flatMap { Int($0) } ?? -1
        let position = fields.count > 1 ? Int(fields[1]) : nil
        return (inMode, position)
    }

    /// Lines of scrollback above the visible screen. A swipe can only scroll
    /// if there is something to scroll to, so the oracle suite checks this
    /// before every swipe rather than assuming the seed survived.
    func historySize() -> Int {
        let raw = run(["display", "-p", "-t", "p", "#{history_size}"]) ?? ""
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    /// Heights of every attached client, as tmux sizes them.
    func clientHeights() -> [Int] {
        (run(["list-clients", "-F", "#{client_height}"]) ?? "")
            .split(separator: "\n").compactMap { Int($0) }
    }

    /// Detaches every client of session `p`, so exactly one client — the next
    /// one to attach — sizes the window.
    func detachAllClients() {
        _ = run(["detach-client", "-s", "p"])
    }

    /// Out of copy mode, history gone, then fresh scrollback: the precondition
    /// every swipe is measured from. `then` runs after the scrollback is drawn
    /// (in the same command line, so it starts only once `seq` has finished).
    func seed(then command: String? = nil) {
        _ = run(["send-keys", "-t", "p", "-X", "cancel"])
        _ = run(["clear-history", "-t", "p"])
        let line = ["seq 1 400", command].compactMap { $0 }.joined(separator: "; ")
        _ = run(["send-keys", "-t", "p", line, "Enter"])
    }

    /// Leaves copy mode without touching history: the reset between swipes.
    func cancelCopyMode() {
        _ = run(["send-keys", "-t", "p", "-X", "cancel"])
    }

    func kill() {
        _ = run(["kill-server"])
        try? FileManager.default.removeItem(atPath: confPath)
    }
}

// MARK: - The app-side swipe router

/// a+Terminal's `ScrollBridgeCore` routing, SGR wheel encoding, arrow-key
/// encoding and bottom-row clamp, replicated so a swipe here produces the bytes
/// the SHIPPING app would send from the same belief. Keep in sync with
/// a+Terminal ScrollBridge.swift (`mode`, `wheelEvent`, `wheelRow`,
/// `arrowEvents`) — like `appModeEscapes`, the replica is what is measured.
/// `wheelBridgeEnabled` is the app default (on).
enum AppScrollBridge {
    enum Route: String, Sendable { case sgrWheel, arrowKeys, native }

    static func route(_ belief: EmulatorBelief) -> Route {
        belief.mouseOn ? .sgrWheel : (belief.alt ? .arrowKeys : .native)
    }

    /// 1-based row for a touch at `y` in a view `height` tall, never the bottom row.
    static func wheelRow(forY y: Double, height: Double, rows: Int) -> Int {
        guard rows > 1, height > 0 else { return 1 }
        return min(min(max(Int(y / (height / Double(rows))) + 1, 1), rows), rows - 1)
    }

    /// The bytes one swipe of `ticks` emits on `route` (empty for `.native`).
    static func bytes(_ route: Route, up: Bool, ticks: Int, col: Int, row: Int,
                      applicationCursor: Bool) -> [UInt8] {
        switch route {
        case .sgrWheel:
            return (0..<ticks).flatMap { _ in Array("\u{1B}[<\(up ? 64 : 65);\(col);\(row)M".utf8) }
        case .arrowKeys:
            let key: [UInt8] = [0x1B, applicationCursor ? 0x4F : 0x5B, up ? 0x41 : 0x42]
            return (0..<(ticks * 3)).flatMap { _ in key }
        case .native:
            return []
        }
    }
}
