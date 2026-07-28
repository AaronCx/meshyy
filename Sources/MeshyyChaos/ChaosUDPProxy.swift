// meshyy — datagram relay for impairing a live QUIC connection (hardening 1d-bis).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// QUIC runs over UDP, so you do not need to understand QUIC to impair it — you need
// to mangle datagrams. This relay sits between client and daemon and never inspects
// a payload, so connection IDs, version negotiation and coalesced packets all pass
// through opaquely. That is what makes it clean-room-safe as well as correct: it
// knows nothing about the protocol it is degrading.
//
// WHAT THIS CAN AND CANNOT SHOW. QUIC retransmits through ordinary loss, so a
// per-datagram drop rate mostly surfaces as latency rather than as anything the
// application can see. That is the correct result and worth asserting, but it is not
// a test of reconnect. The knobs that produce application-visible behaviour are the
// episodic ones, and they are driven as method calls rather than declared in the
// profile because a test needs them to happen at a chosen moment:
//
//   blackHole(_:for:)   100% loss in one direction for a window, then healing.
//                       The deafness case. Otherwise very hard to produce reliably,
//                       and M4's path-change detection is defined against it.
//   kill(after:)        Hard stop at a byte offset — the wire ends mid-frame.
//   halfOpen(_:)        One direction dies, the other survives. A peer that only
//                       watches its send path calls this healthy forever.
//   rebind()            The relay changes its own source port. A faithful NAT
//                       rebind, and the reason connection IDs exist.
//
// DETERMINISM. Every random decision comes from one seeded generator confined to the
// proxy queue, so a run replays exactly given `profile.seed`. Tests print the seed on
// failure. `SystemRandomNumberGenerator` would make a failure a story rather than a
// reproduction.

import Foundation
import Network

/// A relayed datagram, for asserting on what the network actually did.
public struct ChaosDatagram: Sendable {
    /// Seconds since the relay started, when it arrived.
    public let at: Double
    /// Seconds since the relay started, when it was released onward.
    public let releaseAt: Double
    /// Client to daemon.
    public let up: Bool
    public let bytes: Int
    /// False when the relay dropped it.
    public let delivered: Bool
    /// True when it was held back so the next datagram overtook it.
    public let held: Bool
}

/// One direction of travel, so an impairment can be attributed to a side.
public enum ChaosDirection: Sendable, CustomStringConvertible {
    case up, down, both

    public var description: String {
        switch self {
        case .up: "client→daemon"
        case .down: "daemon→client"
        case .both: "both directions"
        }
    }

    func covers(up isUp: Bool) -> Bool {
        switch self {
        case .up: isUp
        case .down: !isUp
        case .both: true
        }
    }
}

/// A userspace UDP relay that degrades a real QUIC connection.
///
/// Demux model: one listener flow per client address on the front, one fresh
/// connection to the target per flow on the back. The back socket's ephemeral local
/// port is the address the daemon sees, so each client is a distinct apparent peer
/// and replies land on the socket belonging to exactly one of them.
public final class ChaosUDPProxy: @unchecked Sendable {
    public enum ProxyError: Error, CustomStringConvertible {
        case listenerFailed(String)
        public var description: String {
            switch self {
            case .listenerFailed(let detail): "chaos-udp: listener failed: \(detail)"
            }
        }
    }

    private let targetHost: String
    private let targetPort: UInt16
    private let requestedPort: UInt16
    private let profile: ChaosProfile
    private let queue = DispatchQueue(label: "meshyy.chaos.udp")
    private let epoch = DispatchTime.now()

    private var listener: NWListener?
    private var flows: [ObjectIdentifier: Flow] = [:]
    /// Queue-confined, seeded from the profile. See the header note on determinism.
    private var random: ChaosRandom

    /// Directions currently black-holed, with the time each window ends.
    private var blackHoleUntil: (up: Double, down: Double) = (0, 0)
    /// Directions killed outright, never to recover.
    private var dead: (up: Bool, down: Bool) = (false, false)
    /// Byte budget per direction before a hard kill; nil means no limit.
    private var killAfterBytes: (up: Int?, down: Int?) = (nil, nil)

    private var stats = Stats()

    public struct Stats: Sendable {
        public var datagramsUp = 0
        public var datagramsDown = 0
        public var bytesUp = 0
        public var bytesDown = 0
        public var droppedUp = 0
        public var droppedDown = 0
        public var reorderedUp = 0
        public var reorderedDown = 0
        public var flows = 0
        public var receiveErrors = 0
        public var sendErrors = 0
        public var rebinds = 0
        public var trace: [ChaosDatagram] = []

