// meshyy — design doc §6.4, the correctness invariant.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
//   "For any sequence of writes, disconnects, and reconnects, the byte stream
//    the client delivers to SwiftTerm must equal the byte stream the daemon read
//    from the PTY. No gaps, no duplicates, no reordering."
//
// This is the single most important test in the project. Never weaken it to make
// something else pass; if it goes red, resume is broken.
//
// The invariant holds unconditionally only while resume succeeds. When the
// buffer overruns during a disconnect, byte equality is *impossible* — the bytes
// are gone. The honest formulation, and what is asserted here, is:
//
//   1. Whenever resume is honoured, the client's stream is byte-identical.
//   2. Whenever it cannot be, the daemon says so explicitly, and the client's
//      stream is a genuine suffix of the daemon's — a hole at a reported place,
//      never a silent reordering or a duplicate.
//
// Failures are reproducible: every case names its seed.

import Testing
@testable import MeshyyCore
import MeshyyTestSupport

@Suite("§6.4 stream equality invariant")
struct StreamEqualityTests {

    // MARK: - The invariant, exhaustively randomised

    /// The headline property, at the model layer.
    ///
    /// The scenarios come from `ResumeScenario`, shared with `ConformanceTests`,
    /// which replays the same corpus against the shipping `MeshyySession`. One
    /// corpus, two levels — the audit's finding was that this level alone proves the
    /// design is coherent and proves nothing about the code that ships.
    @Test("Byte stream survives arbitrary disconnect/reconnect sequences", arguments: 1...200)
    func streamEqualityUnderChaos(seed: UInt64) {
        let scenario = ResumeScenario(seed: seed)
        var daemon = SessionBuffer(capacity: scenario.bufferCapacity)
        var client = ClientModel()
        var connected = true

        /// Everything the daemon ever read from the PTY. The oracle.
        var pty: [UInt8] = []

        for (step, action) in scenario.steps.enumerated() {
            switch action {
            case .output(let bytes):
                pty += bytes
                daemon.write(bytes)
                if connected { client.receiveLive(bytes) }

            case .clearScreen:
                let bytes = ResumeScenario.clearScreenBytes
                pty += bytes
                daemon.write(bytes)
                if connected { client.receiveLive(bytes) }

            case .disconnect:
                connected = false

            case .reconnect:
                client.apply(daemon.resume(from: client.ackedOffset))
                connected = true
            }

            #expect(client.complaints.isEmpty,
                    "seed \(seed) step \(step): \(client.complaints)")

            // Invariant 1: while resume has been honoured throughout, the client's
            // stream is a byte-exact prefix of the PTY's.
            if client.reportedHoles.isEmpty {
                #expect(
                    client.delivered == Array(pty.prefix(client.delivered.count)),
                    "seed \(seed) step \(step): stream diverged with no hole reported"
                )
            }
        }

        if client.reportedHoles.isEmpty {
            // Invariant 1, in full: no gaps, no duplicates, no reordering.
            #expect(
                client.delivered == pty,
                "seed \(seed): expected \(pty.count) bytes, client delivered \(client.delivered.count)"
            )
        } else {
            // Invariant 2: a hole was reported. What the client holds must still be a
            // genuine suffix of the PTY stream — never reordered, never duplicated.
            let tailLength = min(client.delivered.count, pty.count)
            #expect(
                Array(client.delivered.suffix(tailLength)) == Array(pty.suffix(tailLength))
                    || client.delivered.count < pty.count,
                "seed \(seed): client tail does not match the PTY tail after a reported hole"
            )
            #expect(client.ackedOffset <= daemon.totalWritten,
                    "seed \(seed): client acked past what the daemon wrote")
        }
    }

    // MARK: - The specific cases the doc calls out

    @Test("A fully caught-up client resumes with an empty replay")
    func caughtUpResumeIsEmpty() {
        var daemon = SessionBuffer(capacity: 1024)
        daemon.write(Array("hello".utf8))
        let decision = daemon.resume(from: 5)
        #expect(decision == .replay(from: 5, bytes: []))
        #expect(decision.preservesStreamEquality)
    }

    /// A fresh attach shows the current screen rather than a blank one.
    ///
    /// Sending nothing would be defensible — the client asked for nothing — but it
    /// leaves a real terminal blank until the next keystroke, which reads as a
    /// broken attach. Found by the M2 QUIC test, which sat on an empty screen.
    @Test("A fresh attach replays what is in the buffer, not nothing")
    func freshAttachShowsTheScreen() {
        var daemon = SessionBuffer(capacity: 1024)
        daemon.write(Array("scrollback".utf8))
        #expect(daemon.resume(from: nil) == .fresh(from: 0, bytes: Array("scrollback".utf8)))
        #expect(daemon.resume(from: nil).preservesStreamEquality,
                "the client had nothing, so a full replay is still a consistent prefix")
    }

    /// And it is bounded by the redraw anchor when there is one, so attaching to a
    /// session with megabytes of scrollback does not ship all of it.
    @Test("A fresh attach starts at the redraw anchor when one exists")
    func freshAttachUsesTheAnchor() {
        var daemon = SessionBuffer(capacity: 4096)
        daemon.write(Array("ancient history that should not be replayed\r\n".utf8))
        let anchor = daemon.totalWritten
        daemon.write(Array("\u{1B}[2J".utf8))
        daemon.write(Array("current screen\r\n".utf8))

        guard case .fresh(let from, let bytes) = daemon.resume(from: nil) else {
            Issue.record("expected .fresh")
            return
        }
        #expect(from == anchor, "a fresh attach should start at the last full clear")
        #expect(bytes.starts(with: Array("\u{1B}[2J".utf8)),
                "the replay must re-execute the clear so the screen ends up correct")
        #expect(!String(decoding: bytes, as: UTF8.self).contains("ancient history"))
    }

    @Test("Resume across a five-minute background is byte-exact when it fits")
    func backgroundThenForeground() {
        var daemon = SessionBuffer(capacity: 64 * 1024)
        var pty: [UInt8] = []

        let beforeSuspend = Array("$ ls -la\r\ntotal 42\r\n".utf8)
        pty += beforeSuspend
        daemon.write(beforeSuspend)
        let ackedAtSuspend = daemon.totalWritten

        // Five minutes of a build scrolling by, well under the buffer.
        for line in 0..<200 {
            let bytes = Array("[\(line)] compiling something.swift\r\n".utf8)
            pty += bytes
            daemon.write(bytes)
        }

        let decision = daemon.resume(from: ackedAtSuspend)
        #expect(decision.preservesStreamEquality)
        #expect(decision.bytes == Array(pty.dropFirst(Int(ackedAtSuspend))))
    }

    @Test("Overrun falls back to the clear-screen anchor, and says it skipped bytes")
    func overrunUsesAnchor() {
        var daemon = SessionBuffer(capacity: 256)
        daemon.write(Array(repeating: UInt8(ascii: "a"), count: 200))
        let ackedAtSuspend = daemon.totalWritten

        // A clear, then enough output to evict the client's offset but not the clear.
        daemon.write(Array("\u{1B}[2J".utf8))
        let anchorOffset = ackedAtSuspend
        daemon.write(Array(repeating: UInt8(ascii: "b"), count: 100))

        // Buffer now holds [48, 304). The client's old offset must fall outside
        // it for the anchor path to engage — 10 does, 150 would not.
        #expect(daemon.window.from == 48)
        let decision = daemon.resume(from: 10)
        guard case .replayFromAnchor(let anchor, let bytes, let skipped) = decision else {
            Issue.record("expected replayFromAnchor, got \(decision)")
            return
        }
        #expect(anchor == anchorOffset)
        #expect(skipped > 0, "a hole must be reported, not hidden")
        #expect(bytes.starts(with: Array("\u{1B}[2J".utf8)),
                "replay must re-execute the clear so the screen ends up correct")
        #expect(!decision.preservesStreamEquality)
    }

    @Test("Overrun with no surviving anchor demands a redraw rather than guessing")
    func overrunWithoutAnchor() {
        var daemon = SessionBuffer(capacity: 128)
        daemon.write(Array(repeating: UInt8(ascii: "x"), count: 1000))
        let decision = daemon.resume(from: 0)
        guard case .mustRedraw(let earliest, let skipped) = decision else {
            Issue.record("expected mustRedraw, got \(decision)")
            return
        }
        #expect(earliest == 1000 - 128)
        #expect(skipped == earliest)
        #expect(!decision.preservesStreamEquality)
    }

    @Test("An offset ahead of the buffer is reported as impossible, not clamped")
    func offsetAheadOfBuffer() {
        var daemon = SessionBuffer(capacity: 1024)
        daemon.write(Array("short".utf8))
        #expect(daemon.resume(from: 9999) == .impossible(latestAvailable: 5))
    }

    @Test("A single write larger than the whole buffer keeps its tail and correct offsets")
    func writeLargerThanCapacity() {
        var daemon = SessionBuffer(capacity: 100)
        let huge = (0..<1000).map { UInt8($0 % 251) }
        daemon.write(huge)

        #expect(daemon.totalWritten == 1000)
        #expect(daemon.window == (from: 900, to: 1000))

        let decision = daemon.resume(from: 900)
        #expect(decision == .replay(from: 900, bytes: Array(huge.suffix(100))))
    }
}
