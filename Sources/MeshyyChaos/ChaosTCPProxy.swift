// meshyy — order-preserving latency-injecting TCP proxy.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Used by the design doc §1 benchmark to measure what a real SSH + multiplexer
// attach costs at a given RTT, and by the §11 chaos harness for the TCP+TLS
// fallback transport. Userspace rather than dummynet because dummynet needs
// root — see docs/provenance.md, 2026-07-27.

import Foundation
import Network

/// A TCP proxy that forwards `listenPort` to `targetHost:targetPort`, delaying
/// every byte by the profile's one-way delay in each direction.
///
/// Byte order is always preserved: a jittered delivery time is clamped forward
/// to the previous one, because reordering a TCP stream corrupts it rather than
/// emulating anything real. Loss and reorder in the profile are ignored here;
/// use `ChaosUDPProxy` for those.
public final class ChaosTCPProxy: @unchecked Sendable {
    public enum ProxyError: Error, CustomStringConvertible {
        case listenerFailed(String)
        case notStarted

        public var description: String {
            switch self {
            case .listenerFailed(let detail): "chaos: listener failed: \(detail)"
            case .notStarted: "chaos: proxy not started"
            }
        }
    }

    private let targetHost: String
    private let targetPort: UInt16
    private let requestedPort: UInt16
    private let profile: ChaosProfile
    private let queue = DispatchQueue(label: "meshyy.chaos.tcp")

    private var listener: NWListener?
    private var pairs: [ObjectIdentifier: Pair] = [:]

    /// Bytes forwarded client→server and server→client, for sanity checks.
    public private(set) var bytesUp = 0
    public private(set) var bytesDown = 0

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
    }

    /// Binds and starts accepting. Returns the port actually bound, which is
    /// what callers need when `listenPort` was 0.
    public func start() throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only. This is a test tool; it must never be reachable off-box.
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
        let failure = Mutex<String?>(nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failure.withLock { $0 = String(describing: error) }
                ready.signal()
            case .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
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
            for pair in pairs.values { pair.cancel() }
            pairs.removeAll()
        }
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection pumping

    /// Queue-confined: every field is only ever touched on `queue`.
    private final class Pair: @unchecked Sendable {
        let client: NWConnection
        let server: NWConnection
        /// Monotonic clamp per direction so jitter never reorders the stream.
        var nextUp: DispatchTime = .now()
        var nextDown: DispatchTime = .now()
        var cancelled = false

        init(client: NWConnection, server: NWConnection) {
            self.client = client
            self.server = server
        }

        func cancel() {
            guard !cancelled else { return }
            cancelled = true
            client.cancel()
            server.cancel()
        }
    }

    private func accept(_ client: NWConnection) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(targetHost),
            port: NWEndpoint.Port(rawValue: targetPort) ?? .any
        )
        let server = NWConnection(to: endpoint, using: .tcp)
        let pair = Pair(client: client, server: server)
        pairs[ObjectIdentifier(pair.client)] = pair

        client.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.retire(pair) }
            if case .failed = state { self?.retire(pair) }
        }
        server.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.pump(pair, from: pair.client, to: pair.server, up: true)
                self.pump(pair, from: pair.server, to: pair.client, up: false)
            case .failed, .cancelled:
                self.retire(pair)
            default:
                break
            }
        }

        client.start(queue: queue)
        server.start(queue: queue)

        if let sever = profile.severAfter {
            queue.asyncAfter(deadline: .now() + sever.timeInterval) { [weak self] in
                self?.retire(pair)
            }
        }
    }

    private func retire(_ pair: Pair) {
        guard !pair.cancelled else { return }
        pair.cancel()
        pairs.removeValue(forKey: ObjectIdentifier(pair.client))
    }

    private func pump(_ pair: Pair, from source: NWConnection, to sink: NWConnection, up: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.forward(data, pair: pair, to: sink, up: up)
            }
            if isComplete || error != nil {
                // Delay the teardown by one delivery interval so bytes already
                // in flight are not cut off by the FIN racing ahead of them.
                self.queue.asyncAfter(deadline: .now() + self.profile.delay.timeInterval + 0.05) {
                    self.retire(pair)
                }
                return
            }
            self.pump(pair, from: source, to: sink, up: up)
        }
    }

    private func forward(_ data: Data, pair: Pair, to sink: NWConnection, up: Bool) {
        var generator = SystemRandomNumberGenerator()
        let delay = profile.sampleDelay(using: &generator)
        let earliest = DispatchTime.now() + delay.timeInterval
        let clamped = up ? max(earliest, pair.nextUp) : max(earliest, pair.nextDown)
        if up { pair.nextUp = clamped } else { pair.nextDown = clamped }

        if up { bytesUp += data.count } else { bytesDown += data.count }

        queue.asyncAfter(deadline: clamped) {
            guard !pair.cancelled else { return }
            sink.send(content: data, completion: .contentProcessed { _ in })
        }
    }
}

/// Minimal mutual-exclusion box. The standard library's `Mutex` is available,
/// but this file needs it before `Synchronization` is imported on every
/// platform the package targets, and the surface used here is one line.
private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
