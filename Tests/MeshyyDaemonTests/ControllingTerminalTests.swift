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

    /// All three standard descriptors must be READ-WRITE, as a terminal's are.
    ///
    /// Sounds like pedantry; it was a black screen. tmux's server writes the redraw
    /// to the terminal fd its client hands over, and that fd is fd 0. The first
    /// trampoline opened fd 0 read-only (`exec <"$0"`), so those writes failed,
    /// tmux's output buffer never drained — "redraw deferred (395 left)", 4051
    /// times in its own server log — and every `tmux attach` painted nothing. Plain
    /// output and even vim were byte-identical, because they write to stdout, which
    /// is why nothing else noticed. Measured with lsof: the file-action version gave
    /// `0u 1u 2u`, the broken trampoline `0r 1w 2w`.
    ///
    /// Asserted with `fcntl(F_GETFL)` rather than a shell redirection: `echo >&0`
    /// passes even against the bug, because the shell re-opens the terminal by name
    /// instead of duplicating the descriptor — a test that could not fail.
    @Test("All three standard descriptors are read-write, as a terminal's are")
    func standardDescriptorsAreReadWrite() throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else { return }
        let check = """
            import fcntl, os
            modes = []
            for fd in (0, 1, 2):
                mode = fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE
                modes.append({os.O_RDONLY: 'r', os.O_WRONLY: 'w', os.O_RDWR: 'rw'}[mode])
            print('FDMODES-' + ','.join(modes) + '-END')
            """
        let pty = try PTY(
            executable: python,
            arguments: ["-c", check],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        defer { pty.terminate() }
        let output = try awaitOutput(pty, marker: "-END")
        #expect(output.contains("FDMODES-rw,rw,rw-END"), """
            a session's descriptors are not all read-write (saw \(output.debugDescription)) \
            — tmux writes its redraw to fd 0, so anything less is a black screen on \
            every attach
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
