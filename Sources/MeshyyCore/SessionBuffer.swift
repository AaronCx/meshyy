// meshyy — the resume decision (design doc §6).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Ring buffer plus screen scanner plus the one decision that matters: given the
// offset a reconnecting client claims, what does the daemon send back?
//
// This lives in MeshyyCore rather than the daemon so the §6.4 property test
// drives the real logic. A property test against a mock proves nothing.

import Foundation

/// What the daemon does with a client's resume request.
public enum ResumeDecision: Sendable, Equatable {
    /// Resume honoured exactly. `bytes` is everything from the requested offset
    /// to the newest byte, and the client's stream stays byte-identical to the
    /// PTY's.
    case replay(from: UInt64, bytes: [UInt8])

    /// The requested offset is gone, but a full-redraw anchor survives inside
    /// the buffer. Replaying from it re-executes the clear or alt-screen entry,
    /// so the client's screen ends up correct even though its byte stream now
    /// has a hole. Design doc §6.3.
    ///
    /// The hole is reported, not hidden: `skipped` is how many bytes were lost.
    case replayFromAnchor(anchor: UInt64, bytes: [UInt8], skipped: UInt64)

    /// Neither the offset nor an anchor survives. The client must clear and ask
    /// the multiplexer to repaint (design doc §6.3). Costs ~4 ms per
    /// docs/benchmarks.md — not a path worth engineering around.
    ///
    /// `bytes` is the whole surviving window, exactly what a FRESH attach on the
    /// same buffer would get. It used to be empty, and the two failures that
    /// caused were both silent:
    ///
    ///  * A client that fell out of the ring got NOTHING, forever. Measured: a
    ///    fresh attach on an unchanging wrapped ring delivered 262144 bytes,
    ///    while a resume one byte too old delivered 0 — and since the client's
    ///    offset then stayed a full ring behind, its next attach was too old
    ///    again. A ratchet: attach after attach, never a byte, never a screen.
    ///  * `replayBase` announced `earliestAvailable` while replaying nothing, so
    ///    the client's offset ended up exactly one ring capacity stale and the
    ///    next replay overlapped bytes it had already drawn — duplication, which
    ///    §6.4 exists to make impossible.
    ///
    /// Replaying the window fixes both: the base is where the bytes really start.
    case mustRedraw(earliestAvailable: UInt64, bytes: [UInt8], skipped: UInt64)

    /// No prior offset: the client has never seen this session.
    ///
    /// Replays from the most recent full-redraw anchor if one survives, else from
    /// the oldest byte still held. Sending nothing would be defensible — the client
    /// asked for nothing — but it leaves a real terminal blank until the next
    /// keystroke, which reads as a broken attach. Anchoring bounds the replay in
    /// the common case (any clear or alt-screen entry) and falls back to the whole
    /// buffer only for a session that has never redrawn.
    case fresh(from: UInt64, bytes: [UInt8])

    /// The client claimed an offset the daemon never produced. A session-id
    /// mix-up or a client bug. Design doc §3.5: never silently degrade.
    case impossible(latestAvailable: UInt64)

    /// Bytes to write to the client's emulator, if any.
    public var bytes: [UInt8] {
        switch self {
        case .replay(_, let bytes): bytes
        case .replayFromAnchor(_, let bytes, _): bytes
        case .fresh(_, let bytes): bytes
        case .mustRedraw(_, let bytes, _): bytes
        case .impossible: []
        }
    }

    /// Absolute offset the replayed bytes begin at, which is what the client needs
    /// to keep its own offset arithmetic exact. Sent as `replayBase`.
    public var replayBase: UInt64 {
        switch self {
        case .replay(let from, _): from
        case .replayFromAnchor(let anchor, _, _): anchor
        case .fresh(let from, _): from
        // Where the replayed window actually begins — which is the oldest byte
        // the daemon can still vouch for.
        case .mustRedraw(let earliest, _, _): earliest
        case .impossible(let latest): latest
        }
    }

    /// True when the client's byte stream remains exactly equal to the PTY's —
    /// the §6.4 invariant. False means the client must be told the screen was
    /// rebuilt rather than continued.
    public var preservesStreamEquality: Bool {
        switch self {
        case .replay, .fresh: true
        case .replayFromAnchor, .mustRedraw, .impossible: false
        }
    }
}

/// One session's replayable output.
public struct SessionBuffer: Sendable {
    private var ring: RingBuffer
    private var scanner = ScreenScanner()

    public init(capacity: Int = RingBuffer.defaultCapacity) {
        self.ring = RingBuffer(capacity: capacity)
    }

    /// Absolute offset one past the last byte read from the PTY.
    public var totalWritten: UInt64 { ring.totalWritten }
    public var window: (from: UInt64, to: UInt64) { ring.window }
    public var altScreenActive: Bool { scanner.altScreenActive }
    /// Tracked DEC private modes currently set — what a fresh emulator must be
    /// told before replay means anything to it.
    public var activeModes: Set<Int> { scanner.activeModes }
    public var capacity: Int { ring.capacity }

    /// Records output read from the PTY. Returns the screen events it contained,
    /// which the daemon forwards as `ScreenMode` frames (design doc §7.1).
    @discardableResult
    public mutating func write(_ bytes: [UInt8]) -> [ScreenScanner.Event] {
        let offset = ring.totalWritten
        ring.append(bytes)
        return scanner.scan(bytes, startingAt: offset)
    }

    /// What a client that has never seen this session gets.
    private func freshAttach() -> ResumeDecision {
        let window = ring.window
        let from = scanner.replayAnchor(notOlderThan: window.from) ?? window.from
        return .fresh(from: from, bytes: (try? ring.replay(from: from)) ?? [])
    }

    /// Decides what a (re)connecting client gets.
    ///
    /// `resumeFrom` is nil for a fresh attach. The ordering here matters: an
    /// offset ahead of the buffer is a different failure from one behind it, and
    /// collapsing them would hide a client bug behind a routine cache miss.
    public func resume(from resumeFrom: UInt64?) -> ResumeDecision {
        guard let offset = resumeFrom else { return freshAttach() }

        do {
            return .replay(from: offset, bytes: try ring.replay(from: offset))
        } catch RingBuffer.ReplayFailure.aheadOfBuffer(let latest) {
            return .impossible(latestAvailable: latest)
        } catch RingBuffer.ReplayFailure.tooOld(let earliest) {
            // Design doc §6.3: rather than dumping megabytes, replay from the
            // most recent point the screen was thrown away.
            if let anchor = scanner.replayAnchor(notOlderThan: earliest),
               let bytes = try? ring.replay(from: anchor) {
                return .replayFromAnchor(
                    anchor: anchor,
                    bytes: bytes,
                    skipped: anchor > offset ? anchor - offset : 0
                )
            }
            // The whole surviving window, exactly as `freshAttach` would send it.
            // Announcing a base while sending nothing is what left a fallen-behind
            // client blank forever and its offset a ring capacity stale.
            let window = ring.window
            return .mustRedraw(
                earliestAvailable: window.from,
                bytes: (try? ring.replay(from: window.from)) ?? [],
                skipped: window.from > offset ? window.from - offset : 0
            )
        } catch {
            // RingBuffer.replay throws only the two cases above. Anything else
            // is a programming error, and guessing would violate §3.5.
            return .impossible(latestAvailable: ring.totalWritten)
        }
    }
}
