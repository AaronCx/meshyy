// meshyy — when a reconnect fires, and how many fire at once (M4).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// M4 was rewritten because M0 removed both of its original mechanisms: Network
// framework QUIC exposes no 0-RTT and does no connection migration. Reconnect
// *speed* is solved and measured — 2.06 round trips, essentially optimal without
// 0-RTT. What is unsolved is **when** the reconnect fires.
//
// THREE WAYS TO FIND OUT THE PATH IS GONE, and they are not redundant:
//
//   4a  NWPathMonitor    An interface transition is announced. Nothing has failed
//                        yet, which is what makes this the cheapest signal: act on
//                        the announcement rather than waiting for a timeout to
//                        confirm what the OS already said.
//   4b  Heartbeat        A NAT rebind announces nothing. Measured in 1d-bis: the
//                        byte flow stops, and the client's transport still reports
//                        `.connected`. A round trip on the control stream is the
//                        only thing that can notice it.
//   4c  Foreground       The most common reconnect in real use, and it has a
//                        lifecycle event rather than a network one.
//
// 4d IS WHY THEY LIVE TOGETHER. All three fire within a few hundred milliseconds of
// an airplane-mode toggle. Three concurrent redials against one session is a real
// bug class and a security-relevant one — each redial spends a single-use token, so
// racing them means tokens minted and abandoned, and a daemon watching for token
// abuse would be right to be suspicious. One reconnect in flight, enforced here and
// asserted in tests rather than observed.

import Foundation
import Network

/// Why a reconnect was requested. Carried through so a failure names its trigger,
/// and so the coordinator can tell a trigger that carries new information from one
/// that is merely a repeat.
public enum ReconnectTrigger: Sendable, Equatable, CustomStringConvertible {
    /// 4a. `NWPathMonitor` reported an interface change.
    case pathChanged(String)
    /// 4b. The heartbeat deadline passed with no pong.
    case heartbeatLost(misses: Int)
    /// 4c. The app came back to the foreground.
    case foreground
    /// The transport itself reported a failure. Rare — see 1d-bis.
    case transportFailed(String)
    /// The app asked directly.
    case manual

    public var description: String {
        switch self {
        case .pathChanged(let detail): "path changed (\(detail))"
        case .heartbeatLost(let misses): "heartbeat lost (\(misses) missed)"
        case .foreground: "app foregrounded"
        case .transportFailed(let reason): "transport failed (\(reason))"
        case .manual: "requested by the app"
        }
    }

    /// Whether this trigger tells us something the last attempt did not know.
    ///
    /// A path change or a foreground means the world changed since the attempt that
    /// is currently failing, so waiting out a backoff computed against the *old*
    /// world is exactly wrong — the user has just switched to a working network and
    /// is watching a dead terminal. A heartbeat miss carries no such news: it is the
    /// same silence, observed again.
    var carriesNewInformation: Bool {
        switch self {
        case .pathChanged, .foreground, .manual: true
        case .heartbeatLost, .transportFailed: false
        }
    }
}

