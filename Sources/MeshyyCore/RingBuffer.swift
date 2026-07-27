// meshyy — per-session replay buffer (design doc §6.2).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// The core of the project. Raw PTY bytes with a monotonic byte offset; on
// reconnect the client asks for everything from the offset it last consumed and
// feeds it to its emulator exactly as if it had arrived live.
//
// Why bytes and not screen state: see docs/provenance.md, 2026-07-27.

import Foundation

/// A fixed-capacity byte buffer that remembers the absolute offset of every byte
/// it still holds.
///
/// Offsets are absolute and monotonic for the life of the session — they count
/// every byte ever written, not the position within storage. `totalWritten` only
/// ever grows; `earliestAvailable` grows as old bytes are evicted.
///
/// Not thread-safe by itself. The daemon owns one per session behind an actor.
public struct RingBuffer: Sendable {
    /// Design doc §6.2 default. §12.3 flags this as a guess to instrument.
    public static let defaultCapacity = 4 * 1024 * 1024

    private var storage: [UInt8]
    /// Index in `storage` where the next byte goes.
    private var writeIndex = 0
    /// Absolute count of bytes ever written. The offset of the next byte.
    public private(set) var totalWritten: UInt64 = 0
    /// True once the buffer has wrapped and is evicting.
    private var wrapped = false

    public let capacity: Int

    public init(capacity: Int = RingBuffer.defaultCapacity) {
        precondition(capacity > 0, "ring buffer capacity must be positive")
        self.capacity = capacity
        self.storage = [UInt8](repeating: 0, count: capacity)
    }

    /// Oldest offset still replayable. Equals `totalWritten` only when empty.
    public var earliestAvailable: UInt64 {
        wrapped ? totalWritten - UInt64(capacity) : 0
    }

    /// Newest offset, one past the last byte written.
    public var latestAvailable: UInt64 { totalWritten }

    public var count: Int {
        wrapped ? capacity : writeIndex
    }

    public var isEmpty: Bool { count == 0 }

    /// Appends `bytes`, evicting the oldest as needed.
    ///
    /// A write larger than the whole buffer keeps only its tail — the bytes that
    /// would have survived eviction anyway — so the offset arithmetic stays
    /// identical to the byte-at-a-time case. `totalWritten` still advances by the
    /// full length, because it counts bytes read from the PTY, not bytes stored.
    public mutating func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }

        if bytes.count >= capacity {
            let tail = bytes.suffix(capacity)
            storage.replaceSubrange(0..<capacity, with: tail)
            writeIndex = 0
            wrapped = true
            totalWritten += UInt64(bytes.count)
            return
        }

        let firstChunk = min(capacity - writeIndex, bytes.count)
        storage.replaceSubrange(
            writeIndex..<(writeIndex + firstChunk),
            with: bytes[0..<firstChunk]
        )
        if firstChunk < bytes.count {
            let remainder = bytes.count - firstChunk
            storage.replaceSubrange(0..<remainder, with: bytes[firstChunk...])
            wrapped = true
            writeIndex = remainder
        } else {
            writeIndex += firstChunk
            if writeIndex == capacity {
                writeIndex = 0
                wrapped = true
            }
        }
        totalWritten += UInt64(bytes.count)
    }

    public mutating func append(_ bytes: some Sequence<UInt8>) {
        append(Array(bytes))
    }

    /// Why a replay request cannot be served.
    public enum ReplayFailure: Error, Equatable, CustomStringConvertible {
        /// The requested offset has been evicted. The daemon answers with
        /// `ResumeTooOld { earliestOffset }` (design doc §6.3).
        case tooOld(earliestAvailable: UInt64)
        /// The client claims an offset the daemon has never produced. Only
        /// happens on a session-id mix-up or a client bug, and it must not be
        /// papered over — design doc §3.5, fail visible.
        case aheadOfBuffer(latestAvailable: UInt64)

        public var description: String {
            switch self {
            case .tooOld(let earliest):
                "resume offset predates the buffer; earliest available is \(earliest)"
            case .aheadOfBuffer(let latest):
                "resume offset is ahead of anything written; latest is \(latest)"
            }
        }
    }

    /// Every byte from `offset` to the newest, in order.
    ///
    /// `offset == latestAvailable` is a success returning nothing: a client that
    /// is fully caught up resumes with an empty replay, which is the common case
    /// on a fast foreground.
    public func replay(from offset: UInt64) throws -> [UInt8] {
        if offset > totalWritten { throw ReplayFailure.aheadOfBuffer(latestAvailable: totalWritten) }
        if offset < earliestAvailable { throw ReplayFailure.tooOld(earliestAvailable: earliestAvailable) }

        let wanted = Int(totalWritten - offset)
        guard wanted > 0 else { return [] }

        let stored = count
        // `wanted <= stored` is guaranteed by the two bounds checks above.
        let start = (writeIndex - wanted + capacity * 2) % capacity
        if wrapped || start + wanted > stored {
            var result = [UInt8]()
            result.reserveCapacity(wanted)
            for step in 0..<wanted {
                result.append(storage[(start + step) % capacity])
            }
            return result
        }
        return Array(storage[start..<(start + wanted)])
    }

    /// The window the daemon reports in `Welcome`.
    public var window: (from: UInt64, to: UInt64) {
        (earliestAvailable, latestAvailable)
    }
}
