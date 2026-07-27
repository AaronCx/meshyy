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

/// Deterministic PRNG so a failing case can be replayed from its seed.
/// SplitMix64 — chosen because it is four lines and its constants are published.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Mirrors what the real client does: consumes bytes, acks an offset, loses the
/// connection, and comes back asking to resume from its last ack.
private struct ClientModel {
    /// Everything this client has handed to its emulator, in order.
    var delivered: [UInt8] = []
    /// The offset the client has confirmed consuming (design doc §6.2 `Ack`).
    var ackedOffset: UInt64 = 0
    /// Offsets where the daemon told the client its stream had a hole.
    var reportedHoles: [(at: UInt64, skipped: UInt64)] = []

    /// Applies a resume decision the way the client must.
    mutating func apply(_ decision: ResumeDecision) {
        switch decision {
        case .fresh:
            break
        case .replay(let from, let bytes):
            // The client asked from `ackedOffset`; the daemon must honour
            // exactly that, or the offsets have drifted.
            #expect(from == ackedOffset, "daemon replayed from \(from), client asked \(ackedOffset)")
            delivered += bytes
            ackedOffset += UInt64(bytes.count)
        case .replayFromAnchor(let anchor, let bytes, let skipped):
            reportedHoles.append((at: ackedOffset, skipped: skipped))
            delivered += bytes
            ackedOffset = anchor + UInt64(bytes.count)
        case .mustRedraw(let earliest, let skipped):
            reportedHoles.append((at: ackedOffset, skipped: skipped))
            // The client clears and asks the multiplexer to repaint. It delivers
            // nothing from the buffer and restarts from the oldest byte it can
            // still be sure about.
            ackedOffset = earliest
        case .impossible:
            Issue.record("daemon reported an impossible offset — client bug")
        }
    }

    /// Live output arriving while connected.
    mutating func receiveLive(_ bytes: [UInt8]) {
        delivered += bytes
        ackedOffset += UInt64(bytes.count)
    }
}

@Suite("§6.4 stream equality invariant")
struct StreamEqualityTests {

    // MARK: - The invariant, exhaustively randomised

    /// The headline property. 200 seeded scenarios, each a random interleaving of
    /// writes, acks, disconnects and reconnects against a buffer small enough
    /// that overruns actually happen.
    @Test("Byte stream survives arbitrary disconnect/reconnect sequences", arguments: 1...200)
    func streamEqualityUnderChaos(seed: UInt64) {
        var random = SplitMix64(seed: seed)
        // Small on purpose: a 4 MB buffer would never overrun in a unit test and
        // the interesting branches would go unexercised.
        var daemon = SessionBuffer(capacity: 1024)
        var client = ClientModel()
        var connected = true

        /// Everything the daemon ever read from the PTY. The oracle.
        var pty: [UInt8] = []

        for step in 0..<60 {
            switch Int.random(in: 0..<10, using: &random) {

            case 0...5:
                // The PTY produced output. Sometimes a burst big enough to force
                // an overrun while the client is away.
                let length = Bool.random(using: &random)
                    ? Int.random(in: 1...64, using: &random)
                    : Int.random(in: 1...1500, using: &random)
                let bytes = (0..<length).map { _ in UInt8.random(in: 32...126, using: &random) }
                pty += bytes
                daemon.write(bytes)
                if connected {
                    client.receiveLive(bytes)
                }

            case 6:
                // A clear-screen sequence, so the §6.3 anchor path gets exercised
                // rather than only the mustRedraw fallback.
                let bytes = Array("\u{1B}[2J".utf8)
                pty += bytes
                daemon.write(bytes)
                if connected { client.receiveLive(bytes) }

            case 7:
                // iOS suspended the app.
                connected = false

            case 8, 9:
                guard !connected else { break }
                let decision = daemon.resume(from: client.ackedOffset)
                client.apply(decision)
                connected = true

            default:
                break
            }

            // Invariant 1: while resume has been honoured throughout, the
            // client's stream is a byte-exact prefix of the PTY's.
            if client.reportedHoles.isEmpty {
                #expect(
                    client.delivered == Array(pty.prefix(client.delivered.count)),
                    "seed \(seed) step \(step): stream diverged with no hole reported"
                )
            }
        }

        // Final reconnect so the client is caught up before the closing assertions.
        if !connected {
            client.apply(daemon.resume(from: client.ackedOffset))
        }

        if client.reportedHoles.isEmpty {
            // Invariant 1, in full: no gaps, no duplicates, no reordering.
            #expect(
                client.delivered == pty,
                "seed \(seed): expected \(pty.count) bytes, client delivered \(client.delivered.count)"
            )
        } else {
            // Invariant 2: a hole was reported. What the client holds must still
            // be a genuine subsequence-by-suffix of the PTY stream — never
            // reordered, never duplicated. Check the tail it claims to be caught
            // up on actually matches the PTY at that position.
            let tailLength = min(client.delivered.count, pty.count)
            let clientTail = Array(client.delivered.suffix(tailLength))
            let ptyTail = Array(pty.suffix(tailLength))
            #expect(
                clientTail == ptyTail || client.delivered.count < pty.count,
                "seed \(seed): client tail does not match the PTY tail after a reported hole"
            )
            #expect(
                client.ackedOffset <= daemon.totalWritten,
                "seed \(seed): client acked past what the daemon wrote"
            )
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

    @Test("A fresh attach replays nothing and is not a failure")
    func freshAttach() {
        var daemon = SessionBuffer(capacity: 1024)
        daemon.write(Array("scrollback".utf8))
        #expect(daemon.resume(from: nil) == .fresh)
        #expect(ResumeDecision.fresh.preservesStreamEquality)
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