/// Serialises reconnect attempts and backs off on repeated failure (M4 4d).
///
/// Deliberately knows nothing about QUIC, tokens or sessions: it is handed a closure
/// and guarantees only that one runs at a time. That keeps the concurrency rule
/// testable without standing up a daemon, which is what "asserted, not observed"
/// requires.
public actor ReconnectCoordinator {
    /// First retry immediate, then doubling. The measured redial cost is ~160ms on
    /// the LTE profile, so an early retry is cheap; the cap exists so a daemon that
    /// is genuinely down (laptop shut, host rebooting) is not hammered for hours.
    public struct Backoff: Sendable, Equatable {
        public var first: Duration = .zero
        public var initial: Duration = .milliseconds(500)
        public var maximum: Duration = .seconds(8)
        public var multiplier: Double = 2

        public init() {}

        /// Delay before attempt number `failures + 1`.
        func delay(afterFailures failures: Int) -> Duration {
            guard failures > 0 else { return first }
            let scaled = initial.timeInterval * pow(multiplier, Double(failures - 1))
            return .milliseconds(Int(min(scaled, maximum.timeInterval) * 1000))
        }
    }

    /// In-memory counters for assertions and a diagnostics screen. Nothing here is
    /// recorded, persisted or sent anywhere — CLAUDE.md's zero-data-collection rule is
    /// absolute, and the privacy gate rejected an earlier name for this type on sight,
    /// which is the gate working rather than being pedantic.
    ///
    /// A test that watches log lines to check single-flight is testing the logging.
    public struct Counters: Sendable, Equatable {
        /// Attempts actually started.
        public var attempts = 0
        /// Triggers that arrived while an attempt was already running.
        public var suppressed = 0
        /// Attempts that threw.
        public var failures = 0
        /// Peak concurrent attempts. MUST be 1. This is the 4d assertion.
        public var peakConcurrent = 0
        /// Backoff waits skipped because a trigger brought new information.
        public var backoffsSkipped = 0
    }

    private var backoff: Backoff
    private var running = false
    private var consecutiveFailures = 0
    /// A trigger that arrived mid-attempt and deserves another go once this one ends.
    private var pending: ReconnectTrigger?
    private var counters = Counters()
    private var concurrent = 0

    public init(backoff: Backoff = Backoff()) {
        self.backoff = backoff
    }

    public func snapshot() -> Counters { counters }

    /// Resets the failure count. Called on a successful attach, so a session that has
    /// been up for hours does not inherit a long backoff from a bad patch last week.
    public func succeeded() {
        consecutiveFailures = 0
    }

    /// Requests a reconnect, running `attempt` at most once concurrently.
    ///
    /// Returns when this call's work is done. A caller whose trigger was suppressed
    /// returns immediately rather than queueing, because the attempt already running
    /// will produce the same outcome — with one exception, handled by `pending`: a
    /// trigger carrying new information earns a retry after the current attempt ends.
    @discardableResult
    public func request(
        _ trigger: ReconnectTrigger,
        attempt: @Sendable () async throws -> Void
    ) async -> Bool {
        guard !running else {
            counters.suppressed += 1
            // Keep the most informative pending trigger rather than the most recent:
            // a path change followed by two heartbeat misses should retry as a path
            // change, which skips the backoff.
            if trigger.carriesNewInformation, pending?.carriesNewInformation != true {
                pending = trigger
            } else if pending == nil {
                pending = trigger
            }
            return false
        }

        running = true
        defer { running = false }

        var next: ReconnectTrigger? = trigger
        var lastSucceeded = false

        while let current = next {
            next = nil

            let wait = backoff.delay(afterFailures: consecutiveFailures)
            if wait > .zero {
                if current.carriesNewInformation {
                    // The world changed. A delay computed against the old one is not
                    // patience, it is latency the user is sitting through.
                    counters.backoffsSkipped += 1
                } else {
                    try? await Task.sleep(for: wait)
                }
            }

            concurrent += 1
            counters.peakConcurrent = max(counters.peakConcurrent, concurrent)
            counters.attempts += 1
            do {
                try await attempt()
                consecutiveFailures = 0
                lastSucceeded = true
            } catch {
                consecutiveFailures += 1
                counters.failures += 1
                lastSucceeded = false
            }
            concurrent -= 1

            // A trigger that arrived mid-attempt gets its own go, but only if this
            // attempt did not already fix things — otherwise a burst of triggers
            // during a successful reconnect would each redial a healthy session.
            if let queued = pending, !lastSucceeded {
                pending = nil
                next = queued
            } else {
                pending = nil
            }
        }
        return lastSucceeded
    }
}

