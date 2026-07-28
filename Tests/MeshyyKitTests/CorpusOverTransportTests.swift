// meshyy — the shared scenario corpus, executed through a real transport (1c-bis).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// 1c-bis: "Add a second execution mode for the same scenario corpus that runs through
// real framing and a real transport, so the corpus is written once and executed at two
// levels."
//
// The corpus now runs three ways, each cheaper and blinder than the last:
//
//   1. `ConformanceTests`     model level. Both client implementations in lockstep,
//                             200 scenarios, compared after every step. Fast, and
//                             blind to everything below `MeshyySession`.
//   2. `AbruptLossTests`      framing level. Real `FrameEnvelope` encoding and a real
//                             `FrameDecoder`, fed byte at a time so a frame can be cut
//                             in half. Blind to the transport.
//   3. **this file**          transport level. A real daemon, a real PTY, a real QUIC
//                             connection, and disconnects that actually tear a
//                             connection down.
//
// WHY A SUBSET, AND WHY THAT IS HONEST. Each scenario here stands up a daemon, a
// keychain identity, a QUIC listener and a shell, and every `disconnect` closes a live
// connection and dials a new one. At 200 scenarios that is minutes of wall clock on
// every CI run for coverage that is *already* asserted twice above — the transport
// level's job is to catch what the other two structurally cannot see, not to re-derive
// the same arithmetic 200 more times. A fixed, seeded subset does that. The count is
// stated here and in docs/qa/test-inventory.md rather than left for a reader to infer
// from an `arguments:` range, because a silently truncated sweep reads as full
// coverage.

import Foundation
import MeshyyCore
import MeshyyTestSupport
import Testing
@testable import MeshyyKit

extension MeshyyKitSuite {
    @Suite("The corpus, over a real transport (1c-bis)")
    struct CorpusOverTransportTests {

        /// Seeds drawn from the same 200-scenario corpus the other two modes use.
        ///
        /// Fixed rather than random: a subset that changes per run turns a failure
        /// into an anecdote, which is the same argument the chaos relay's seed is
        /// built on.
        static let seeds: [UInt64] = [1, 7, 13, 42, 99, 137, 176, 200]

        /// Collects delivered PTY bytes across however many connections a scenario uses.
        private final class Sink: @unchecked Sendable {
            private let lock = NSLock()
            private var bytes: [UInt8] = []
            private var welcomes = 0

            var delivered: [UInt8] {
                lock.lock()
                defer { lock.unlock() }
                return bytes
            }

            var welcomeCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return welcomes
            }

            func append(_ frame: FrameEnvelope) {
                lock.lock()
                defer { lock.unlock() }
                if frame.kind == .pty {
                    bytes += frame.payload
                } else if frame.kind == .control,
                          let control = try? ControlFrame.decode(frame.payload),
                          case .welcome = control {
                    welcomes += 1
                }
            }

            func wait(
                timeout: TimeInterval = 25,
                until predicate: @Sendable @escaping () -> Bool
            ) async -> Bool {
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    if predicate() { return true }
                    try? await Task.sleep(for: .milliseconds(25))
                }
                return predicate()
            }
        }

        /// Runs one scenario end to end against a real daemon.
        ///
        /// The daemon's child is the byte pipe, so what comes back is exactly what was
        /// sent — the subject here is the transport, not a shell. Scenario `output`
        /// steps become bytes typed at the PTY; `disconnect` closes the QUIC connection
        /// for real; `reconnect` bootstraps a fresh token and dials again, resuming
        /// from what this client has actually received.
        @Test("A corpus scenario survives real disconnects with the stream intact",
              arguments: seeds)
        func scenarioSurvivesRealTransport(seed: UInt64) async throws {
            let scenario = ResumeScenario(seed: seed)
            try await withHarness(bufferCapacity: scenario.bufferCapacity) { daemon in
                let sink = Sink()
                var connection: MeshyyConnection?
                var expected: [UInt8] = []
                var connected = false

                /// Dials, resuming from what has genuinely been received so far.
                func attach() async throws {
                    let bootstrap = try daemon.bootstrap(session: "corpus-\(seed)")
                    let fresh = MeshyyConnection(bootstrap: bootstrap, sshHost: "127.0.0.1")
                    fresh.onFrame = { sink.append($0) }
                    try await fresh.connect()
                    let consumed = UInt64(sink.delivered.count)
                    try fresh.send(.hello(.init(
                        token: bootstrap.token,
                        cols: 80,
                        rows: 24,
                        // The client's own count is the resume point — the same rule the
                        // shipping client follows, and the one 1g pinned.
                        resumeFrom: consumed > 0 ? consumed : nil,
                        session: nil
                    )))
                    connection = fresh
                    connected = true
                }

                try await attach()
                #expect(await sink.wait { sink.welcomeCount >= 1 }, "seed \(seed): no Welcome")

                for step in scenario.steps {
                    switch step {
                    case .output(let bytes):
                        // A PTY is not transparent to arbitrary bytes even in raw mode
                        // — established the hard way in 1f, where 312 of 700 bytes came
                        // back mangled. Printable ASCII only, so a failure here means
                        // the transport lost something rather than the terminal
                        // transforming it.
                        let payload = bytes.map { 0x20 + ($0 % 0x5F) }
                        guard connected, let live = connection else { continue }
                        expected += payload
                        try live.sendKeystrokes(payload)
                        let target = expected.count
                        #expect(await sink.wait { sink.delivered.count >= target },
                                "seed \(seed): only \(sink.delivered.count) of \(target) bytes arrived")

                    case .clearScreen:
                        guard connected, let live = connection else { continue }
                        let payload = ResumeScenario.clearScreenBytes
                        expected += payload
                        try live.sendKeystrokes(payload)
                        let target = expected.count
                        #expect(await sink.wait { sink.delivered.count >= target },
                                "seed \(seed): clear-screen bytes never arrived")

                    case .disconnect:
                        // A real teardown, not a bool.
                        connection?.close()
                        connection = nil
                        connected = false

                    case .reconnect:
                        guard !connected else { continue }
                        let before = sink.welcomeCount
                        try await attach()
                        #expect(await sink.wait { sink.welcomeCount > before },
                                "seed \(seed): the reconnect never attached")
                    }
                }

                // §6.4, at the transport level: what the client received is exactly what
                // was sent, with no gap at any seam and no byte delivered twice.
                let delivered = sink.delivered
                #expect(delivered == expected, """
                    seed \(seed): the stream is not exact across \(sink.welcomeCount) attaches — \
                    delivered \(delivered.count) bytes, expected \(expected.count)
                    """)
                connection?.close()
            }
        }

        /// The subset must actually exercise the thing it exists for, or it is eight
        /// slow copies of the happy path.
        @Test("The chosen seeds really do disconnect and reconnect")
        func chosenSeedsAreNotVacuous() {
            var reconnects = 0
            var clears = 0
            for seed in Self.seeds {
                let steps = ResumeScenario(seed: seed).steps
                reconnects += steps.filter { $0 == .reconnect }.count
                clears += steps.filter { $0 == .clearScreen }.count
            }
            #expect(reconnects >= Self.seeds.count,
                    "only \(reconnects) reconnects across \(Self.seeds.count) seeds — this mode would be testing a single connection")
            #expect(clears > 0, "no clear-screen in the subset, so the anchor path is untouched")
        }
    }
}
