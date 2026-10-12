// meshyy — the debug-gated mode trace: what the far side armed, and when.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// The trace is the far-side half of a scroll investigation: a phone records what its
// emulator believed at each swipe, the daemon records what the pty actually armed, and
// the two line up by wall-clock time. These pin that the daemon's half is recorded,
// says what it should, and costs nothing when it is off.

import Foundation
import Synchronization
import Testing
@testable import MeshyyCore
@testable import MeshyyDaemon

extension DaemonRealProcessSuite {
    @Suite("Mode trace (debug-gated)", .serialized,
           .enabled(if: RealProcessTests.isEnabled, RealProcessTests.reason))
    struct ModeTraceTests {

        @Test("The ring keeps the newest entries and never grows past its capacity")
        func ringIsBounded() {
            var log = ModeTraceLog(capacity: 3)
            for offset in 0..<5 {
                log.append(ModeTraceEntry(
                    at: Date(), source: .pty, modes: [1000], altScreen: false,
                    offset: UInt64(offset), flips: 1, transientMouseOff: false))
            }
            #expect(log.entries.map(\.offset) == [2, 3, 4])
        }

        /// The shape that matters: arm, enter the alt screen, then a tmux-style redraw
        /// pulse that disarms and re-arms inside ONE write. The pulse must be visible
        /// (transient_mouse_off) even though the set it ends on is unchanged — a pulse
        /// split across two reads is exactly where a phone's swipe can find the mouse off.
        ///
        /// Each step waits for the previous one to be recorded before the next is
        /// released (the child blocks on `read`). Sleeps were not enough: on a loaded CI
        /// runner all three writes landed in one drain and the steps blurred into one.
        @Test("Arming, the alt screen, a redraw pulse and an attach are all recorded")
        func recordsTransitions() async throws {
            let lines = Mutex<[String]>([])
            let session = try PTYSession(
                name: "trace-modes",
                executable: "/bin/sh",
                arguments: ["-c", """
                    stty -echo
                    printf '\\033[?1000;1006h'; read step
                    printf '\\033[?1049h'; read step
                    printf '\\033[?1006l\\033[?1000l\\033[?1006h\\033[?1000h'; sleep 30
                    """],
                environment: ["PATH": "/usr/bin:/bin"],
                traceModes: true,
                modeTraceSink: { line in lines.withLock { $0.append(line) } }
            )
            await session.start()
            defer { Task { await session.close() } }

            func waitForTrace(
                _ what: String,
                until done: ([ModeTraceEntry]) -> Bool
            ) async throws -> [ModeTraceEntry] {
                var trace: [ModeTraceEntry] = []
                let deadline = Date().addingTimeInterval(20)
                while Date() < deadline {
                    trace = await session.info.modeTrace ?? []
                    if done(trace) { return trace }
                    try await Task.sleep(for: .milliseconds(25))
                }
                Issue.record("never recorded \(what): \(trace)")
                return trace
            }

            var trace = try await waitForTrace("the arming") { $0.contains { $0.source == .pty } }
            try await session.send(Array("\n".utf8))
            trace = try await waitForTrace("the alt screen") { $0.contains { $0.source == .alt } }
            try await session.send(Array("\n".utf8))
            trace = try await waitForTrace("the pulse") { $0.filter { $0.source == .pty }.count >= 2 }

            let pty = trace.filter { $0.source == .pty }
            #expect(pty.first?.modes == [1000, 1006] && pty.first?.transientMouseOff == false
                    && pty.first?.flips == 2,
                    "the first arming was not recorded as a clean arm: \(trace)")
            #expect(trace.contains { $0.source == .alt && $0.altScreen },
                    "entering the alt screen was not recorded: \(trace)")
            let pulse = pty.last
            #expect(pty.count == 2 && pulse?.transientMouseOff == true && pulse?.flips == 4
                    && pulse?.modes == [1000, 1006] && pulse?.altScreen == true,
                    "a disarm/re-arm pulse must be recorded as transient, ending armed: \(trace)")
            // Wall-clock, so it can be lined up against a phone's record.
            #expect(trace.allSatisfy { abs($0.at.timeIntervalSinceNow) < 60 })

            let (_, _, token) = await session.attach(resumeFrom: nil)
            let afterAttach = await session.info.modeTrace ?? []
            #expect(afterAttach.last?.source == .attach && afterAttach.last?.modes == [1000, 1006],
                    "an attaching client's starting state was not recorded: \(afterAttach)")
            await session.detach(token)

            let logged = lines.withLock { $0 }
            #expect(logged.count == afterAttach.count,
                    "every entry must also reach the log sink: \(logged)")
            #expect(logged.allSatisfy { $0.hasPrefix("meshyyd: modes trace-modes at_ms=") })
        }

        @Test("Off by default: no trace, no log lines, but the current modes still report")
        func offByDefault() async throws {
            let lines = Mutex<[String]>([])
            let session = try PTYSession(
                name: "trace-off",
                executable: "/bin/sh",
                arguments: ["-c", "printf '\\033[?1000h'; sleep 30"],
                environment: ["PATH": "/usr/bin:/bin"],
                modeTraceSink: { line in lines.withLock { $0.append(line) } }
            )
            await session.start()
            defer { Task { await session.close() } }

            var info = await session.info
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, info.activeModes != [1000] {
                try await Task.sleep(for: .milliseconds(50))
                info = await session.info
            }
            #expect(info.activeModes == [1000])
            #expect(info.modeTrace == nil)
            #expect(lines.withLock { $0 }.isEmpty, "an untraced daemon must log nothing")
        }

        @Test("list --json carries the current modes, and the trace when it is on")
        func listCarriesModes() async throws {
            try await withServer(child: .bytePipe, traceModes: true) { path, store in
                let client = try TestClient(socketPath: path)
                defer { client.close() }
                client.send(.control(.hello(.init(token: "", cols: 80, rows: 24, session: "listed"))))
                #expect(client.pump { !$0.isEmpty }, "no Welcome")
                // The byte pipe echoes this back as output, which the daemon parses.
                client.send(.pty(0, Array("\u{1B}[?1000;1006h".utf8)))

                var row: [String: Any]?
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline {
                    row = try Self.row("listed", socketPath: path)
                    if row?["modes"] as? [Int] == [1000, 1006] { break }
                    usleep(50_000)
                }
                #expect(row?["modes"] as? [Int] == [1000, 1006], "row: \(String(describing: row))")
                let trace = row?["mode_trace"] as? [[String: Any]] ?? []
                #expect(trace.contains { $0["src"] as? String == "pty"
                    && $0["modes"] as? [Int] == [1000, 1006]
                    && ($0["at_ms"] as? Int ?? 0) > 1_700_000_000_000 },
                    "the trace row is missing or malformed: \(trace)")
                _ = store
            }
        }

        private static func row(_ name: String, socketPath: String) throws -> [String: Any]? {
            let asker = try TestClient(socketPath: socketPath)
            defer { asker.close() }
            asker.send(.control(.sessionListRequest))
            _ = asker.pump { frames in frames.contains { $0.kind == .control } }
            guard case .sessionListResponse(let json)? = asker.controlFrames.first(where: {
                if case .sessionListResponse = $0 { return true }
                return false
            }),
            let envelope = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let rows = envelope["sessions"] as? [[String: Any]]
            else { return nil }
            return rows.first { $0["name"] as? String == name }
        }
    }
}
