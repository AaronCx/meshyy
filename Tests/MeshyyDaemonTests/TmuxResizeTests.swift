// meshyy — the black-space bug, reproduced with the program that shows it.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// The user-visible failure: the phone dismisses its keyboard, sends the taller
// size, and tmux keeps drawing at the shorter one — black space below. Every
// synthetic layer said the resize path worked (`stty size` reflected every
// change), and the screen still went black, because the layer that draws is the
// tmux CLIENT and no test was watching what IT believed.
//
// So this suite runs the real chain: a real daemon session whose shell runs a
// real tmux client on the session's pty, driven over the real socket transport,
// and every assertion is on what TMUX reports about its client — the exact
// number that decides where the black region starts.

import Darwin
import Foundation
import Testing
@testable import MeshyyCore
@testable import MeshyyDaemon

/// tmux runs on this machine or the suite skips.
private let tmuxPath = "/opt/homebrew/bin/tmux"
private var tmuxAvailable: Bool { FileManager.default.isExecutableFile(atPath: tmuxPath) }

/// Talks to an ISOLATED tmux server (its own -L socket) so these tests can never
/// touch a real session on this machine.
private struct TmuxProbe {
    let label: String

    init() { label = "mshy-e2e-\(UUID().uuidString.prefix(8).lowercased())" }

    /// What the tmux SERVER believes about its attached client — the number that
    /// decides where the black space starts.
    func clientSize() -> String? {
        let out = run(["-L", label, "list-clients", "-F", "#{client_width}x#{client_height}"])
        let trimmed = out?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    func killServer() { _ = run(["-L", label, "kill-server"]) }

    private func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

@Suite("Resize with a real tmux client", .serialized,
       .enabled(if: RealProcessTests.isEnabled, RealProcessTests.reason),
       .enabled(if: tmuxAvailable, "tmux not found at /opt/homebrew/bin/tmux"))
struct TmuxResizeTests {

    /// Polls tmux's belief until it matches or the deadline passes.
    private func awaitClientSize(
        _ probe: TmuxProbe, expecting size: String, seconds: Double = 8
    ) -> String {
        let deadline = Date().addingTimeInterval(seconds)
        var seen = "no client"
        while Date() < deadline {
            if let current = probe.clientSize() {
                seen = current
                if current == size { return current }
            }
            usleep(100_000)
        }
        return seen
    }

    /// A daemon session whose shell starts an isolated tmux client, with the
    /// given starting size, plus the connected test client driving it.
    private func startTmuxSession(
        path: String, probe: TmuxProbe, cols: Int, rows: Int
    ) throws -> TestClient {
        let client = try TestClient(socketPath: path)
        client.send(.control(.hello(.init(
            token: "", cols: cols, rows: rows, session: "tmux-\(probe.label)"
        ))))
        #expect(client.pump { frames in frames.contains { $0.kind == .control } },
                "no Welcome")
        client.send(.pty(0, Array("\(tmuxPath) -L \(probe.label) new -A -s p\n".utf8)))
        return client
    }

    /// The dismiss sequence under BOTH process topologies. `/bin/sh` keeps its jobs
    /// in its own group, so any delivery at all reaches tmux — that is the shape
    /// most harnesses accidentally test, and it hid this bug from every layer. A
    /// job-control shell (zsh — the daemon's real default) puts the tmux client in
    /// its OWN group: on the phone, every resize was applied to the kernel and
    /// heard by nobody, and tmux kept drawing at the old height — black below.
    @Test("The keyboard-dismiss sequence: shrink, grow — tmux must follow",
          arguments: [SessionChild.shell, SessionChild.jobControlShell])
    func keyboardDismissSequence(child: SessionChild) async throws {
        try await withServer(child: child) { path, _ in
            let probe = TmuxProbe()
            defer { probe.killServer() }
            let client = try startTmuxSession(path: path, probe: probe, cols: 74, rows: 64)
            defer { client.close() }

            #expect(awaitClientSize(probe, expecting: "74x64") == "74x64",
                    "tmux never saw the starting size (\(child))")

            // Keyboard up.
            client.send(.control(.resize(cols: 74, rows: 39)))
            #expect(awaitClientSize(probe, expecting: "74x39") == "74x39",
                    "tmux missed the shrink (\(child))")

            // Keyboard dismissed — THE black-space step.
            client.send(.control(.resize(cols: 74, rows: 64)))
            let grown = awaitClientSize(probe, expecting: "74x64")
            #expect(grown == "74x64", """
                (\(child)) tmux is drawing \(grown) against a 74x64 terminal — \
                everything below its idea of the bottom row is the black space the \
                user reported
                """)
        }
    }

    /// The suspend-cycle variant: the taller size arrives as a RE-ATTACH (the app
    /// was backgrounded when the keyboard went away, so no resize frame was ever
    /// sent — the new size shows up in the next Hello instead).
    @Test("A reattach at a taller size than the pty holds — tmux must follow")
    func reattachAtDifferentSize() async throws {
        try await withServer(child: .shell) { path, _ in
            let probe = TmuxProbe()
            defer { probe.killServer() }
            let first = try startTmuxSession(path: path, probe: probe, cols: 74, rows: 39)

            #expect(awaitClientSize(probe, expecting: "74x39") == "74x39",
                    "tmux never saw the starting size")

            // The app suspends: transport gone, no Bye, shell and tmux live on.
            first.close()
            usleep(300_000)

            // Foreground: reattach with the keyboard now dismissed — taller.
            let second = try TestClient(socketPath: path)
            defer { second.close() }
            second.send(.control(.hello(.init(
                token: "", cols: 74, rows: 64, session: "tmux-\(probe.label)"
            ))))
            #expect(second.pump { frames in frames.contains { $0.kind == .control } },
                    "no Welcome on reattach")

            let grown = awaitClientSize(probe, expecting: "74x64")
            #expect(grown == "74x64", """
                after a reattach at 74x64, tmux is still drawing \(grown) — the exact \
                suspended-with-keyboard-up, foregrounded-without state
                """)
        }
    }


}
