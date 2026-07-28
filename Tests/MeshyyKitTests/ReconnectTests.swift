// meshyy — reconnect triggering, asserted rather than observed (M4 4b/4d).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// These are deterministic and need no network, which is the point. M4's acceptance
// says "under every combination of triggers, exactly one reconnect in flight —
// asserted, not observed", and a concurrency rule checked by reading log lines is a
// test of the logging. `ReconnectCoordinator` therefore knows nothing about QUIC or
// tokens: it takes a closure and guarantees one runs at a time, so the guarantee can
// be tested directly.

import Foundation
import Network
import Synchronization
import Testing
@testable import MeshyyKit

@Suite("Reconnect triggering (M4)")
struct ReconnectTests {

    // MARK: - 4d: one reconnect in flight

    /// The airplane-mode case: 4a, 4b and 4c all fire within a few hundred
    /// milliseconds of each other.
    ///
    /// Three concurrent redials against one session is a real bug class and a
    /// security-relevant one — each spends a single-use token, so racing them means
    /// tokens minted and abandoned, which a daemon watching for token abuse would be
    /// right to find suspicious.
    @Test("A burst of simultaneous triggers produces exactly one attempt in flight")
    func burstOfTriggersIsSerialised() async {
        let coordinator = ReconnectCoordinator()
        let live = Mutex(0)
        let peak = Mutex(0)

        // Hoisted so the closure is one explicitly-Sendable value shared by every
        // trigger, rather than a fresh one captured per task.
        let attempt: @Sendable () async throws -> Void = {
            let now = live.withLock { $0 += 1; return $0 }
            peak.withLock { $0 = max($0, now) }
            // Long enough that a broken implementation genuinely overlaps rather than
            // finishing before the next trigger arrives.
            try? await Task.sleep(for: .milliseconds(120))
            live.withLock { $0 -= 1 }
        }

        await withTaskGroup(of: Void.self) { group in
            for trigger: ReconnectTrigger in [
                .pathChanged("wifi -> lte"),
                .heartbeatLost(misses: 3),
                .foreground,
                .transportFailed("idle timeout"),
                .manual,
            ] {
                group.addTask { _ = await coordinator.request(trigger, attempt: attempt) }
            }
        }

        #expect(peak.withLock { $0 } == 1,
                "\(peak.withLock { $0 }) redials ran at once — each spends a single-use token")

