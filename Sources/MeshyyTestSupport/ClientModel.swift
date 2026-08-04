// meshyy — the reference client, used as a differential oracle (hardening 1b-bis).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// A deliberately simple reimplementation of what a client must do with a
// `ResumeDecision`. Checking a production implementation against a simple reference
// one is differential testing, and it is worth keeping.
//
// The defect the 1a audit found was NOT that this oracle exists. It is that nothing
// held it and `MeshyySession` together, so 200 seeded scenarios proved the *design*
// was coherent and proved nothing about the code that ships. `ConformanceTests` is
// the pin.
//
// Divergences are recorded rather than asserted, because this target cannot import
// the testing library — and because a runner wants the seed and step index in the
// message, which only it knows.

import Foundation
import MeshyyCore

/// What a client must do with what the daemon sends back.
public struct ClientModel: Sendable {
    /// Everything handed to the renderer, in order.
    public private(set) var delivered: [UInt8] = []
    /// The offset confirmed as consumed (design doc §6.2 `Ack`). What a reconnect
    /// resumes from.
    public private(set) var ackedOffset: UInt64 = 0
    /// Points where the daemon said the stream had a hole.
    public private(set) var reportedHoles: [(at: UInt64, skipped: UInt64)] = []
    /// Problems the runner should surface, with enough context to act on.
    public private(set) var complaints: [String] = []

    public init() {}

    /// Applies a resume decision the way a client must.
    public mutating func apply(_ decision: ResumeDecision) {
        switch decision {
        case .fresh(let from, let bytes):
            delivered += bytes
            ackedOffset = from + UInt64(bytes.count)

        case .replay(let from, let bytes):
            // The client asked from `ackedOffset`; the daemon must honour exactly
            // that, or the two have drifted.
            if from != ackedOffset {
                complaints.append("daemon replayed from \(from), client asked \(ackedOffset)")
            }
            delivered += bytes
            ackedOffset += UInt64(bytes.count)

        case .replayFromAnchor(let anchor, let bytes, let skipped):
            reportedHoles.append((at: ackedOffset, skipped: skipped))
            delivered += bytes
            ackedOffset = anchor + UInt64(bytes.count)

        case .mustRedraw(let earliest, let bytes, let skipped):
            reportedHoles.append((at: ackedOffset, skipped: skipped))
            // The hole is announced, and then the surviving window is delivered —
            // exactly what a fresh attach gets on the same buffer. Delivering
            // NOTHING here (which this modelled, and the daemon did) left a client
            // that had fallen out of the ring blank forever, and its offset a full
            // ring capacity stale so the next resume was too old again.
            delivered += bytes
            ackedOffset = earliest + UInt64(bytes.count)

        case .impossible:
            complaints.append("daemon reported an impossible offset — client bug")
        }
    }

    /// Live output arriving while attached.
    public mutating func receiveLive(_ bytes: [UInt8]) {
        delivered += bytes
        ackedOffset += UInt64(bytes.count)
    }
}
