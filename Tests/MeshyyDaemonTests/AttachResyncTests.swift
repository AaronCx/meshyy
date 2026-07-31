// meshyy — an attach must repair a program that drifted out of sync with the PTY.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// THE BUG THIS EXISTS FOR.
//
// The kernel sends SIGWINCH on TIOCSWINSZ only when the size actually CHANGES, and
// `PTYSession.resize` returns early when the requested size equals the recorded one.
// Both are right for a live resize. Together they make one state unrecoverable: a
// full-screen program that is out of sync with a PTY that is already the correct size.
//
// Nothing can fix it. The client sends the right number every time it attaches, the
// daemon compares it against the number it already holds, and neither the ioctl nor the
// signal ever happens. The program stays wrong for the life of the session.
//
// Observed on a real session: the PTY was 74x64 while tmux was still drawing 74x39
// hours later, with the phone re-sending 74x64 on every attach. It reads as "resizing
// doesn't work at all", and the resize path was working perfectly — there was simply
// nothing left for it to do. Verified against the kernel directly: re-applying an
// unchanged size produces no signal.
//
// It does not happen over plain SSH, because a dropped SSH connection closes the PTY
// and there is no surviving program left to be out of sync. It is a cost of keeping the
// shell alive, which makes it meshyy's to pay.

import Foundation
import MeshyyCore
import Synchronization
import Testing
@testable import MeshyyDaemon

/// A child that reports the size it is told about, every time it is told.
///
/// The whole failure is a signal that never arrives, so the assertion has to be on what
/// the CHILD saw. Asserting on the size the daemon recorded passes against the broken
/// code — it recorded the right number and told nobody.
private func makeSizeReporter(size: TerminalSize) throws -> PTY {
    try PTY(
        executable: "/bin/sh",
        arguments: ["-c", "trap 'stty size' WINCH; while :; do sleep 0.05; done"],
        environment: ["PATH": "/usr/bin:/bin"],
        size: size
    )
}

/// Drains for `seconds`, returning everything the child printed.
private func drain(_ pty: PTY, seconds: Double) throws -> String {
    var accumulated = [UInt8]()
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        guard let chunk = try pty.read() else { break }
        if chunk.isEmpty { usleep(5_000); continue }
        accumulated += chunk
    }
    return String(decoding: accumulated, as: UTF8.self)
}

@Suite("Attach resync", .serialized)
struct AttachResyncTests {

    /// THE PROPERTY. An attach makes the foreground program re-read the size even when
    /// the size did not change.
    @Test("An attach re-signals the size even when nothing changed")
    func attachResyncsAnUnchangedSize() throws {
        let pty = try makeSizeReporter(size: TerminalSize(cols: 74, rows: 39))
        defer { pty.terminate() }
        // Let the trap be installed before anything is signalled, or this races the
        // shell's startup and fails for a reason unrelated to the fix.
        _ = try drain(pty, seconds: 0.7)

        // The PTY is already 74x39 and the client attaches at 74x39 — the exact state
        // that used to be unrecoverable.
        try pty.resyncSize(to: TerminalSize(cols: 74, rows: 39))
        let reported = try drain(pty, seconds: 1.0)

        #expect(reported.contains("39 74"), """
            the child was never told the size on an attach that did not change it \
            (saw \(reported.debugDescription)). A program that drifted out of sync with a \
            PTY that is already the right size can then never be corrected — which is the \
            terminal that stops filling the screen and never recovers
            """)
    }

    /// The ordinary path must keep working: a real change still resizes and still
    /// signals, exactly as before. A fix that signals on every attach must not have
    /// been bought by breaking the case that already worked.
    @Test("A changed size still reaches the child")
    func changedSizeStillApplies() throws {
        let pty = try makeSizeReporter(size: TerminalSize(cols: 74, rows: 39))
        defer { pty.terminate() }
        _ = try drain(pty, seconds: 0.7)

        try pty.resize(to: TerminalSize(cols: 74, rows: 64))
        let reported = try drain(pty, seconds: 1.0)

        #expect(reported.contains("64 74"),
                "a genuine resize did not reach the child (saw \(reported.debugDescription))")
    }

    /// The negative control, which is what makes the resync tests meaningful: the RAW
    /// PTY apply (`PTY.resize`, kernel semantics only) really does signal nobody when
    /// the size is unchanged. Without this, `attachResyncsAnUnchangedSize` could be
    /// passing because the kernel signals on every ioctl, and the fix would be
    /// untested. Note this pins the KERNEL's behaviour at the PTY layer — the SESSION
    /// layer now deliberately repairs on every resize (see the test below).
    @Test("The raw PTY apply stays silent when the size is unchanged")
    func unchangedResizeSignalsNobody() throws {
        let pty = try makeSizeReporter(size: TerminalSize(cols: 74, rows: 39))
        defer { pty.terminate() }
        _ = try drain(pty, seconds: 0.7)

        try pty.resize(to: TerminalSize(cols: 74, rows: 39))
        let reported = try drain(pty, seconds: 0.8)

        #expect(!reported.contains("39 74"), """
            re-applying an unchanged size DID signal the child, so the premise of the \
            resync fix no longer holds and `attachResyncsAnUnchangedSize` is proving \
            nothing — re-derive both before trusting either
            """)
    }

    /// THE MID-SESSION REPAIR. A client re-sending a size the PTY already has must
    /// still reach the foreground program.
    ///
    /// The old session-level early return was correct while the transport flapped —
    /// any missed WINCH was repaired seconds later by a reattach's resync. The
    /// heartbeat fix removed the flapping, and with it the accidental repair:
    /// measured on a real session, a tmux client that missed one WINCH drew 74x39
    /// against a 74x64 PTY for a DAY, with the phone re-sending the right size on
    /// every keyboard toggle and the daemon answering every one with silence.
    @Test("A mid-session resize repairs a program that missed its signal")
    func unchangedResizeStillRepairs() async throws {
        let session = try PTYSession(
            name: "resize-repair",
            executable: "/bin/sh",
            arguments: ["-c", "trap 'stty size' WINCH; while :; do sleep 0.05; done"],
            environment: ["PATH": "/usr/bin:/bin"],
            size: TerminalSize(cols: 74, rows: 39)
        )
        await session.start()
        let (_, events, token) = await session.attach(resumeFrom: nil)
        let box = Mutex("")
        let pump = Task {
            for await event in events {
                if case .output(_, let bytes) = event {
                    box.withLock { $0 += String(decoding: bytes, as: UTF8.self) }
                }
            }
        }
        // Let the trap be installed before signalling, same as the PTY-level tests.
        try await Task.sleep(for: .milliseconds(700))

        // The exact stuck state: the PTY is already 74x39, the client sends 74x39.
        try await session.resize(to: TerminalSize(cols: 74, rows: 39))

        var seen = ""
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            seen = box.withLock { $0 }
            if seen.contains("39 74") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        pump.cancel()
        await session.detach(token)
        await session.close()
        #expect(seen.contains("39 74"), """
            a mid-session resize to an unchanged size signalled nobody \
            (saw \(seen.debugDescription)) — a program that missed one WINCH now stays \
            wrong for the life of a session that no longer reattaches
            """)
    }
}