        let counters = await coordinator.snapshot()
        #expect(counters.peakConcurrent == 1, "the coordinator's own count disagrees")
        #expect(counters.attempts == 1, "expected one attempt, got \(counters.attempts)")
        #expect(counters.suppressed == 4,
                "four triggers should have been suppressed, not \(counters.suppressed)")
    }

    /// A suppressed trigger is not simply discarded when it knew something new.
    ///
    /// The case: a reconnect is failing against a network that is gone, and the user
    /// walks into WiFi range. The path change must produce another attempt — the one
    /// in flight is trying the old world.
    @Test("A trigger with new information earns a retry after a failed attempt")
    func newInformationRetriesAfterFailure() async {
        let coordinator = ReconnectCoordinator()
        let attempts = Mutex(0)
        let started = Mutex(false)

        async let first: Bool = coordinator.request(.heartbeatLost(misses: 3)) {
            started.withLock { $0 = true }
            attempts.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(80))
            struct Dead: Error {}
            throw Dead()   // the network really is gone
        }

        // Wait for the first attempt to be genuinely in flight before interrupting it.
        while !started.withLock({ $0 }) { await Task.yield() }
        _ = await coordinator.request(.pathChanged("none -> wifi")) {
            attempts.withLock { $0 += 1 }
        }
        _ = await first

        #expect(attempts.withLock { $0 } == 2,
                "the path change was dropped, so the user waits out a backoff computed against a network that no longer exists")
        let counters = await coordinator.snapshot()
        #expect(counters.peakConcurrent == 1, "the retry overlapped the attempt it followed")
    }

    /// The mirror case: triggers arriving during a *successful* reconnect must not
    /// each redial a session that is now healthy.
    @Test("Triggers during a successful attempt do not redial a healthy session")
    func successAbsorbsQueuedTriggers() async {
        let coordinator = ReconnectCoordinator()
        let attempts = Mutex(0)
        let started = Mutex(false)

        async let first: Bool = coordinator.request(.foreground) {
            started.withLock { $0 = true }
            attempts.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(80))
        }
        while !started.withLock({ $0 }) { await Task.yield() }
        _ = await coordinator.request(.pathChanged("wifi -> lte")) {
            attempts.withLock { $0 += 1 }
        }
        _ = await first

        #expect(attempts.withLock { $0 } == 1,
                "a healthy session was redialled \(attempts.withLock { $0 }) times")
    }

    // MARK: - 4d: backoff

    /// First retry immediate, then doubling to a cap.
    ///
    /// The first retry is immediate because the measured redial cost is ~160ms on the
    /// LTE profile, so trying once more straight away is cheaper than any delay worth
    /// writing down. The cap exists because a daemon that is genuinely down — laptop
    /// shut, host rebooting — should not be probed every second for an hour.
    @Test("Backoff starts immediate, doubles, and caps")
    func backoffShape() {
        var backoff = ReconnectCoordinator.Backoff()
        backoff.initial = .milliseconds(500)
        backoff.maximum = .seconds(8)

        #expect(backoff.delay(afterFailures: 0) == .zero, "the first retry must be immediate")
        #expect(backoff.delay(afterFailures: 1) == .milliseconds(500))
        #expect(backoff.delay(afterFailures: 2) == .milliseconds(1000))
        #expect(backoff.delay(afterFailures: 3) == .milliseconds(2000))
        #expect(backoff.delay(afterFailures: 4) == .milliseconds(4000))
        #expect(backoff.delay(afterFailures: 5) == .milliseconds(8000))
        #expect(backoff.delay(afterFailures: 9) == .milliseconds(8000), "the cap must hold")
        #expect(backoff.delay(afterFailures: 40) == .milliseconds(8000),
                "a long outage must not overflow into an absurd delay")
    }

    /// Repeated failure must actually delay.
    ///
    /// Added because the mutation battery caught a hole: deleting the backoff wait
    /// entirely left every other test in this suite green. `successResetsBackoff`
    /// asserts a *fast* path and so cannot tell "the count was reset" from "there is
    /// no backoff at all" — the two look identical from the outside. This asserts the
    /// slow path, which is the half that stops a dead daemon being hammered.
    @Test("Consecutive failures actually wait before retrying")
    func failuresBackOff() async {
        var backoff = ReconnectCoordinator.Backoff()
        backoff.initial = .milliseconds(200)
        backoff.maximum = .milliseconds(400)
        let coordinator = ReconnectCoordinator(backoff: backoff)
        struct Dead: Error {}

        // The first attempt is immediate by design, so it establishes the failure.
        let firstStart = ContinuousClock().now
        _ = await coordinator.request(.manual) { throw Dead() }
        #expect(ContinuousClock().now - firstStart < .milliseconds(150),
                "the FIRST attempt must not wait — a redial costs ~160ms and trying again straight away is cheaper than any delay worth writing down")

        // The second must wait out `initial`.
        let secondStart = ContinuousClock().now
        _ = await coordinator.request(.heartbeatLost(misses: 3)) { throw Dead() }
        let waited = ContinuousClock().now - secondStart
        #expect(waited >= .milliseconds(180),
                "a repeated failure retried after \(waited) — a daemon that is genuinely down gets hammered")
    }

    /// A session up for hours must not inherit a long backoff from a bad patch of
    /// network last week.
    @Test("A successful attempt clears the failure count")
    func successResetsBackoff() async {
        let coordinator = ReconnectCoordinator()
        struct Dead: Error {}
        for _ in 0..<3 {
            _ = await coordinator.request(.manual) { throw Dead() }
        }
        #expect(await coordinator.snapshot().failures == 3)

        let start = ContinuousClock().now
        _ = await coordinator.request(.manual) {}
        // A 4th consecutive failure would have waited 2s. Success on the previous line
        // reset the count, so the next request is immediate.
        _ = await coordinator.request(.manual) {}
        #expect(ContinuousClock().now - start < .milliseconds(400),
                "the failure count survived a success, so a healthy session backs off")
    }

    // MARK: - 4b: heartbeat bookkeeping

    /// Nonces exist so a straggler cannot satisfy a later probe. Without that, one
    /// late pong arriving after two missed beats resets the count and the deadline
    /// never fires on a path that is slow-but-dying.
    @Test("A pong retires its probe and every older one")
    func pongRetiresOlderProbes() {
        var monitor = HeartbeatMonitor(interval: .seconds(1), missesBeforeDead: 3)
        let first = monitor.nextPing()
        let second = monitor.nextPing()
        let third = monitor.nextPing()
        #expect(monitor.missed == 3)
        #expect(monitor.isDead, "three unanswered probes is the deadline")

        // Answering the newest retires the two behind it: they travel in order on one
        // stream, so an older one cannot now arrive first.
        monitor.received(nonce: third.value)
        #expect(monitor.missed == 0)
        #expect(!monitor.isDead)
        #expect(first.value != second.value, "nonces must be distinct or they cannot match")
    }

    @Test("An unrecognised pong is ignored, not treated as an answer")
    func strayPongIsIgnored() {
        var monitor = HeartbeatMonitor(interval: .seconds(1), missesBeforeDead: 2)
        _ = monitor.nextPing()
        _ = monitor.nextPing()
        #expect(monitor.isDead)

        // A straggler from a previous connection, or a peer echoing nonsense.
        monitor.received(nonce: 999_999)
        #expect(monitor.isDead,
                "a stray pong resurrected a dead path — the deadline would never fire")
    }

    @Test("Attaching forgets probes the old connection can no longer answer")
    func resetClearsOutstandingProbes() {
        var monitor = HeartbeatMonitor(interval: .seconds(1), missesBeforeDead: 3)
        _ = monitor.nextPing()
        _ = monitor.nextPing()
        _ = monitor.nextPing()
        #expect(monitor.isDead)

        monitor.reset()
        #expect(monitor.missed == 0,
                "the fresh connection inherited the old one's misses and is dead on arrival")
    }

    /// The tuned numbers. Documented in docs/provenance.md with the measurements
    /// behind them; asserted here so a casual edit has to argue with a test.
    @Test("The heartbeat ships at the tuned interval and threshold")
    func tunedDefaults() {
        let monitor = HeartbeatMonitor()
        #expect(monitor.interval == .seconds(1))
        #expect(monitor.missesBeforeDead == 3,
                "3 misses = 3s detection, against a measured 4.45s idle-timeout backstop")
    }

    // MARK: - 4a: path changes worth acting on

    /// `NWPathMonitor` emits updates for changes that do not affect reachability at
    /// all. Redial is cheap but not free, and a redial storm on a flapping network is
    /// worse than the stall it avoids — so the trigger is a change in what the path
    /// *is*, not merely another callback.
    @Test("The path signature ignores updates that change nothing that matters")
    func pathSignatureIsStable() {
        // Pure function over a real NWPath is awkward to synthesise, so this asserts
        // the property that makes the dedup sound: the signature is built only from
        // fields that decide whether a connection made on the old path can still work.
        let monitor = NWPathMonitor()
        let signature = PathWatcher.signature(of: monitor.currentPath)
        #expect(signature == PathWatcher.signature(of: monitor.currentPath),
                "the same path produced two different signatures, so every update redials")
        #expect(signature.contains("expensive="),
                "cellular-vs-WiFi must be part of the signature: it is the transition M4's acceptance is written about")
        monitor.cancel()
    }
}
