// meshyy — pin the reference client to the shipping one (hardening 1b-bis).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// The 1a audit's sharpest finding: the §6.4 property test asserts against
// `ClientModel`, a reference implementation written before `MeshyySession` existed,
// with nothing holding the two together. 200 seeded scenarios proved the *design*
// was coherent and proved nothing about the code that ships — demonstrated in
// `docs/qa/mutation-log.md`, where a byte-losing off-by-one in `MeshyySession`
// merged green.
//
// This is the pin. Every scenario in the shared corpus is replayed against BOTH
// implementations and their delivered byte streams are compared **after every
// step**, not only at the end. That converts the existing corpus from a liability
// into transitive coverage of the shipping path.
//
// The shipping client is driven with the exact frames `SessionAttachment` would
// send, derived from `SessionBuffer` — the same source of truth the daemon uses — so
// the harness cannot drift into testing a fiction of the protocol.

import Foundation
import MeshyyCore
import MeshyyTestSupport
import Testing
@testable import MeshyyKit

/// Replays one scenario against both implementations, comparing at every step.
private struct ConformanceRun {
    let scenario: ResumeScenario

    /// Where the two disagreed, if they did.
    struct Divergence: CustomStringConvertible {
        let seed: UInt64
        let stepIndex: Int
        let step: ResumeStep
        let reference: [UInt8]
        let shipping: [UInt8]

        var description: String {
            let firstDifference = zip(reference, shipping).enumerated()
                .first { $0.element.0 != $0.element.1 }?.offset
                ?? min(reference.count, shipping.count)
            return """
                seed \(seed), step \(stepIndex) (\(label)):
                  reference delivered \(reference.count) bytes
                  shipping  delivered \(shipping.count) bytes
                  first difference at byte \(firstDifference)
                  reference[\(firstDifference)...] = \(Self.window(reference, from: firstDifference))
                  shipping [\(firstDifference)...] = \(Self.window(shipping, from: firstDifference))
                """
        }

        private var label: String {
            switch step {
            case .output(let bytes): "output(\(bytes.count)B)"
            case .clearScreen: "clearScreen"
            case .disconnect: "disconnect"
            case .reconnect: "reconnect"
            }
        }

        /// A short window around the divergence — the whole stream can be kilobytes,
        /// and a wall of numbers is not a diagnosis.
        private static func window(_ bytes: [UInt8], from index: Int) -> String {
            let slice = bytes.dropFirst(index).prefix(16)
            return "\(Array(slice))\(bytes.count > index + 16 ? "…" : "")"
        }
    }

    /// Runs both implementations in lockstep. Returns the first divergence, or nil.
    func run() async -> Divergence? {
        var daemon = SessionBuffer(capacity: scenario.bufferCapacity)
        var reference = ClientModel()

        let shipping = MeshyySession()
        var shippingDelivered: [UInt8] = []
        var connected = true

        // A fresh session starts attached, which on the wire means the daemon has
        // already stated a replay base. Mirror that.
        await shipping.resetForAttach(resumeFrom: nil)
        _ = await shipping.handle(.control(.replayBase(ptyID: 0, offset: 0)))

        for (index, step) in scenario.steps.enumerated() {
            switch step {
            case .output(let bytes):
                daemon.write(bytes)
                if connected {
                    reference.receiveLive(bytes)
                    shippingDelivered += await shipping.handle(.pty(0, bytes))
                }

            case .clearScreen:
                let bytes = ResumeScenario.clearScreenBytes
                daemon.write(bytes)
                if connected {
                    reference.receiveLive(bytes)
                    shippingDelivered += await shipping.handle(.pty(0, bytes))
                }

            case .disconnect:
                connected = false

            case .reconnect:
                // Both resume from their OWN recorded offset. That is the whole point:
                // if the shipping client's arithmetic drifts, it asks for a different
                // offset than the reference does and the streams part company.
                let decision = daemon.resume(from: reference.ackedOffset)
                reference.apply(decision)

                let shippingOffset = await shipping.consumedOffset
                let shippingDecision = daemon.resume(from: shippingOffset)
                await shipping.resetForAttach(resumeFrom: nil)
                // Exactly what SessionAttachment sends, in order: the base, then the
                // replayed bytes.
                _ = await shipping.handle(
                    .control(.replayBase(ptyID: 0, offset: shippingDecision.replayBase))
                )
                shippingDelivered += await shipping.handle(.pty(0, shippingDecision.bytes))
                connected = true
            }

            if reference.delivered != shippingDelivered {
                return Divergence(
                    seed: scenario.seed,
                    stepIndex: index,
                    step: step,
                    reference: reference.delivered,
                    shipping: shippingDelivered
                )
            }
        }
        return nil
    }
}

extension MeshyyKitSuite {
    @Suite("Client conformance (reference vs shipping)")
    struct ConformanceTests {

        /// The pin. 200 seeded scenarios, both implementations, compared at every step.
        ///
        /// A failure names the seed and the step index, so it is replayable rather
        /// than merely alarming.
        @Test(
            "The shipping client delivers exactly what the reference client does",
            arguments: 1...200
        )
        func shippingMatchesReference(seed: UInt64) async {
            let divergence = await ConformanceRun(scenario: ResumeScenario(seed: seed)).run()
            #expect(divergence == nil, "\(divergence?.description ?? "")")
        }

        /// The corpus must actually exercise resume, or the pin above is vacuous — 200
        /// scenarios of pure output would pass whatever the offset arithmetic did.
        @Test("The corpus contains disconnects and reconnects to pin against")
        func corpusIsNotVacuous() {
            let scenarios = ResumeScenario.corpus()
            let reconnects = scenarios.reduce(0) { total, scenario in
                total + scenario.steps.filter { $0 == .reconnect }.count
            }
            let clears = scenarios.reduce(0) { total, scenario in
                total + scenario.steps.filter { $0 == .clearScreen }.count
            }
            #expect(scenarios.count == 200)
            #expect(reconnects > 200, "only \(reconnects) reconnects across 200 scenarios")
            #expect(clears > 100, "only \(clears) clear-screens, so the anchor path is thin")
        }

        /// A scenario is identical on every run and every machine, or a reported seed
        /// is not a reproduction.
        @Test("Scenarios are deterministic for a given seed")
        func scenariosAreDeterministic() {
            for seed in [1, 7, 42, 199] as [UInt64] {
                #expect(ResumeScenario(seed: seed).steps == ResumeScenario(seed: seed).steps,
                        "seed \(seed) is not reproducible")
            }
            #expect(ResumeScenario(seed: 1).steps != ResumeScenario(seed: 2).steps,
                    "different seeds must produce different scenarios")
        }
    }
}
