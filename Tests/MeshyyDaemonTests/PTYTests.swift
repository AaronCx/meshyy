// meshyy — PTY ownership, against a real PTY and a real shell.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// These spawn processes. That is the point: the design doc asserts things about
// termios and controlling terminals that only a real PTY can confirm, and an
// assertion is not a test.

import Darwin
import Foundation
import Testing
@testable import MeshyyCore
@testable import MeshyyDaemon

/// Reads from a PTY until `marker` appears or the deadline passes.
/// Returns everything read, so a failure message can show what did arrive.
private func readUntil(
    _ pty: PTY,
    marker: String,
    timeout: TimeInterval = 5
) throws -> (found: Bool, output: String) {
    var accumulated = [UInt8]()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        guard let chunk = try pty.read() else { break } // child exited
        if chunk.isEmpty {
            usleep(5_000)
            continue
        }
        accumulated += chunk
        let text = String(decoding: accumulated, as: UTF8.self)
        if text.contains(marker) { return (true, text) }
    }
    return (false, String(decoding: accumulated, as: UTF8.self))
}

/// A shell reading commands from the PTY.
///
/// Deliberately NOT interactive (`-i`): an interactive shell adds prompt and job
/// control noise that is hard to distinguish from output, and none of it is
/// relevant to what these tests check. A non-interactive `sh` still has the PTY
/// as stdin, so `stty` and `tty` behave exactly as they would for a real user.
private func makeShell(size: TerminalSize = .default) throws -> PTY {
    try PTY(
        executable: "/bin/sh",
        arguments: [],
        environment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color",
            "HOME": NSHomeDirectory(),
        ],
        size: size
    )
}

/// ECHO is on, so a command written to the PTY comes back before its output
/// does. A marker spelled out in the command text would therefore match the echo
/// rather than the result, and the test would pass without the shell running at
/// all. Splitting the marker across printf arguments means the echoed command
/// never contains the assembled string.
private func markerCommand(_ marker: String) -> String {
    let midpoint = marker.index(marker.startIndex, offsetBy: marker.count / 2)
    return "printf '%s%s\\n' '\(marker[marker.startIndex..<midpoint])' "
        + "'\(marker[midpoint...])'\n"
}

@Suite("PTY", .serialized)
struct PTYTests {

