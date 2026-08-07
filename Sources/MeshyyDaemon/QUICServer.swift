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

    /// Whether a peer may attach: loopback, or the Tailscale CGNAT range.
    ///
    /// 100.64.0.0/10 is the shared-address space Tailscale assigns from (RFC 6598), so
    /// this admits a tailnet without admitting the LAN it happens to ride on. Checked on
    /// the address rather than the interface type because the interface a tailnet rides
    /// on is not a property this daemon can reason about correctly — see the note in
    /// `start()`.
    static func isPermittedPeer(_ endpoint: NWEndpoint?) -> Bool {
        // No path yet. Refusing here would drop legitimate peers on a timing detail, and
        // the token and certificate pin are the real controls — this check is
        // defence-in-depth. So allow, and say so rather than pretending it was checked.
        guard let endpoint else { return true }
        // FAIL OPEN on a shape this does not recognise, and refuse only what it can
        // positively identify as outside the policy.
        //
        // The other way round turned a hardening measure into an outage twice: this
        // refused every endpoint form it had not anticipated, which on a CI runner meant
        // a loopback QUIC connection that simply never established. The token is
        // single-use and short-TTL and the certificate is pinned over authenticated SSH
        // — THOSE are the controls. This check exists to keep the daemon off a hostile
        // LAN, and a check that cannot read an address has learned nothing about whether
        // the address is hostile.
        guard case .hostPort(let host, _) = endpoint else { return true }
        let address: String
        switch host {
        case .ipv4(let v4): address = "\(v4)"
        case .ipv6(let v6):
            let text = "\(v6)"
            // ::ffff:100.x.y.z and ::1 both arrive here on a dual-stack listener.
            if text.hasPrefix("::1") { return true }
            address = text.contains(".") ? String(text.split(separator: ":").last ?? "") : text
        default: return true   // an address form this cannot read — see above
        }
        let bare = address.split(separator: "%").first.map(String.init) ?? address
        if bare == "127.0.0.1" || bare == "::1" { return true }
        let octets = bare.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return true }   // unparseable — see above
        // 100.64.0.0/10
        return octets[0] == 100 && (64...127).contains(octets[1])
    }
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
        // §8's policy — loopback and Tailscale, not the hostile LAN — is enforced on the
        // PEER ADDRESS at accept time, not by prohibiting interface types.
        //
        // The previous implementation set prohibitedInterfaceTypes = [.wifi, .cellular,
        // .wiredEthernet] on the reasoning that this "lets loopback and utun through".
        // That reasoning is WRONG, and it silently broke the product's main use case:
        // Network framework classifies a Tailscale utun path by the interface it rides
        // ON, so a phone connecting over Tailscale-on-WiFi is prohibited exactly like a
        // phone on the raw LAN. Measured: a QUIC dial to this daemon's Tailscale address
        // times out after 10s, every time.
        //
        // The symptom was brutal precisely because it was invisible — the daemon happily
        // accepted the SSH bootstrap and created the session, so `list` showed a live
        // session that no client could ever reach, and the app fell back to SSH after
        // eating the full connect timeout. An address check is testable and cannot be
        // wrong about what an interface "really" is.

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
            guard let self else { return }
            self.accept(group, restrictPeers: !self.bindAllInterfaces)
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

    private func accept(_ group: NWConnectionGroup, restrictPeers: Bool) {
        let peer = QUICPeer(group: group, store: store, tokens: tokens, restrictPeers: restrictPeers) { [weak self] finished in
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
    /// Enforce §8's loopback-or-Tailscale policy on the peer address.
    ///
    /// Checked HERE rather than on the group, because `NWConnectionGroup` exposes no
    /// endpoint or path — the remote address only becomes visible on an individual
    /// stream. The previous attempt used `prohibitedInterfaceTypes` on the listener
    /// instead, which did not do what it claimed: Network framework classifies a
    /// Tailscale utun path by the interface it rides on, so prohibiting `.wifi` silently
    /// blocked every tailnet client. That is the product's main use case, and it failed
    /// invisibly for hours.
    private let restrictPeers: Bool

    private var attachment: SessionAttachment?
    /// One decoder per stream. Frames are length-prefixed per stream, so sharing a
    /// decoder across streams would interleave two length prefixes and desync both.
    private var decoders: [ObjectIdentifier: FrameDecoder] = [:]
    private var streams: [ObjectIdentifier: NWConnection] = [:]
    /// Which stream to answer a given LANE on, learned from where its frames
    /// arrived (see `ChannelKind.wireLane`). Control and pty share one lane so
    /// their relative order survives the wire: a `modes` frame that could
    /// overtake — or be overtaken by — the output around it silently undoes
    /// the very state it asserts, and switching pty output onto a second
    /// stream mid-session let NEW bytes overtake OLD ones under flow-control
    /// stall. Blobs keep their own lane, which is all §5.2 ever needed: a
    /// bulk upload must not head-of-line block the terminal.
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
        restrictPeers: Bool = true,
        onFinish: @escaping (QUICPeer) -> Void
    ) {
        self.group = group
        self.queue = DispatchQueue(label: "meshyy.quic.peer")
        self.restrictPeers = restrictPeers
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
        if restrictPeers, let remote = stream.currentPath?.remoteEndpoint,
           !QUICServer.isPermittedPeer(remote) {
            // §3.5: refuse visibly and immediately. Dropping this silently would leave
            // the client waiting out its whole connect timeout with no idea why — which
            // is exactly how the interface-type version of this policy hid for hours.
            // stderr, not `log`: there is no logger in this target, and a bare `log`
            // resolves to Foundation's logarithm, which compiles in some contexts and
            // silently is not what anyone meant.
            let peer = String(describing: remote)
            FileHandle.standardError.write(Data("""
                meshyyd: refused a QUIC peer at \(peer) — not loopback or Tailscale. \
                Start meshyyd with --all-interfaces to allow it.

                """.utf8))
            stream.cancel()
            return
        }
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
            // Bind the LANE to this stream the first time it is seen, so replies
            // go back the way they came. Keyed on the lane rather than the raw
            // kind: an older client that opens a separate pty stream for its
            // keystrokes must not pull this daemon's output onto it — output
            // stays ordered behind the control frames on the hello stream.
            if streamForKind[frame.kind.wireLane] == nil {
                streamForKind[frame.kind.wireLane] = stream
            }
            attachment?.receive(frame)
        }
    }

    private func write(_ envelope: FrameEnvelope) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            let target = self.streamForKind[envelope.kind.wireLane]
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
    ///
    /// Streams are FINished, not cancelled outright. `inFlightSends` reaching zero
    /// only means Network framework *accepted* the bytes — `contentProcessed` fires
    /// when the transport takes them, not when the peer has them. Cancelling at that
    /// moment resets the QUIC stream, and a reset tells the peer to discard whatever
    /// was still in flight. The symptom was a client that saw a silent hang instead
    /// of the Error explaining why its token was refused, and it only appeared under
    /// load: alone the bytes had already left, in a busy suite they had not.
    ///
    /// So: signal end-of-stream, let the peer drain, and only then cancel.
    private func tearDown() {
        guard !closed else { return }
        closed = true
        let attachment = self.attachment
        self.attachment = nil

        let closing = Array(streams.values)
        for stream in closing {
            stream.send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in }
            )
        }
        streams.removeAll()
        decoders.removeAll()
        streamForKind.removeAll()

        // Bounded: a peer that never reads must not hold the connection open, but a
        // peer that is merely busy must get its last frame.
        queue.asyncAfter(deadline: .now() + Self.drainGrace) { [group] in
            for stream in closing { stream.cancel() }
            group.cancel()
        }

        attachment?.finish()
        onFinish(self)
    }

    /// How long a FINished stream is given to reach the peer before it is cancelled.
    private static let drainGrace: TimeInterval = 0.5
}
