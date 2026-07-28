// meshyy — the shared resume scenario corpus (hardening 1b-bis, 1c-bis).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// One corpus, executed at more than one level. The §6.4 property test runs it
// against `SessionBuffer` and the reference `ClientModel`; the conformance harness
// runs the same scenarios against the shipping `MeshyySession`.
//
// It lives in its own target rather than in a test file because two test targets
// need it, and because duplicating it would recreate the exact defect the 1a audit
// found: two implementations of the same idea with nothing holding them together.
//
// Not a package product. Nothing ships it.

import Foundation

/// Deterministic PRNG so a failing scenario can be replayed from its seed.
/// SplitMix64 — four lines, published constants.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// One thing that happens to a session.
public enum ResumeStep: Sendable, Equatable {
    /// The PTY produced these bytes.
    case output([UInt8])
    /// The PTY produced a full-screen clear, so the §6.3 anchor path is exercised
    /// rather than only the `mustRedraw` fallback.
    case clearScreen
    /// iOS suspended the app: the connection dies with no warning.
    case disconnect
    /// The app returned and asked to resume from whatever it last consumed.
    case reconnect
}

/// A seeded scenario: a fixed list of steps, identical for a given seed on any
/// machine and at any level it is executed.
public struct ResumeScenario: Sendable {
    public let seed: UInt64
    public let steps: [ResumeStep]
    /// Small on purpose: a 4 MB buffer would never overrun in a unit test and the
    /// interesting branches would go unexercised.
    public let bufferCapacity: Int

    public static let defaultStepCount = 60
    public static let defaultCapacity = 1024

    /// Byte range used for generated output.
    ///
    /// Printable ASCII, not 0…255. The model layer would not care, but the same
    /// corpus is replayed through a real PTY, and a PTY is not transparent to
    /// arbitrary bytes even in raw mode — flow-control and signal characters are
    /// eaten by the line discipline. Keeping the corpus PTY-safe is what lets one
    /// corpus serve both levels.
    static let byteRange: ClosedRange<UInt8> = 32...126

    public init(
        seed: UInt64,
        stepCount: Int = ResumeScenario.defaultStepCount,
        bufferCapacity: Int = ResumeScenario.defaultCapacity
    ) {
        self.seed = seed
        self.bufferCapacity = bufferCapacity

        var random = SplitMix64(seed: seed)
        var steps: [ResumeStep] = []
        var connected = true

        for _ in 0..<stepCount {
            switch Int.random(in: 0..<10, using: &random) {
            case 0...5:
                // Sometimes a burst big enough to force an overrun while away.
                let length = Bool.random(using: &random)
                    ? Int.random(in: 1...64, using: &random)
                    : Int.random(in: 1...1500, using: &random)
                steps.append(.output(
                    (0..<length).map { _ in UInt8.random(in: Self.byteRange, using: &random) }
                ))
            case 6:
                steps.append(.clearScreen)
            case 7:
                if connected { steps.append(.disconnect); connected = false }
            case 8, 9:
                if !connected { steps.append(.reconnect); connected = true }
            default:
                break
            }
        }
        // Always end attached, so a runner can make a closing assertion about the
        // whole stream rather than about a suspended one.
        if !connected { steps.append(.reconnect) }

        self.steps = steps
    }

    public static let clearScreenBytes = Array("\u{1B}[2J".utf8)

    /// The full corpus the property test and the conformance harness both use.
    public static func corpus(_ seeds: ClosedRange<UInt64> = 1...200) -> [ResumeScenario] {
        seeds.map { ResumeScenario(seed: $0) }
    }
}
