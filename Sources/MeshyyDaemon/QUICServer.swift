// meshyy — the QUIC listener (design doc §5.2, M2).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Everything undocumented here was measured in the M0 spike; see
// docs/spikes/2026-07-27-quic-network-framework.md. Three findings shape this file
// and each has cost an afternoon to rediscover, so they are called out at the
// point they matter rather than only in the spike:
//
//   1. `newConnectionHandler` and `newConnectionGroupHandler` are mutually
//      exclusive. Setting both fails the listener with EINVAL.
//   2. `setReceiveHandler` must be called before `start` on a connection group, or
//      the group never leaves its initial state and its state handler never fires
//      even once — with no error to diagnose.
//   3. `NWConnection(from: group)` returns nil until the group is `.ready`.
//
// Framing: every stream carries `FrameEnvelope`, so a stream is self-describing
// and one code path serves QUIC and the unix socket. QUIC still buys what §5.2
// wants — separate streams mean a blob upload cannot head-of-line block PTY bytes
// — but the channel's identity is in the envelope rather than in a stream id we
// would have to negotiate.

import Foundation
import MeshyyCore
import Network
import Security

public final class QUICServer: @unchecked Sendable {
    public enum ServerError: Error, CustomStringConvertible {
        case identityRejected
        case listenerFailed(String)
        case noPort

        public var description: String {
            switch self {
            case .identityRejected:
                "quic: sec_identity_create rejected the daemon identity"
            case .listenerFailed(let detail):
                "quic: listener failed: \(detail)"
            case .noPort:
                "quic: listener became ready without a port"
            }
        }
    }

    private let identity: DaemonIdentity
    private let store: SessionStore
    private let tokens: TokenActor
    private let bindAllInterfaces: Bool
    private let queue = DispatchQueue(label: "meshyy.quic.listener")

    private var listener: NWListener?
    private var peers: [ObjectIdentifier: QUICPeer] = [:]

    /// The port the listener is bound to, once started.
    public private(set) var boundPort: UInt16 = 0

    public init(
        identity: DaemonIdentity,
        store: SessionStore,
        tokens: TokenActor,
        bindAllInterfaces: Bool = false
    ) {
        self.identity = identity
        self.store = store
        self.tokens = tokens
        self.bindAllInterfaces = bindAllInterfaces
    }

    /// QUIC options shared by both ends, so a mismatch is impossible by
    /// construction rather than by two lists staying in sync.
    static func baseOptions() -> NWProtocolQUIC.Options {
        let options = NWProtocolQUIC.Options(alpn: [Meshyy.alpn])
        // Control + one per PTY + blobs, with room to spare. Design doc §12.4 asks
        // whether multiple PTYs per connection are worth it; this does not decide
        // that, it just does not foreclose it.
        options.initialMaxStreamsBidirectional = 64
        options.initialMaxStreamsUnidirectional = 64
        // 30s. Long enough that a brief cellular stall is not a disconnect, short
        // enough that a suspended iOS app's dead connection is reaped rather than
        // held open with its ring buffer.
        options.idleTimeout = 30_000
        return options
    }

    public func start(port requestedPort: UInt16 = 0) throws -> UInt16 {
        let options = Self.baseOptions()
        guard let secIdentity = sec_identity_create(identity.secIdentity) else {
            throw ServerError.identityRejected
        }
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)

        let parameters = NWParameters(quic: options)
        parameters.allowLocalEndpointReuse = true
        if !bindAllInterfaces {
            // Design doc §8: loopback or the Tailscale interface by default;
            // binding everything takes an explicit flag and a startup warning.
            // Network framework has no "loopback plus one utun" constraint, so the
            // honest implementation is to prohibit the interface types that would
            // put this on a hostile LAN and let loopback and utun through.
            parameters.prohibitedInterfaceTypes = [.wifi, .cellular, .wiredEthernet]
        }

        let listener: NWListener
        do {
            if requestedPort == 0 {
                listener = try NWListener(using: parameters)
            } else {
                guard let port = NWEndpoint.Port(rawValue: requestedPort) else {
                    throw ServerError.listenerFailed("bad port \(requestedPort)")
                }
                listener = try NWListener(using: parameters, on: port)
            }
        } catch {
            throw ServerError.listenerFailed("\(error)")
        }

        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: String?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure = "\(error)"; ready.signal()
            case .cancelled: ready.signal()
            default: break
            }
        }
        // NOTE: newConnectionHandler must NOT also be set — the two are mutually
        // exclusive and setting both fails the listener with EINVAL.
        listener.newConnectionGroupHandler = { [weak self] group in
            self?.accept(group)
        }
        listener.start(queue: queue)
        self.listener = listener

        guard ready.wait(timeout: .now() + 10) == .success else {
            listener.cancel()
            throw ServerError.listenerFailed("timed out becoming ready")
        }
        if let failure {
            listener.cancel()
            throw ServerError.listenerFailed(failure)
        }
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw ServerError.noPort
        }
        boundPort = port
        return port
    }

    private func accept(_ group: NWConnectionGroup) {
        let peer = QUICPeer(group: group, store: store, tokens: tokens) { [weak self] finished in
            self?.queue.async { [weak self] in
                self?.peers.removeValue(forKey: ObjectIdentifier(finished))
            }
        }
        peers[ObjectIdentifier(peer)] = peer
        peer.start()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        queue.sync {
            for peer in peers.values { peer.close() }
            peers.removeAll()
        }
    }

    public var connectedPeerCount: Int {
        queue.sync { peers.count }
    }
}