        /// For a failure message: what the relay did, in one line.
        public var summary: String {
            "up=\(datagramsUp)/\(bytesUp)B down=\(datagramsDown)/\(bytesDown)B "
                + "dropped=\(droppedUp)/\(droppedDown) reordered=\(reorderedUp)/\(reorderedDown) "
                + "flows=\(flows) rebinds=\(rebinds) rxErr=\(receiveErrors) txErr=\(sendErrors)"
        }
    }

    public init(
        listenPort: UInt16 = 0,
        targetHost: String,
        targetPort: UInt16,
        profile: ChaosProfile
    ) {
        self.requestedPort = listenPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.profile = profile
        self.random = ChaosRandom(seed: profile.seed)
    }

    /// Binds and returns the port the client should be pointed at.
    public func start() throws -> UInt16 {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback

        let listener: NWListener
        if requestedPort == 0 {
            listener = try NWListener(using: parameters)
        } else {
            guard let port = NWEndpoint.Port(rawValue: requestedPort) else {
                throw ProxyError.listenerFailed("bad port \(requestedPort)")
            }
            listener = try NWListener(using: parameters, on: port)
        }

        let ready = DispatchSemaphore(value: 0)
        let failure = ChaosLocked<String?>(nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error):
                failure.withLock { $0 = String(describing: error) }
                ready.signal()
            case .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] flow in self?.accept(flow) }
        listener.start(queue: queue)
        self.listener = listener

        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw ProxyError.listenerFailed("timed out binding")
        }
        if let detail = failure.withLock({ $0 }) {
            listener.cancel()
            throw ProxyError.listenerFailed(detail)
        }
        guard let bound = listener.port?.rawValue else {
            listener.cancel()
            throw ProxyError.listenerFailed("no port after ready")
        }
        return bound
    }

    public func stop() {
        queue.sync {
            for flow in flows.values { flow.cancel() }
            flows.removeAll()
        }
        listener?.cancel()
        listener = nil
    }

    /// Counters and the datagram trace, taken on the proxy queue so they cannot tear.
    public func snapshot() -> Stats {
        queue.sync { stats }
    }

    /// Seconds since the relay started, on the same clock as the trace.
    public func elapsed() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - epoch.uptimeNanoseconds) / 1e9
    }

    // MARK: - Episodic impairment

    /// Drop everything in `direction` for `duration`, then heal.
    ///
    /// The deafness case: packets leave and nothing comes back, with no error and no
    /// close. Indistinguishable at the endpoint from a dead network, which is the
    /// point — it is also indistinguishable from a NAT rebind, which is why M4 needs
    /// a heartbeat rather than an error callback.
    public func blackHole(_ direction: ChaosDirection, for duration: Duration) {
        queue.sync {
            let until = elapsed() + duration.timeInterval
            if direction.covers(up: true) { blackHoleUntil.up = max(blackHoleUntil.up, until) }
            if direction.covers(up: false) { blackHoleUntil.down = max(blackHoleUntil.down, until) }
        }
    }

    /// Stop relaying `direction` after this many more bytes, mid-datagram-stream.
    ///
    /// The budget is checked before forwarding, so the kill lands at an arbitrary
    /// point in the wire rather than on a convenient frame boundary.
    public func kill(after bytes: Int, direction: ChaosDirection = .both) {
        queue.sync {
            if direction.covers(up: true) { killAfterBytes.up = bytes }
            if direction.covers(up: false) { killAfterBytes.down = bytes }
        }
    }

    /// Kill one direction permanently and leave the other working.
    ///
    /// A peer that only watches whether its own sends succeed will call this
    /// connection healthy indefinitely.
    public func halfOpen(_ direction: ChaosDirection) {
        queue.sync {
            if direction.covers(up: true) { dead.up = true }
            if direction.covers(up: false) { dead.down = true }
        }
    }

    /// Cut every flow dead — no close, no ICMP, just silence.
    ///
    /// Design doc §6.1: this is the iOS-suspension kill.
    public func severAll() {
        queue.sync {
            for flow in flows.values { flow.cancel() }
            flows.removeAll()
        }
    }

    /// Local ports the daemon currently sees traffic arriving from.
    public func sourcePorts() -> [UInt16] {
        queue.sync {
            flows.values.compactMap { flow in
                if case .hostPort(_, let port) = flow.server.currentPath?.localEndpoint {
                    return port.rawValue
                }
                return nil
            }
        }
    }

    /// Replace every back socket with a fresh one, so the daemon sees the same QUIC
    /// connection arriving from a new source port. That is a NAT rebind, and
    /// surviving it is exactly what connection IDs are for.
    ///
    /// With `keepOld`, the previous socket stays open and keeps pumping, which tells
    /// a daemon that ignores the new address but still answers the old one apart from
    /// one that drops the connection.
    public func rebind(keepOld: Bool = false) {
        queue.sync {
            for flow in flows.values where !flow.cancelled {
                let old = flow.server
                // Detach the old socket's handler FIRST. It still points at this flow,
                // and its own `.cancelled` would otherwise retire the whole flow —
                // front socket, replacement and all. This cost an hour in the spike:
                // the rebind looked like "QUIC refuses to migrate" when it was the
                // relay tearing itself down.
                old.stateUpdateHandler = { _ in }

                let replacement = NWConnection(to: targetEndpoint(), using: backParameters())
                flow.server = replacement
                flow.errorsDown = 0
                replacement.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.flushBacklog(flow)
                        self.pump(flow, from: replacement, up: false)
                    default: break
                    }
                }
                replacement.start(queue: queue)
                stats.rebinds += 1
                if !keepOld {
                    // Drop the old socket only once the new one is wired, so a reply
                    // in flight is not lost to a gap the test would read as loss.
                    queue.asyncAfter(deadline: .now() + 0.2) { old.cancel() }
                }
            }
        }
    }

    // MARK: - Per-client flow

    /// Queue-confined. One per client source address.
    private final class Flow: @unchecked Sendable {
        let client: NWConnection   // listener-side flow: replies go to that client
        var server: NWConnection   // our own socket toward the target
        /// A datagram held back so the next one overtakes it, per direction. Carries
        /// its arrival time so the trace stays honest about when it landed.
        var heldUp: (data: Data, at: Double)?
        var heldDown: (data: Data, at: Double)?
        /// Queued until the back socket is ready.
        var backlogUp: [(data: Data, at: Double)] = []
        var cancelled = false
        /// Consecutive receive errors per direction. A run of them means the socket
        /// really is gone and the retry loop should stop.
        var errorsUp = 0
        var errorsDown = 0

        init(client: NWConnection, server: NWConnection) {
            self.client = client
            self.server = server
        }

        /// Records an error and reports whether the direction should give up.
        func shouldGiveUp(up: Bool) -> Bool {
            if up { errorsUp += 1; return errorsUp > 500 }
            errorsDown += 1
            return errorsDown > 500
        }

        func cancel() {
            guard !cancelled else { return }
            cancelled = true
            client.cancel()
            server.cancel()
        }
    }

    private func targetEndpoint() -> NWEndpoint {
        NWEndpoint.hostPort(
            host: NWEndpoint.Host(targetHost),
            port: NWEndpoint.Port(rawValue: targetPort) ?? .any
        )
    }

    private func backParameters() -> NWParameters {
        let parameters = NWParameters.udp
        parameters.requiredInterfaceType = .loopback
        return parameters
    }

    private func accept(_ client: NWConnection) {
        stats.flows += 1
        let server = NWConnection(to: targetEndpoint(), using: backParameters())
        let flow = Flow(client: client, server: server)
        flows[ObjectIdentifier(client)] = flow

        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.retire(flow)
            default: break
            }
        }
        server.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.flushBacklog(flow)
                self.pump(flow, from: flow.server, up: false)
            case .failed, .cancelled:
                self.retire(flow)
            default: break
            }
        }

        client.start(queue: queue)
        server.start(queue: queue)
        pump(flow, from: client, up: true)

        if let sever = profile.severAfter {
            queue.asyncAfter(deadline: .now() + sever.timeInterval) { [weak self] in
                self?.retire(flow)
            }
        }
    }

    private func flushBacklog(_ flow: Flow) {
        let queued = flow.backlogUp
        flow.backlogUp = []
        for item in queued { deliver(item.data, arrivedAt: item.at, flow: flow, up: true) }
    }

    private func retire(_ flow: Flow) {
        guard !flow.cancelled else { return }
        flow.cancel()
        flows.removeValue(forKey: ObjectIdentifier(flow.client))
    }

    /// `receiveMessage` is what preserves datagram boundaries. `receive(min:max:)` is
    /// free to coalesce, which would corrupt QUIC.
    private func pump(_ flow: Flow, from source: NWConnection, up: Bool) {
        source.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.arrived(data, flow: flow, up: up) }
            if error != nil {
                // A UDP receive error is not necessarily terminal — on loopback an
                // ICMP port-unreachable surfaces here as ECONNREFUSED while the socket
                // stays usable. Bailing out is what silently wedges a relay: the
                // direction goes mute and the QUIC peer sits in loss recovery until
                // its idle timeout, which reads as a product bug.
                self.stats.receiveErrors += 1
                switch source.state {
                case .cancelled, .failed: return   // the socket itself is gone
                default: break
                }
                guard !flow.cancelled, !flow.shouldGiveUp(up: up) else { return }
                self.queue.asyncAfter(deadline: .now() + 0.002) { [weak self] in
                    guard let self, !flow.cancelled else { return }
                    self.pump(flow, from: source, up: up)
                }
                return
            }
            guard !flow.cancelled else { return }
            self.pump(flow, from: source, up: up)
        }
    }

    private func arrived(_ data: Data, flow: Flow, up: Bool) {
        let at = elapsed()
        if up {
            stats.datagramsUp += 1
            stats.bytesUp += data.count
        } else {
            stats.datagramsDown += 1
            stats.bytesDown += data.count
        }

        if shouldDrop(data, up: up, at: at) {
            if up { stats.droppedUp += 1 } else { stats.droppedDown += 1 }
            stats.trace.append(ChaosDatagram(
                at: at, releaseAt: at, up: up, bytes: data.count, delivered: false, held: false
            ))
            return
        }

        // Reorder: hold this datagram back and let the next one overtake it. A timeout
        // flush keeps the last datagram of a flight from being lost outright, which
        // would make reordering indistinguishable from loss.
        if profile.reorder > 0, random.next(in: 0..<1) < profile.reorder {
            let alreadyHeld = up ? flow.heldUp : flow.heldDown
            if alreadyHeld == nil {
                if up {
                    flow.heldUp = (data, at)
                    stats.reorderedUp += 1
                } else {
                    flow.heldDown = (data, at)
                    stats.reorderedDown += 1
                }
                queue.asyncAfter(deadline: .now() + profile.delay.timeInterval + 0.02) {
                    [weak self] in self?.releaseHeld(flow, up: up)
                }
                return
            }
        }

        deliverOrQueue(data, arrivedAt: at, flow: flow, up: up, held: false)
        // Whatever just went through overtakes the held datagram; release it behind.
        releaseHeld(flow, up: up)
    }

    private func releaseHeld(_ flow: Flow, up: Bool) {
        if up, let held = flow.heldUp {
            flow.heldUp = nil
            deliverOrQueue(held.data, arrivedAt: held.at, flow: flow, up: true, held: true)
        }
        if !up, let held = flow.heldDown {
            flow.heldDown = nil
            deliverOrQueue(held.data, arrivedAt: held.at, flow: flow, up: false, held: true)
        }
    }

    /// Every reason a datagram does not go through, in one place so a test can reason
    /// about which one fired from the trace.
    private func shouldDrop(_ data: Data, up: Bool, at: Double) -> Bool {
        if up ? dead.up : dead.down { return true }
        if at < (up ? blackHoleUntil.up : blackHoleUntil.down) { return true }

        // Hard kill at a byte offset: spend the budget, and once it is gone the
        // direction is dead for good. Checked before forwarding, so the wire ends
        // wherever the budget ran out rather than on a frame boundary.
        if let budget = up ? killAfterBytes.up : killAfterBytes.down {
            let remaining = budget - data.count
            if remaining < 0 {
                if up { dead.up = true } else { dead.down = true }
                return true
            }
            if up { killAfterBytes.up = remaining } else { killAfterBytes.down = remaining }
        }

        let rate = (up ? profile.lossUp : profile.lossDown) ?? profile.loss
        return rate > 0 && random.next(in: 0..<1) < rate
    }

    private func deliverOrQueue(
        _ data: Data, arrivedAt: Double, flow: Flow, up: Bool, held: Bool
    ) {
        if up, flow.server.state != .ready {
            flow.backlogUp.append((data, arrivedAt))
            return
        }
        deliver(data, arrivedAt: arrivedAt, flow: flow, up: up, held: held)
    }

    private func deliver(
        _ data: Data, arrivedAt: Double, flow: Flow, up: Bool, held: Bool = false
    ) {
        let delay = profile.sampleDelay(using: &random)
        let sink = up ? flow.server : flow.client
        stats.trace.append(ChaosDatagram(
            at: arrivedAt,
            releaseAt: elapsed() + delay.timeInterval,
            up: up,
            bytes: data.count,
            delivered: true,
            held: held
        ))

        if delay == .zero {
            send(data, over: sink)
        } else {
            queue.asyncAfter(deadline: .now() + delay.timeInterval) { [weak self] in
                guard !flow.cancelled else { return }
                self?.send(data, over: sink)
            }
        }
    }

    private func send(_ data: Data, over sink: NWConnection) {
        sink.send(content: data, completion: .contentProcessed { [weak self] error in
            // A send that fails is a datagram the relay lost while claiming to have
            // delivered it. Swallowing this is how a relay lies to its own trace, and
            // then a real bug looks like injected loss.
            guard error != nil, let self else { return }
            self.queue.async { self.stats.sendErrors += 1 }
        })
    }
}

/// SplitMix64. Same published algorithm as `MeshyyTestSupport.SplitMix64`, duplicated
/// deliberately: `MeshyyChaos` backs the shipped `meshyy-chaos` executable, and
/// depending on a test-support target to save eight lines would pull it into a
/// product.
struct ChaosRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A double in `range`, drawn from the same seeded stream as everything else.
    mutating func next(in range: Range<Double>) -> Double {
        let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

final class ChaosLocked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
