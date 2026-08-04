// meshyy — a client that fell out of the ring must still be given the window.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Two failures lived in one branch, and both were silent.
//
// A resume whose offset had been evicted returned `.mustRedraw` with NO bytes,
// while a FRESH attach on the identical buffer replayed the whole surviving
// window. So a client that fell behind got nothing — and, because the decision
// also announced `replayBase = earliestAvailable` while sending nothing, its
// offset ended up exactly one ring capacity stale. Its next attach was therefore
// too old again: a ratchet, attach after attach, never a byte and never a screen.
// The stale base is also how the same bytes could be delivered twice, which is
// the §6.4 invariant's whole reason for existing.

import Foundation
import Testing
@testable import MeshyyCore

@Suite("Resume window")
struct ResumeWindowTests {

    /// Deterministic printable payload, so a duplicate or a gap changes the
    /// bytes rather than merely the count.
    private func payload(_ count: Int, seed: Int = 0) -> [UInt8] {
        let printable = Array(0x20...0x7E)
        return (0..<count).map { UInt8(printable[($0 * 7 + seed * 31) % printable.count]) }
    }

    /// Fills a buffer past its capacity so the oldest bytes are evicted.
    private func overrun(capacity: Int) -> SessionBuffer {
        var buffer = SessionBuffer(capacity: capacity)
        for chunk in 0..<8 { _ = buffer.write(payload(capacity / 2, seed: chunk)) }
        return buffer
    }

    @Test("A too-old resume gets the same window a fresh attach would")
    func tooOldResumeGetsTheWindow() {
        var buffer = overrun(capacity: 4096)
        let fresh = buffer.resume(from: nil)
        let evicted = buffer.resume(from: 0)   // long gone

        #expect(!evicted.bytes.isEmpty, """
            a resume whose offset had been evicted delivered NOTHING while a fresh \
            attach on the same buffer delivered \(fresh.bytes.count) bytes — the \
            client stays blank, and its next attach is too old again
            """)
        #expect(evicted.bytes.count == fresh.bytes.count,
                "the two paths disagree on the same buffer: \(evicted.bytes.count) vs \(fresh.bytes.count)")
    }

    /// THE OFFSET PROPERTY. Whatever is replayed, the announced base must be the
    /// offset of the FIRST byte replayed — that is the arithmetic the client's
    /// own offset is built on, and a base that lies by a ring capacity is how
    /// bytes get delivered twice.
    @Test("replayBase is the offset of the first byte actually delivered")
    func replayBaseMatchesTheFirstByte() {
        var buffer = overrun(capacity: 4096)
        let window = buffer.window

        for decision in [buffer.resume(from: nil), buffer.resume(from: 0),
                         buffer.resume(from: window.from + 10)] {
            guard !decision.bytes.isEmpty else {
                Issue.record("\(decision) delivered no bytes at all")
                continue
            }
            let base = decision.replayBase
            // Re-resume from the announced base: whatever the base names must be
            // where these very bytes start.
            let claimed = buffer.resume(from: base).bytes
            #expect(claimed == decision.bytes, """
                \(decision) announced base \(base), but replaying from there yields \
                different bytes than it delivered — the client's offset arithmetic \
                is now wrong by the difference, which duplicates or skips on the \
                NEXT resume
                """)
        }
    }

    /// And the ratchet itself: a client that falls behind must recover, not be
    /// pushed further behind by every attempt.
    @Test("A fallen-behind client catches up rather than ratcheting")
    func fallenBehindClientCatchesUp() {
        var buffer = SessionBuffer(capacity: 4096)
        for chunk in 0..<8 { _ = buffer.write(payload(2048, seed: chunk)) }

        // Attach far behind, then follow the protocol: consume what you are given
        // and resume from base + count.
        var offset: UInt64 = 0
        var lastDelivered = 0
        for attempt in 1...3 {
            let decision = buffer.resume(from: offset)
            lastDelivered = decision.bytes.count
            #expect(lastDelivered > 0,
                    "attach \(attempt) delivered nothing; the client can never catch up")
            offset = decision.replayBase + UInt64(decision.bytes.count)
            // A little more output between attaches, well inside the ring.
            _ = buffer.write(payload(64, seed: attempt))
        }
        #expect(offset >= buffer.window.to - 4096,
                "after three attaches the client is still a ring behind (offset \(offset), head \(buffer.window.to))")
        #expect(lastDelivered > 0)
    }
}
