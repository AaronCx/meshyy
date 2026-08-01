// meshyy — a session's child must own its terminal.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Nothing tested this, and it was broken the whole time: children spawned with
// no controlling terminal, so `/dev/tty` answered "device not configured" inside
// every session. Everything that opens it failed — `sudo`, an ssh password
// prompt, `read -s`, vim's shell escapes — and none of it failed loudly. Over
// plain SSH it all worked, because sshd does the ctty dance itself, so it read
// as "meshyy is broken" rather than as one missing property.

import Darwin
import Foundation
import Testing
@testable import MeshyyCore
@testable import MeshyyDaemon

@Suite("Controlling terminal", .serialized,
       .enabled(if: RealProcessTests.isEnabled, RealProcessTests.reason))
struct ControllingTerminalTests {

    /// Reads from the pty until `marker` appears, or the deadline passes.
    private func awaitOutput(_ pty: PTY, marker: String, seconds: Double = 8) throws -> String {
        var accumulated = [UInt8]()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let chunk = try? pty.read(), !chunk.isEmpty {
                accumulated += chunk
                if String(decoding: accumulated, as: UTF8.self).contains(marker) { break }
            } else {
                usleep(20_000)
            }
        }
        return String(decoding: accumulated, as: UTF8.self)
    }

    /// NOTE ON SCOPE, measured the hard way: an in-process `PTY` acquires a
    /// controlling terminal with or without the trampoline, so this test passes
    /// either way and is NOT the proof that the trampoline is needed. The property
    /// broke only under **launchd**, where the daemon's own process has no session
    /// (`ps` shows `SESS 0`) — verified by running the identical binary under a
    /// throwaway LaunchAgent: without the trampoline `/dev/tty` answered "device
    /// not configured", with it the same binary answered fine. Keep this test for
    /// the ordinary regression, and re-run the launchd check by hand
    /// (docs/qa/ctty-trampoline-notes.md) before ever removing the trampoline.
    @Test("/dev/tty is usable inside a session")
    func devTTYWorks() throws {
        let pty = try PTY(
            executable: "/bin/sh",
            arguments: ["-c", "echo TTY-$( (echo probe > /dev/tty) 2>&1 && echo OK || echo FAIL)-END"],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        defer { pty.terminate() }
        let output = try awaitOutput(pty, marker: "-END")
        #expect(output.contains("TTY-OK-END"), """
            /dev/tty is not usable inside the session (saw \(output.debugDescription)) — \
            sudo, ssh password prompts and `read -s` all fail there, silently and only \
            under meshyy
            """)
    }

    @Test("The child owns the pty as its controlling terminal")
    func childOwnsTheTerminal() throws {
        let pty = try PTY(
            executable: "/bin/sh",
            arguments: ["-c", "echo CTTY-$(tty)-END"],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        defer { pty.terminate() }
        let output = try awaitOutput(pty, marker: "-END")
        #expect(output.contains("CTTY-\(pty.slavePath)-END"), """
            the child's controlling terminal is not this session's pty \
            (expected \(pty.slavePath), saw \(output.debugDescription))
            """)
    }

    /// The half that costs something: a child holding a ctty cannot finish
    /// exiting while the daemon keeps the slave open, so an exit must still be
    /// observable — otherwise every dead session reports itself alive forever.
    @Test("A child that exits is still seen to exit, ctty and all")
    func exitIsStillObservable() throws {
        let pty = try PTY(
            executable: "/bin/echo",
            arguments: ["done"],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        defer { pty.terminate() }

        var exited = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !pty.isChildAlive { exited = true; break }
            usleep(10_000)
        }
        #expect(exited, """
            the child's exit was never observed — a session leader parked mid-exit \
            reads as running to waitpid, so every dead session would report alive
            """)

        // And the output it wrote before exiting must still be readable: the
        // drain-then-release ordering is what protects it.
        let output = try awaitOutput(pty, marker: "done")
        #expect(output.contains("done"),
                "the child's last output was discarded (saw \(output.debugDescription))")
    }
}