/// One client connection: a QUIC connection group and the streams on it.
final class QUICPeer: @unchecked Sendable {
    private let group: NWConnectionGroup
    private let queue: DispatchQueue
    private let onFinish: (QUICPeer) -> Void

    private var attachment: SessionAttachment?
    /// One decoder per stream. Frames are length-prefixed per stream, so sharing a
    /// decoder across streams would interleave two length prefixes and desync both.
    private var decoders: [ObjectIdentifier: FrameDecoder] = [:]
    private var streams: [ObjectIdentifier: NWConnection] = [:]
    /// Which stream to answer a given channel on, learned from where its frames
    /// arrived. Replying on the stream a channel came in on is what preserves
    /// §5.2's benefit: PTY bytes never queue behind a blob upload.
    private var streamForKind: [ChannelKind: NWConnection] = [:]
    private var closed = false
    /// Frames handed to Network framework but not yet on the wire.
    ///
    /// A refused attach sends an Error and then finishes, and finishing cancels the
    /// streams. `NWConnection.send` is asynchronous, so cancelling immediately threw
    /// the Error away and the client saw a silent hang instead of a reason — which
    /// is exactly the "fail visible" failure design doc §3.5 forbids. Close is
    /// therefore deferred until the queue drains.
    private var inFlightSends = 0
    private var closeWhenDrained = false

    init(
        group: NWConnectionGroup,
        store: SessionStore,
        tokens: TokenActor,
        onFinish: @escaping (QUICPeer) -> Void
    ) {
        self.group = group
        self.queue = DispatchQueue(label: "meshyy.quic.peer")
        self.onFinish = onFinish
        self.attachment = SessionAttachment(
            store: store,
            // Design doc §5.1: the token was issued over SSH and names the session.
            authority: .bootstrapToken(tokens),
            send: { [weak self] envelope in self?.write(envelope) },
            close: { [weak self] in self?.close() }
        )
    }

    func start() {
        group.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                // `waiting` is normal churn on this API, including on loopback, and
                // must not be surfaced as a fault — design doc §3.5 says fail
                // visible, not fail noisily.
                break
            }
        }
        group.newConnectionHandler = { [weak self] stream in
            self?.adopt(stream)
        }
        // Required before start, or the group never leaves its initial state and
        // no handler ever fires. A multiplex group has no group-level messages, so
        // the body is empty — but it must exist.
        group.setReceiveHandler(maximumMessageSize: 65536, rejectOversizedMessages: false) { _, _, _ in }
        group.start(queue: queue)
    }

    private func adopt(_ stream: NWConnection) {
        let key = ObjectIdentifier(stream)
        streams[key] = stream
        decoders[key] = FrameDecoder()
        stream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.retire(stream)
            default:
                break
            }
        }
        stream.start(queue: queue)
        pump(stream)
    }

    private func pump(_ stream: NWConnection) {
        stream.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.ingest(Array(data), from: stream)
            }
            if isComplete || error != nil {
                self.retire(stream)
                return
            }
            self.pump(stream)
        }
    }

    private func ingest(_ bytes: [UInt8], from stream: NWConnection) {
        let key = ObjectIdentifier(stream)
        var decoder = decoders[key] ?? FrameDecoder()
        let frames: [FrameEnvelope]
        do {
            frames = try decoder.push(bytes)
        } catch {
            // A length-prefixed stream cannot resynchronise. Report and drop the
            // whole connection rather than the one stream: a client that framed one
            // stream wrongly is not trustworthy on the others.
            write(.control(.error(code: 400, message: "\(error)")))
            close()
            return
        }
        decoders[key] = decoder

        for frame in frames {
            // Bind the channel to this stream the first time it is seen, so replies
            // go back the way they came.
            if streamForKind[frame.kind] == nil { streamForKind[frame.kind] = stream }
            attachment?.receive(frame)
        }
    }

    private func write(_ envelope: FrameEnvelope) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            let target = self.streamForKind[envelope.kind]
                ?? self.streamForKind[.control]
                ?? self.streams.values.first
            guard let target else { return } // nothing open yet; the client will retry

            self.inFlightSends += 1
            target.send(content: Data(envelope.encoded), completion: .contentProcessed { _ in
                // Already on `queue`: NWConnection completions land on the queue the
                // connection was started with.
                self.inFlightSends -= 1
                if self.closeWhenDrained, self.inFlightSends == 0 {
                    self.tearDown()
                }
            })
        }
    }

    private func retire(_ stream: NWConnection) {
        let key = ObjectIdentifier(stream)
        streams.removeValue(forKey: key)
        decoders.removeValue(forKey: key)
        for (kind, bound) in streamForKind where bound === stream {
            streamForKind.removeValue(forKey: kind)
        }
        // The control stream going away ends the session; a pty or blob stream
        // closing on its own does not.
        if streams.isEmpty { close() }
    }

    func close() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            // Let anything already handed to the transport reach the wire first —
            // an Error frame explaining why the connection is closing is worth more
            // than closing 20ms sooner. Bounded so a wedged send cannot leak the
            // peer forever.
            if self.inFlightSends > 0, !self.closeWhenDrained {
                self.closeWhenDrained = true
                self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.tearDown()
                }
                return
            }
            self.tearDown()
        }
    }

    /// Actually releases everything. Always on `queue`.
    private func tearDown() {
        guard !closed else { return }
        closed = true
        let attachment = self.attachment
        self.attachment = nil
        for stream in streams.values { stream.cancel() }
        streams.removeAll()
        decoders.removeAll()
        streamForKind.removeAll()
        group.cancel()
        attachment?.finish()
        onFinish(self)
    }
}