/// Watches for interface transitions (M4 4a).
///
/// The callback is the trigger, not a failed write. By the time a write fails the
/// user has already been staring at a dead terminal for an idle timeout; the path
/// update arrives while the old interface is still nominally up.
public final class PathWatcher: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "meshyy.path")
    private var lastSignature: String?
    private var started = false

    public init() {}

    /// Calls `onChange` when the set of usable interfaces changes.
    ///
    /// Signature, not identity: `NWPathMonitor` emits updates for changes that do not
    /// affect reachability at all (a link-quality hint, a DNS config reload). Redial
    /// is cheap but not free, and a redial storm on a flapping network is worse than
    /// the stall it avoids — so the comparison is on what the path *is*, and an
    /// update that says the same thing is dropped.
    public func start(onChange: @escaping @Sendable (String) -> Void) {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let signature = Self.signature(of: path)
            guard signature != self.lastSignature else { return }
            let previous = self.lastSignature
            self.lastSignature = signature
            // The first update describes the path the connection was made on. There is
            // nothing to reconnect to yet, and firing here would redial every session
            // immediately after opening it.
            guard previous != nil else { return }
            onChange("\(previous ?? "none") -> \(signature)")
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
    }

    /// What the path is, reduced to the parts that decide whether a connection made
    /// on the old one can still work.
    static func signature(of path: NWPath) -> String {
        let interfaces = path.availableInterfaces
            .map { "\($0.type):\($0.name)" }
            .sorted()
            .joined(separator: ",")
        return "\(path.status)|\(interfaces)|expensive=\(path.isExpensive)"
    }
}

/// Tracks liveness with ping/pong on the control stream (M4 4b).
///
/// Pure bookkeeping — it neither sends nor sleeps — so the deadline logic is testable
/// without a network or a clock. The owner drives it.
public struct HeartbeatMonitor: Sendable {
    /// Tuned in docs/provenance.md against the 1d-bis chaos harness. Summary: the
    /// QUIC idle timeout already detects total silence in ~4.5s, so the heartbeat
    /// earns its place by being faster, and a false positive costs one ~160ms redial.
    public var interval: Duration
    public var missesBeforeDead: Int

    /// Nonces sent and not yet answered, oldest first.
    private var outstanding: [UInt64] = []
    private var nextNonce: UInt64 = 1
    /// Probes minted over this monitor's life. Purely observational — bug #2
    /// was a heartbeat that silently stopped RUNNING, and the survival test
    /// that guards it can only fail by waiting out the full idle timeout. A
    /// counter that must keep climbing names that defect directly, in
    /// milliseconds. Never reset: reset() forgets unanswered probes, not the
    /// fact that probing is alive.
    public private(set) var ticks: UInt64 = 0

    public init(interval: Duration = .seconds(1), missesBeforeDead: Int = 3) {
        self.interval = interval
        self.missesBeforeDead = missesBeforeDead
    }

    public var missed: Int { outstanding.count }

    /// True once enough probes have gone unanswered to call the path dead.
    public var isDead: Bool { outstanding.count >= missesBeforeDead }

    /// Mints the next probe.
    public mutating func nextPing() -> ControlFrameNonce {
        let nonce = nextNonce
        nextNonce &+= 1
        ticks &+= 1
        outstanding.append(nonce)
        return ControlFrameNonce(value: nonce)
    }

    /// Records a pong. Answering nonce N retires N and everything older, because the
    /// probes travel in order on one stream and an older one cannot now arrive first.
    ///
    /// An unrecognised nonce is ignored rather than treated as an answer: a straggler
    /// from a previous connection must not resurrect a session that has already been
    /// declared dead, or the deadline never fires on a flapping path.
    public mutating func received(nonce: UInt64) {
        guard let index = outstanding.firstIndex(of: nonce) else { return }
        outstanding.removeFirst(index + 1)
    }

    /// Forgets outstanding probes. Called on attach: probes sent down a connection
    /// that no longer exists can never be answered, and counting them would declare
    /// the fresh connection dead on arrival.
    public mutating func reset() {
        outstanding.removeAll()
    }
}

/// A minted heartbeat nonce. A named type so a nonce cannot be confused with an
/// offset at a call site — both are `UInt64` and both appear on the control stream.
public struct ControlFrameNonce: Sendable, Equatable {
    public let value: UInt64
}
