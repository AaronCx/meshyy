// meshyy — network impairment profile shared by the TCP and UDP chaos proxies.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.

import Foundation

/// How badly to treat traffic passing through a chaos proxy.
///
/// One-way values. A `delay` of 40ms yields an 80ms round trip, which is the
/// number that matters for the design doc §1 measurement: what a user pays is
/// (round trips × RTT), and only the RTT is observable from the endpoint.
public struct ChaosProfile: Sendable, Equatable {
    /// One-way delay applied in each direction.
    public var delay: Duration
    /// Uniform jitter added to `delay`, in `[0, jitter]`.
    public var jitter: Duration
    /// Datagram loss probability in `[0, 1]`. UDP only — dropping bytes from a
    /// TCP stream would corrupt it rather than emulate loss, so the TCP proxy
    /// ignores this and models congestion as delay.
    public var loss: Double
    /// Probability a datagram is held back and delivered after the next one.
    /// UDP only.
    public var reorder: Double
    /// Sever every connection this many seconds after it opens. `nil` never
    /// severs. Emulates the iOS-suspension kill described in design doc §6.1.
    public var severAfter: Duration?

    public init(
        delay: Duration = .zero,
        jitter: Duration = .zero,
        loss: Double = 0,
        reorder: Double = 0,
        severAfter: Duration? = nil
    ) {
        self.delay = delay
        self.jitter = jitter
        self.loss = loss
        self.reorder = reorder
        self.severAfter = severAfter
    }

    /// Pass-through. Used to measure the proxy's own floor cost so it can be
    /// subtracted from impaired runs.
    public static let pristine = ChaosProfile()

    /// One-way delay for a given round-trip time.
    public static func rtt(_ milliseconds: Int) -> ChaosProfile {
        ChaosProfile(delay: .milliseconds(milliseconds / 2))
    }

    /// Sampled one-way delay for a single unit of traffic.
    func sampleDelay(using generator: inout some RandomNumberGenerator) -> Duration {
        guard jitter > .zero else { return delay }
        let jitterNanos = jitter.wholeNanoseconds
        let sampled = Int64.random(in: 0...max(0, jitterNanos), using: &generator)
        return delay + .nanoseconds(sampled)
    }
}

extension Duration {
    /// Total nanoseconds, saturating. `components` is (seconds, attoseconds).
    var wholeNanoseconds: Int64 {
        let (seconds, attoseconds) = components
        let fromSeconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !fromSeconds.overflow else { return .max }
        let fromAttos = attoseconds / 1_000_000_000
        let total = fromSeconds.partialValue.addingReportingOverflow(fromAttos)
        return total.overflow ? .max : total.partialValue
    }

    /// Seconds as a `Double`, for `DispatchQueue.asyncAfter` and reporting.
    ///
    /// Named to match `MeshyyCore`'s accessor, and deliberately not `seconds`:
    /// that collides with the static `Duration.seconds(_:)` factory.
    public var timeInterval: Double {
        Double(wholeNanoseconds) / 1_000_000_000
    }
}
