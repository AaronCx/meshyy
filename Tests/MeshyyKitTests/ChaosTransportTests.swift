// meshyy — a real QUIC session driven through an impaired network (hardening 1d-bis).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Everything else in this suite runs over loopback, which is a network that never
// loses, never reorders, and never goes quiet. `ChaosUDPProxy` puts a relay in the
// path so the QUIC connection is real and the network under it is not.
//
// The acceptance criterion for this PR is a test that fails without the relay and
// passes with it. `theRelayIsActuallyInThePath` is that test, and it is first on
// purpose: every assertion below it is meaningless if the traffic is quietly going
// direct, which is the failure mode a chaos harness is most likely to have and least
// likely to notice.
//
// WHAT IS MEASURED RATHER THAN ASSUMED. Two behaviours here are findings, not
// requirements — the milestone amendment needs to know what the transport does before
// M4 can be specified against it:
//
//   - a NAT rebind (the relay changing its own source port mid-session)
//   - a black-hole window long enough to trip the idle timeout
//
// M0 established that Network framework QUIC exposes no connection migration. What
// that means for a rebind is not something to guess at, so the test records it.

import Foundation
@testable import MeshyyChaos
import MeshyyCore
import Testing
@testable import MeshyyKit

/// Collects frames off a connection. Local to this file; `QUICTransportTests` has its
/// own, and sharing one would couple two suites that fail for different reasons.
private final class ChaosSink: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [FrameEnvelope] = []

    var all: [FrameEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    var ptyBytes: [UInt8] { all.filter { $0.kind == .pty }.flatMap(\.payload) }

    var controlFrames: [ControlFrame] {
        all.filter { $0.kind == .control }.compactMap { try? ControlFrame.decode($0.payload) }
    }

    var sawWelcome: Bool {
        controlFrames.contains { if case .welcome = $0 { return true } else { return false } }
    }

    func append(_ frame: FrameEnvelope) {
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }

    /// Polls until `predicate` holds or the deadline passes. Generous on purpose: the
    /// ceiling only changes how long a genuine failure takes to report, and every wait
    /// here is on a real QUIC connection over a deliberately degraded relay.
    func wait(
        timeout: TimeInterval = 30,
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

extension MeshyyKitSuite {
    @Suite("Chaos transport (1d-bis)")
    struct ChaosTransportTests {

        /// Stands up daemon + relay and hands back a bootstrap pointing at the relay.
        ///
        /// The rewrite of `port` is the whole trick: the daemon issues a bootstrap for
        /// its own QUIC listener, and the client is told to dial the relay instead.
        /// Nothing else about the handshake changes, including the certificate pin —
        /// the relay is not a man in the middle, it is a bad piece of wire.
        private static func withChaos<T>(
            profile: ChaosProfile,
            child: TestDaemonHarness.Child = .bytePipe,
            _ body: (TestDaemonHarness, ChaosUDPProxy, BootstrapResponse) async throws -> T
        ) async throws -> T {
            try await withHarness(child: child) { daemon in
                let relay = ChaosUDPProxy(
                    targetHost: "127.0.0.1",
                    targetPort: daemon.quicPort,
                    profile: profile
                )
                let relayPort = try relay.start()
                var bootstrap = try daemon.bootstrap(session: "chaos")
                bootstrap.port = relayPort
                do {
                    let result = try await body(daemon, relay, bootstrap)
                    relay.stop()
                    return result
                } catch {
                    relay.stop()
                    throw error
                }
            }
        }

        /// Opens a session through the relay and waits for Welcome.
        private static func connect(
            _ bootstrap: BootstrapResponse,
            sink: ChaosSink,
            cols: Int = 80,
            rows: Int = 24
        ) async throws -> MeshyyConnection {
            let connection = MeshyyConnection(bootstrap: bootstrap, sshHost: "127.0.0.1")
            connection.onFrame = { sink.append($0) }
            try await connection.connect()
            try connection.send(.hello(.init(
                token: bootstrap.token, cols: cols, rows: rows, session: nil
            )))
            return connection
        }

        // MARK: - The acceptance criterion

        /// THE TEST THAT FAILS WITHOUT THE RELAY. A pristine relay must be transparent
        /// — a session through it behaves exactly like a direct one — *and* the relay
        /// must be able to prove it carried the traffic.
        ///
        /// Both halves matter. Transparency alone would also be satisfied by a relay
        /// that was never in the path, which is precisely the bug that makes an entire
        /// chaos suite worthless while staying green. The datagram counts are the
        /// evidence, and they come from the relay's own books.
        @Test("A pristine relay carries a real QUIC session and is provably in the path")
        func theRelayIsActuallyInThePath() async throws {
            try await Self.withChaos(profile: ChaosProfile(seed: 1)) { _, relay, bootstrap in
                let sink = ChaosSink()
                let connection = try await Self.connect(bootstrap, sink: sink)
                defer { connection.close() }

                #expect(await sink.wait { sink.sawWelcome },
                        "no Welcome through a pristine relay — \(relay.snapshot().summary)")

                let payload = Array("through the relay\n".utf8)
                try connection.sendKeystrokes(payload)
                #expect(await sink.wait { sink.ptyBytes.contains(payload) },
                        "echo never came back — \(relay.snapshot().summary)")

                // The evidence. A direct connection would leave these at zero, which
                // is what makes this test fail without the relay in the path.
                let stats = relay.snapshot()
                #expect(stats.flows >= 1, "the relay accepted no flow: \(stats.summary)")
                #expect(stats.datagramsUp > 0 && stats.datagramsDown > 0,
                        "the relay carried nothing in one or both directions: \(stats.summary)")
                #expect(stats.bytesUp > 0 && stats.bytesDown > 0, "\(stats.summary)")

                // A relay that lies about delivering is worse than one that drops.
                #expect(stats.sendErrors == 0, "the relay lost datagrams it claimed to send")
                #expect(stats.droppedUp == 0 && stats.droppedDown == 0,
                        "a pristine profile must not drop anything: \(stats.summary)")
            }
        }

        // MARK: - Ordinary loss, and being honest about it

        /// QUIC retransmits through per-datagram loss, so a drop rate shows up as
        /// latency rather than as anything the application can see.
        ///
        /// That is the correct result and it is worth asserting, because the tempting
        /// conclusion from a green run is "loss is handled" when what was really shown
        /// is "loss was invisible." The assertion is therefore about *bytes arriving
        /// intact*, plus a check that the relay genuinely dropped some — otherwise the
        /// test proves only that nothing happened.
        @Test("Datagram loss is retransmitted through, not surfaced to the application")
        func lossIsRetransmittedThrough() async throws {
            let profile = ChaosProfile(loss: 0.10, seed: 0xC0FFEE)
            try await Self.withChaos(profile: profile) { _, relay, bootstrap in
                let sink = ChaosSink()
                let connection = try await Self.connect(bootstrap, sink: sink)
                defer { connection.close() }

                #expect(await sink.wait { sink.sawWelcome },
                        "10% loss defeated the handshake — seed \(profile.seed), \(relay.snapshot().summary)")

                // Enough traffic that the loss is certain to have hit some of it.
                let expected: [UInt8] = (0..<20).flatMap { Array("lossy line \($0)\n".utf8) }
                for index in 0..<20 {
                    try connection.sendKeystrokes(Array("lossy line \(index)\n".utf8))
                }
                let wanted = expected.count
                #expect(await sink.wait { sink.ptyBytes.count >= wanted },
                        "bytes never arrived under 10% loss — seed \(profile.seed), \(relay.snapshot().summary)")
                #expect(sink.ptyBytes == expected,
                        "loss corrupted the stream rather than delaying it — seed \(profile.seed)")

                let stats = relay.snapshot()
                #expect(stats.droppedUp + stats.droppedDown > 0,
                        "no datagram was actually dropped, so this proved nothing: \(stats.summary)")
            }
        }

        /// Same seed, same decisions.
        ///
        /// This tests the relay's decision stream directly rather than by comparing two
        /// live sessions, and the reason is a limitation worth stating plainly: a live
        /// replay would also require the *traffic* to be identical, and it is not. QUIC
        /// chooses its own retransmission timing, so run two matches the seed but not
        /// the datagram sequence the seed is applied to. The first draft of this test
        /// compared two live runs and was flaky for exactly that reason.
        ///
        /// What the seed therefore guarantees is precise and worth knowing: given the
        /// same sequence of datagrams, the relay makes the same sequence of decisions.
        /// Reproducing a failing run means fixing the seed *and* replaying the traffic.
        @Test("The relay's impairment decisions are reproducible from the seed")
        func impairmentIsDeterministic() {
            func draws(seed: UInt64, count: Int = 64) -> [Double] {
                var random = ChaosRandom(seed: seed)
                return (0..<count).map { _ in random.next(in: 0..<1) }
            }

            #expect(draws(seed: 99) == draws(seed: 99),
                    "seed 99 produced two different streams, so no failure can be replayed")
            #expect(draws(seed: 99) != draws(seed: 100),
                    "different seeds produced identical streams, so the seed does nothing")

            // The decisions that follow, at the rate the loss tests use. Both outcomes
            // must appear, or a "deterministic" stream is just a constant.
            let decisions = draws(seed: 99).map { $0 < 0.30 }
            #expect(decisions.contains(true), "no datagram would ever be dropped at 30%")
            #expect(decisions.contains(false), "every datagram would be dropped at 30%")

            // In range, so a rate of 0 drops nothing and a rate of 1 drops everything
            // rather than being off by a boundary.
            #expect(draws(seed: 7).allSatisfy { $0 >= 0 && $0 < 1 },
                    "a draw fell outside [0,1), so loss rates do not mean what they say")
        }

        // MARK: - Episodic impairment: the cases M4 is defined against

        /// The deafness case. Packets leave, nothing comes back, and there is no error
        /// and no close — the connection is simply quiet.
        ///
        /// This is what M4's heartbeat exists to notice. The assertion is that the
        /// application sees NOTHING during the window: if bytes arrived anyway, the
        /// black hole is not black and every M4 timing measurement taken against it
        /// would be fiction.
        @Test("A black-hole window silences the connection, with no error and no close")
        func blackHoleIsSilent() async throws {
            try await Self.withChaos(profile: ChaosProfile(seed: 7)) { _, relay, bootstrap in
                let sink = ChaosSink()
                let connection = try await Self.connect(bootstrap, sink: sink)
                defer { connection.close() }
                #expect(await sink.wait { sink.sawWelcome })

                let before = Array("before the dark\n".utf8)
                try connection.sendKeystrokes(before)
                #expect(await sink.wait { sink.ptyBytes.contains(before) })

                relay.blackHole(.down, for: .milliseconds(1500))
                let atBlackout = sink.ptyBytes.count
                let swallowed = Array("into the dark\n".utf8)
                try connection.sendKeystrokes(swallowed)

                // Not a timing assertion: nothing may arrive at all while the window
                // is open, however fast the machine is.
                try await Task.sleep(for: .milliseconds(700))
                #expect(sink.ptyBytes.count == atBlackout,
                        "bytes arrived during a 100%-loss window — the relay's black hole leaks")

                // And the connection was never told anything was wrong. That is the
                // entire difficulty M4 has to solve.
                #expect(connection.currentState == .connected,
                        "the transport reported a failure it could not actually have detected")

                // It heals: the retransmit lands once the window closes.
                #expect(await sink.wait { sink.ptyBytes.contains(swallowed) },
                        "the connection did not recover after the black hole healed — \(relay.snapshot().summary)")
            }
        }

        /// One direction dies and the other keeps working. A peer that only watches
        /// whether its own sends succeed calls this healthy forever.
        @Test("A half-open path keeps accepting sends while delivering nothing back")
        func halfOpenLooksHealthyToTheSender() async throws {
            try await Self.withChaos(profile: ChaosProfile(seed: 11)) { _, relay, bootstrap in
                let sink = ChaosSink()
                let connection = try await Self.connect(bootstrap, sink: sink)
                defer { connection.close() }
                #expect(await sink.wait { sink.sawWelcome })

                relay.halfOpen(.down)
                let received = sink.ptyBytes.count
                try connection.sendKeystrokes(Array("shouting into a void\n".utf8))
                try await Task.sleep(for: .milliseconds(800))

                #expect(sink.ptyBytes.count == received, "the dead direction delivered bytes")
                // The sends themselves did not fail, which is the trap.
                #expect(connection.currentState == .connected,
                        "half-open was detected — worth knowing, and it would mean the transport has liveness detection M4 could lean on")

                let stats = relay.snapshot()
                #expect(stats.datagramsUp > 0, "the surviving direction stopped too: \(stats.summary)")
            }
        }

        /// A hard kill at a byte offset: the wire stops mid-datagram-stream, which is
        /// the transport-level version of what `AbruptLossTests` proves at the frame
        /// level. The session must still be resumable from the daemon afterwards.
        @Test("A hard kill mid-stream leaves the session resumable")
        func hardKillLeavesSessionResumable() async throws {
            try await Self.withChaos(profile: ChaosProfile(seed: 13)) { daemon, relay, bootstrap in
                let sink = ChaosSink()
                let connection = try await Self.connect(bootstrap, sink: sink)
                defer { connection.close() }
                #expect(await sink.wait { sink.sawWelcome })

                let early = Array("before the kill\n".utf8)
                try connection.sendKeystrokes(early)
                #expect(await sink.wait { sink.ptyBytes.contains(early) })

                // Die after a few hundred more bytes, wherever that lands.
                relay.kill(after: 300)
                for index in 0..<40 {
                    try? connection.sendKeystrokes(Array("dying \(index)\n".utf8))
                }
                try await Task.sleep(for: .milliseconds(500))
                connection.close()

                // The daemon side is untouched by the client's misfortune: a second
                // bootstrap against the same session still works, through a NEW relay
                // with a clean path.
                let survivor = ChaosUDPProxy(
                    targetHost: "127.0.0.1", targetPort: daemon.quicPort, profile: ChaosProfile()
                )
                let survivorPort = try survivor.start()
                defer { survivor.stop() }
                var second = try daemon.bootstrap(session: "chaos")
                second.port = survivorPort

                let resumed = ChaosSink()
                let reconnection = try await Self.connect(second, sink: resumed)
                defer { reconnection.close() }
                #expect(await resumed.wait { resumed.sawWelcome },
                        "the session did not survive a hard kill of one client's wire — \(survivor.snapshot().summary)")
            }
        }

        // MARK: - NAT rebind: a measurement, not a requirement

        /// The relay changes its own source port mid-session, which is exactly what a
        /// NAT rebind looks like to the daemon: the same QUIC connection arriving from
        /// a new address.
        ///
        /// M0 established that Network framework QUIC exposes no connection migration
        /// API. Whether the *implementation* tolerates a peer address change anyway is
        /// a different question, and it decides how M4 must be built:
        ///
        ///   - if it survives, a rebind is invisible and 4b only needs to catch total
        ///     deafness;
        ///   - if it does not, a rebind is indistinguishable from a dead network at the
        ///     client, and the only recovery is redial — which is exactly the premise
        ///     the rewritten M4 is built on.
        ///
        /// This test asserts the setup happened and RECORDS the outcome rather than
        /// demanding one, because either answer is a fact about the platform and not a
        /// defect in meshyy. The finding is written up in docs/provenance.md.
        @Test("A NAT rebind mid-session: what the transport actually does")
        func natRebindOutcome() async throws {
            try await Self.withChaos(profile: ChaosProfile(seed: 17)) { _, relay, bootstrap in
                let sink = ChaosSink()
                let connection = try await Self.connect(bootstrap, sink: sink)
                defer { connection.close() }
                #expect(await sink.wait { sink.sawWelcome })

                let before = Array("before the rebind\n".utf8)
                try connection.sendKeystrokes(before)
                #expect(await sink.wait { sink.ptyBytes.contains(before) })

                let portsBefore = relay.sourcePorts()
                #expect(!portsBefore.isEmpty, "no back socket to rebind")

                relay.rebind()
                try await Task.sleep(for: .milliseconds(400))

                let portsAfter = relay.sourcePorts()
                // The precondition: the daemon really is seeing a new source address.
                // Without this the test would report "survived a rebind" having never
                // performed one.
                #expect(!portsAfter.isEmpty && portsAfter != portsBefore,
                        "the relay did not actually change source port: \(portsBefore) -> \(portsAfter)")

                let baseline = sink.ptyBytes.count
                try? connection.sendKeystrokes(Array("after the rebind\n".utf8))

                // Polled inline rather than through `sink.wait`: this one has a short
                // ceiling because a rebind that works is instant, and a rebind that
                // does not will never produce a byte however long the wait.
                var survived = false
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline, !survived {
                    survived = sink.ptyBytes.count > baseline
                    try? await Task.sleep(for: .milliseconds(50))
                }

                // MEASURED 2026-07-28, macOS 26.4.1: the rebind BREAKS the connection,
                // and the client is not told. Both halves are asserted so that a future
                // OS changing either one turns this red — which would be a finding that
                // changes M4's design, not a test to relax.
                // MEASURED 2026-07-28, macOS 26.4.1, over 4 runs.
                //
                // The byte flow ALWAYS stops: Network framework QUIC does not follow a
                // peer to a new address, which confirms M0's finding at the level that
                // matters and settles the M4 question. A rebind requires a redial.
                #expect(!survived, """
                    FINDING CHANGED: a NAT rebind now SURVIVES. Network framework QUIC \
                    has gained peer-address migration since this was measured, so M4 no \
                    longer has to treat a rebind as a dead network. Re-open the M4 design. \
                    ports \(portsBefore) -> \(portsAfter), \(relay.snapshot().summary)
                    """)

                // What the CLIENT knows about it is the part M4 has to live with, and it
                // is worse than a clean failure. Across runs the state was sometimes
                // `.connected` and sometimes `.closed("the daemon closed the control
                // stream")` — the difference being whether the daemon happened to give
                // up within the window. Either way the client's own transport never
                // reported a network problem: it either believes it is fine, or it is
                // told second-hand by a peer it can no longer reach.
                //
                // So the assertion is the invariant behind both: the client never
                // detects this itself. A `.failed` state here would mean the transport
                // has liveness detection, and 4b could lean on it instead of a heartbeat.
                if case .failed(let reason) = connection.currentState {
                    Issue.record("""
                        FINDING CHANGED: the transport now detects a rebind on its own \
                        (failed: \(reason)). 4b could use that instead of a heartbeat. \
                        Re-open the M4 design.
                        """)
                }
            }
        }
    }
}