    @Test("A spawned command's output arrives on the master")
    func spawnAndRead() throws {
        let pty = try PTY(
            executable: "/bin/echo",
            arguments: ["MESHYY_PTY_OK"],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        defer { pty.terminate() }
        let (found, output) = try readUntil(pty, marker: "MESHYY_PTY_OK")
        #expect(found, "expected the marker; got \(output.debugDescription)")
    }

    @Test("Keystrokes written to the master reach the shell")
    func interactiveRoundTrip() throws {
        let pty = try makeShell()
        defer { pty.terminate() }
        try pty.write(Array(markerCommand("MESHYY_ROUNDTRIP").utf8))
        let (found, output) = try readUntil(pty, marker: "MESHYY_ROUNDTRIP")
        #expect(found, "got \(output.debugDescription)")
    }

    /// Design doc §7.1 claims the daemon can read the line discipline from the
    /// master fd. If that were false the whole prediction design would need a
    /// different mechanism, so it is checked rather than believed.
    @Test("A fresh PTY reports cooked mode on the master fd")
    func freshPTYIsCooked() throws {
        let pty = try makeShell()
        defer { pty.terminate() }
        let state = pty.termios()
        #expect(state != nil, "tcgetattr on the master fd must succeed")
        #expect(state?.echo == true, "a fresh PTY echoes")
        #expect(state?.icanon == true, "a fresh PTY is line-buffered")
        #expect(state?.raw == false)
    }

    /// The load-bearing one. A child changes its termios; the daemon must see it
    /// through the master fd with no cooperation from the child.
    ///
    /// Driven with `sh -c` rather than an interactive shell on purpose. An
    /// interactive shell runs readline, which holds the tty in raw mode for its
    /// whole life — see `interactiveShellsAreRawNotCooked` below and
    /// docs/spikes/2026-07-27-line-discipline.md. `sh -c` does no input handling,
    /// so the PTY starts in cooked mode and the transitions are observable.
    @Test("termios read on the master reflects the child's own tcsetattr")
    func termiosOnMasterReflectsChildChanges() throws {
        let script = """
            printf 'PHASE%s\\n' _COOKED
            stty -echo -icanon
            printf 'PHASE%s\\n' _RAW
            sleep 1
            stty sane
            printf 'PHASE%s\\n' _SANE
            sleep 2
            """
        let pty = try PTY(
            executable: "/bin/sh",
            arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )
        defer { pty.terminate() }

        // Cooked before the child touches anything.
        #expect(pty.termios()?.echo == true, "a fresh PTY under a non-interactive sh is cooked")
        #expect(pty.termios()?.icanon == true)

        // Raw, after the child's own stty.
        var sawRaw: TermiosState?
        var deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            _ = try? pty.read()
            if let state = pty.termios(), !state.echo, !state.icanon { sawRaw = state; break }
            usleep(10_000)
        }
        #expect(sawRaw?.echo == false, "the daemon must observe ECHO going away")
        #expect(sawRaw?.icanon == false, "the daemon must observe ICANON going away")
        #expect(sawRaw?.raw == true, "no echo and no icanon is raw mode — do not predict")

        // And back, because a one-way transition would be enough to build a latch
        // bug on.
        var restored = false
        deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            _ = try? pty.read()
            if pty.termios()?.echo == true { restored = true; break }
            usleep(10_000)
        }
        #expect(restored, "leaving raw mode must be observable too")
    }

    /// Documents the M0 finding that reshapes design doc §7, so a future reader
    /// does not mistake it for a bug and "fix" prediction back on.
    ///
    /// §7.3 predicted prediction would be off in an agent TUI and **on at a bare
    /// shell prompt**. It is off at a bare shell prompt too: readline and zle echo
    /// characters themselves and hold the tty in raw mode for the shell's entire
    /// life. Under the §7.2 gate, prediction never engages in any real
    /// configuration.
    ///
    /// See docs/spikes/2026-07-27-line-discipline.md.
    @Test(
        "Interactive shells hold the tty in RAW mode, so the §7.2 gate never opens",
        arguments: [
            ("/bin/bash", ["-i"]),
            ("/bin/zsh", ["-f", "-i"]),
        ]
    )
    func interactiveShellsAreRawNotCooked(shell: (String, [String])) throws {
        let pty = try PTY(
            executable: shell.0,
            arguments: shell.1,
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TERM": "xterm-256color",
                "HOME": NSHomeDirectory(),
            ]
        )
        defer { pty.terminate() }

        // Let the line editor initialise and take the terminal.
        var state: TermiosState?
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            _ = try? pty.read()
            if let observed = pty.termios(), !observed.echo { state = observed; break }
            usleep(20_000)
        }

        #expect(state?.echo == false, "\(shell.0): readline/zle turns kernel ECHO off")
        #expect(state?.icanon == false, "\(shell.0): readline/zle turns ICANON off")

        let gate = PredictionGate(
            termios: state ?? .cooked,
            altScreen: false,
            smoothedRTT: .milliseconds(200)
        )
        #expect(!gate.shouldPredict,
                "prediction must stay off at a real shell prompt — this is the finding, not a bug")
        #expect(gate.reasonPredictionIsOff != nil, "and the reason must be explainable to a user")
    }

    @Test("The child gets the PTY as its controlling terminal")
    func childHasControllingTerminal() throws {
        let pty = try makeShell()
        defer { pty.terminate() }
        // `tty` prints the controlling terminal, or "not a tty" if there is none.
        // Without POSIX_SPAWN_SETSID plus the addopen trick, this fails.
        try pty.write(Array("tty\n".utf8))
        let (found, output) = try readUntil(pty, marker: "/dev/ttys")
        #expect(found, "child has no controlling terminal; got \(output.debugDescription)")
        #expect(!output.contains("not a tty"))
    }

    @Test("The child is a session leader, so job control works")
    func childIsSessionLeader() throws {
        let pty = try makeShell()
        defer { pty.terminate() }
        // A session leader's sid equals its pid.
        #expect(getsid(pty.childPID) == pty.childPID,
                "POSIX_SPAWN_SETSID did not take effect")
    }

    @Test("The initial window size reaches the child")
    func initialSizeIsVisible() throws {
        let pty = try makeShell(size: TerminalSize(cols: 133, rows: 47))
        defer { pty.terminate() }
        try pty.write(Array("stty size\n".utf8))
        let (found, output) = try readUntil(pty, marker: "47 133")
        #expect(found, "expected '47 133'; got \(output.debugDescription)")
    }

    @Test("Resizing is visible to the child")
    func resizeIsVisible() throws {
        let pty = try makeShell(size: TerminalSize(cols: 80, rows: 24))
        defer { pty.terminate() }
        try pty.write(Array(markerCommand("MESHYY_READY").utf8))
        _ = try readUntil(pty, marker: "MESHYY_READY")

        try pty.resize(to: TerminalSize(cols: 100, rows: 30))
        try pty.write(Array("stty size\n".utf8))
        let (found, output) = try readUntil(pty, marker: "30 100")
        #expect(found, "expected '30 100'; got \(output.debugDescription)")
    }

    @Test("A dimension of zero is clamped rather than passed to the kernel")
    func sizeIsClamped() {
        #expect(TerminalSize(cols: 0, rows: 0) == TerminalSize(cols: 1, rows: 1))
        #expect(TerminalSize(cols: -5, rows: -5) == TerminalSize(cols: 1, rows: 1))
        let huge = TerminalSize(cols: 1 << 30, rows: 1 << 30)
        #expect(huge.cols == TerminalSize.maximumDimension)
        #expect(huge.rows == TerminalSize.maximumDimension)
    }

    /// The requirement is that a short-lived child's output is never lost, not
    /// that end of file arrives.
    ///
    /// The daemon holds a slave descriptor precisely so a child that prints and
    /// exits in the same breath does not have its output discarded — on Darwin,
    /// once the last slave closes, a read on the master returns EIO and throws
    /// away whatever was buffered. This test failed on CI (and passed locally on
    /// timing) before that fix. See the note on `PTY.slaveFD`.
    @Test("A child that prints and exits immediately does not lose its output")
    func shortLivedChildOutputSurvives() throws {
        for attempt in 1...10 {
            let pty = try PTY(
                executable: "/bin/echo",
                arguments: ["MESHYY_LAST_WORDS"],
                environment: ["PATH": "/usr/bin:/bin"]
            )
            defer { pty.terminate() }

            // Wait for the child to be gone *first*, so the read races exit as
            // badly as possible — which is what CI does on a slow runner.
            let exitDeadline = Date().addingTimeInterval(3)
            while pty.isChildAlive && Date() < exitDeadline { usleep(5_000) }

            let (found, output) = try readUntil(pty, marker: "MESHYY_LAST_WORDS", timeout: 3)
            #expect(found,
                    "attempt \(attempt): output was discarded at child exit; got \(output.debugDescription)")
            if !found { return }
        }
    }

    @Test("Child exit is observable through waitpid rather than end of file")
    func childExitIsObservable() throws {
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
        #expect(exited, "the child's exit must be visible to waitpid")
    }

    @Test("The child's environment is exactly what was passed")
    func environmentIsExact() throws {
        let pty = try PTY(
            executable: "/bin/sh",
            arguments: ["-c", "echo MARK-$MESHYY_TEST_VAR-$HOME-END"],
            environment: ["PATH": "/usr/bin:/bin", "MESHYY_TEST_VAR": "present"]
        )
        defer { pty.terminate() }
        let (found, output) = try readUntil(pty, marker: "MARK-present--END")
        #expect(found, "environment was not passed verbatim; got \(output.debugDescription)")
    }

    @Test("Spawning a nonexistent executable throws instead of hanging")
    func spawnFailureIsReported() {
        #expect(throws: (any Error).self) {
            try PTY(
                executable: "/nonexistent/meshyy-not-a-binary",
                arguments: [],
                environment: [:]
            )
        }
    }

    @Test("terminate signals the whole process group, not just the shell")
    func terminateKillsGroup() throws {
        // `sh -c` again: an interactive shell would add job-control chatter and
        // its own process-group handling, neither of which is under test here.
        let pty = try PTY(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 300 & printf 'MESHYY%s_%s\\n' _CHILD \"$!\"; sleep 10"],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )
        let (found, output) = try readUntil(pty, marker: "MESHYY_CHILD_")
        #expect(found, "got \(output.debugDescription)")

        guard let range = output.range(of: "MESHYY_CHILD_") else {
            Issue.record("no marker in \(output.debugDescription)")
            pty.terminate()
            return
        }
        let digits = output[range.upperBound...].prefix { $0.isNumber }
        guard let grandchild = pid_t(digits) else {
            Issue.record("no pid after the marker in \(output.debugDescription)")
            pty.terminate()
            return
        }

        #expect(getpgid(grandchild) == pty.childPID,
                "the grandchild must be in the session's process group for a group signal to reach it")
        pty.terminate()

        // SIGHUP to the group should take the backgrounded sleep with it.
        var reaped = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if kill(grandchild, 0) != 0 && errno == ESRCH { reaped = true; break }
            usleep(50_000)
        }
        #expect(reaped, "pid \(grandchild) survived terminate() — the group was not signalled")
    }

    /// Pins the fix for a latent daemon bug: SIG_IGN is inherited across fork and
    /// exec, so if anything in the daemon's process ignores a signal, every shell
    /// meshyyd spawns inherits that and `terminate()` becomes a polite suggestion
    /// that leaks processes silently.
    ///
    /// This test ignores SIGHUP in the *parent* on purpose — reproducing what the
    /// test harness happened to do, and what launchd or a future Dispatch version
    /// might — and asserts the child still dies.
    @Test("A spawned child gets default signal dispositions even if the parent ignores them")
    func childDoesNotInheritIgnoredSignals() throws {
        let previous = signal(SIGHUP, SIG_IGN)
        defer { signal(SIGHUP, previous) }

        let pty = try PTY(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'MESHYY%s\\n' _UP; sleep 30"],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        let (found, output) = try readUntil(pty, marker: "MESHYY_UP")
        #expect(found, "child never started; got \(output.debugDescription)")

        let child = pty.childPID
        pty.terminate()

        var died = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if kill(child, 0) != 0 && errno == ESRCH { died = true; break }
            usleep(50_000)
        }
        #expect(died, "child \(child) inherited the parent's ignored SIGHUP and survived")
    }
}
