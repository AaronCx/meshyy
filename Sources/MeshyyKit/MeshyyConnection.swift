// meshyy — the client transport (design doc §5, M2). Consumed by a+Terminal.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Opens a QUIC connection to meshyyd, pins the server certificate against the
// fingerprint SSH already delivered, and carries `FrameEnvelope`s.
//
// The client owns its own deadline and its own pin verdict. Both were measured in
// the M0 spike: a rejected pin does not produce a clean failure state — the group
// simply never reaches `.ready` — so waiting on connection state alone would hang
// and report nothing useful.

import CryptoKit
import Foundation
import MeshyyCore
import Network
import Security
import Synchronization

/// What the client is doing, for a UI that has to explain itself.
public enum MeshyyConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case connected
    /// Design doc §3.5: never silently degrade. Every failure carries a reason a
    /// user could act on.
    case failed(reason: String)
    case closed(reason: String)
}

public final class MeshyyConnection: @unchecked Sendable {
    /// `LocalizedError` as well as `CustomStringConvertible`, and the difference is not
    /// cosmetic. Foundation's `localizedDescription` ignores `description` on a Swift
    /// error and renders "The operation couldn't be completed.
    /// (MeshyyKit.MeshyyConnection.ConnectionError error 1.)" — which is what a user
    /// actually saw in a+Terminal's fallback banner. Every one of these cases already
    /// knows exactly what went wrong; the text just never reached the screen.
    public enum ConnectionError: Error, Equatable, CustomStringConvertible, LocalizedError {
        case pinMismatch(expected: String, actual: String)
        case noCertificate
        case timedOut(after: Duration)
        case transport(String)
        case notConnected

        public var errorDescription: String? { description }

        public var description: String {
            switch self {
            case .pinMismatch(let expected, let actual):
                "meshyy: server certificate does not match the fingerprint SSH "
                    + "delivered (expected \(expected.prefix(16))…, got \(actual.prefix(16))…). "
                    + "Refusing to connect."
            case .noCertificate:
                "meshyy: server presented no certificate"
            case .timedOut(let limit):
                "meshyy: no QUIC connection within \(limit.milliseconds)ms"
            case .transport(let detail):
                "meshyy: \(detail)"
            case .notConnected:
                "meshyy: not connected"
            }
        }
    }

    private let host: String
    private let port: UInt16
    private let expectedFingerprint: String
    private let queue = DispatchQueue(label: "meshyy.client")

    private var group: NWConnectionGroup?
    /// One stream per channel kind, opened lazily. Separate streams are the point
    /// of §5.2: a blob upload must not head-of-line block PTY bytes.
    private var streams: [ChannelKind: NWConnection] = [:]
    private var decoders: [ChannelKind: FrameDecoder] = [:]
    private var pinVerdict: Result<Void, ConnectionError>?
    private var state: MeshyyConnectionState = .idle
    private var closed = false

    /// Frames from the daemon. Set before `connect`.
    public var onFrame: (@Sendable (FrameEnvelope) -> Void)?
    /// State transitions, for the UI.
    public var onState: (@Sendable (MeshyyConnectionState) -> Void)?

    /// 5s. See the note in `clientOptions`.
    static let idleTimeoutMilliseconds = 5_000
    /// Keepalive interval. Well under the idle timeout, so a healthy but quiet
    /// session is never mistaken for a dead one — which is what makes an idle
    /// timeout this short safe.
    static let keepAliveInterval = NWProtocolQUIC.Metadata.KeepAliveBehavior.seconds(2)

    public init(host: String, port: UInt16, certificateSHA256: String) {
        self.host = host
        self.port = port
        self.expectedFingerprint = certificateSHA256.lowercased()
    }

    /// Builds a connection from a bootstrap response, which is the only way
    /// a+Terminal should construct one — it carries the pin.
    public convenience init(bootstrap: BootstrapResponse, sshHost: String) {
        self.init(
            host: bootstrap.host ?? sshHost,
            port: bootstrap.port,
            certificateSHA256: bootstrap.certSHA256
        )
    }

    // MARK: - Connect

    /// Opens the connection and the control stream.
    ///
    /// `timeout` is the client's own deadline. It exists because a pin mismatch
    /// leaves the group in `waiting` forever rather than failing, so there is no
    /// transport-level event to wait for.
    public func connect(timeout: Duration = .seconds(10)) async throws {
        transition(.connecting)

        let options = Self.clientOptions(
            expecting: expectedFingerprint,
            queue: queue,
            record: { [weak self] verdict in
                guard let self else { return }
                self.queue.async { self.pinVerdict = verdict }
            }
        )
        guard let portValue = NWEndpoint.Port(rawValue: port) else {
            throw ConnectionError.transport("bad port \(port)")
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: portValue)
        let group = NWConnectionGroup(
            with: NWMultiplexGroup(to: endpoint),
            using: NWParameters(quic: options)
        )
        self.group = group

        // A continuation rather than a semaphore: waiting on a DispatchSemaphore
        // from an async function blocks a cooperative-pool thread, which Swift 6
        // rejects outright and which can deadlock the pool under load.
        enum Outcome: Sendable {
            case ready
            case failed(String)
            case timedOut
        }
        let settled = Mutex(false)

        let outcome: Outcome = await withCheckedContinuation { continuation in
            @Sendable func settle(_ value: Outcome) {
                // Network framework will happily deliver `waiting` then `failed`
                // then `cancelled`; a continuation may only be resumed once.
                let alreadySettled = settled.withLock { current -> Bool in
                    if current { return true }
                    current = true
                    return false
                }
                guard !alreadySettled else { return }
                continuation.resume(returning: value)
            }

            group.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    settle(.ready)
                case .failed(let error):
                    settle(.failed("\(error)"))
                case .cancelled:
                    settle(.failed("cancelled"))
                default:
                    // `waiting` is routine churn, not a fault. Measured in the M0
                    // spike: it appears even on loopback before a healthy `ready`.
                    break
                }
            }
            // Required before start, or the group never leaves its initial state
            // and the state handler never fires at all. See QUICServer's note.
            group.setReceiveHandler(
                maximumMessageSize: 65536,
                rejectOversizedMessages: false
            ) { _, _, _ in }
            group.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                settle(.timedOut)
            }
        }

        // Report the pin verdict ahead of any transport error: "the certificate is
        // wrong" is the actionable message, and the timeout is only its symptom.
        if case .failure(let error) = queue.sync(execute: { pinVerdict }) ?? .success(()) {
            group.cancel()
            transition(.failed(reason: error.description))
            throw error
        }

        switch outcome {
        case .ready:
            break
        case .failed(let detail):
            group.cancel()
            transition(.failed(reason: detail))
            throw ConnectionError.transport(detail)
        case .timedOut:
            group.cancel()
            let error = ConnectionError.timedOut(after: timeout)
            transition(.failed(reason: error.description))
            throw error
        }

        // Streams can only be created once the group is ready; before that,
        // NWConnection(from:) returns nil.
        try queue.sync { try openStream(for: .control) }
        enableKeepAlive()
        transition(.connected)
    }

    static func clientOptions(
        expecting fingerprint: String,
        queue: DispatchQueue,
        record: @escaping @Sendable (Result<Void, ConnectionError>) -> Void
    ) -> NWProtocolQUIC.Options {
        let options = NWProtocolQUIC.Options(alpn: [Meshyy.alpn])
        options.initialMaxStreamsBidirectional = 64
        options.initialMaxStreamsUnidirectional = 64
        // Short on purpose, and much shorter than the daemon's.
        //
        // Network framework QUIC does NOT do connection migration: a path change
        // black-holes the connection while the group keeps reporting `.ready`
        // (measured — see design doc §6.1 and docs/qa/known-debt.md). The idle
        // timeout is therefore the *only* thing that tells a client its session has
        // gone deaf, and at the 30s default a user stares at a dead terminal for
        // half a minute. 5s plus keepalive detects it fast enough to reconnect
        // before it is worth complaining about.
        options.idleTimeout = Self.idleTimeoutMilliseconds

        // No CA, and chain validation is replaced wholesale. The certificate is
        // trusted iff its SHA-256 matches what SSH already delivered over an
        // authenticated channel (design doc §5.1), so the trust chain terminates in
        // the SSH host key the user already pinned.
        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                      let leaf = chain.first
                else {
                    record(.failure(.noCertificate))
                    complete(false)
                    return
                }
                let der = SecCertificateCopyData(leaf) as Data
                let actual = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
                if actual == fingerprint {
                    record(.success(()))
                    complete(true)
                } else {
                    record(.failure(.pinMismatch(expected: fingerprint, actual: actual)))
                    complete(false)
                }
            },
            queue
        )
        // Sent as SNI. Not used for validation — the pin replaces that — but a
        // TLS stack that saw no server name might behave differently, and matching
        // a SAN in the daemon's certificate keeps the handshake conventional.
        sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, "meshyyd.local")
        return options
    }

    /// Turns on QUIC keepalive, which is the one lever that makes a black-holed
    /// path detectable at all.
    ///
    /// Only reachable through per-connection metadata, and only once a connection
    /// is up — before that the metadata is nil. Deliberately no assertion on the
    /// getter: it reports `.off` regardless of what was set, so the only honest
    /// verification is wire behaviour, which the probe that established this did
    /// and a unit test cannot.
    private func enableKeepAlive() {
        queue.async { [weak self] in
            guard let self, let stream = self.streams[.control] else { return }
            let metadata = stream.metadata(definition: NWProtocolQUIC.definition)
            (metadata as? NWProtocolQUIC.Metadata)?.keepAlive = Self.keepAliveInterval
        }
    }

    // MARK: - Streams

    private func openStream(for kind: ChannelKind) throws {
        guard let group else { throw ConnectionError.notConnected }
        if streams[kind] != nil { return }
        guard let stream = NWConnection(from: group) else {
            throw ConnectionError.transport(
                "could not open a \(kind) stream — the connection is not ready"
            )
        }
        streams[kind] = stream
        decoders[kind] = FrameDecoder()
        stream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                // FAIL, not close. `.closed` is for an end the CLIENT chose —
                // reattaching, detaching, shutting down — and a session ignores it
                // by design. A stream that died under us is the opposite: the app
                // is left holding a transport that says "connected", swallows every
                // byte written to it (the outbox drops the throw), and never
                // reconnects, because the one event that would have driven recovery
                // was filed as a deliberate close. That is the tab that looks fine
                // and eats your typing — and dictation worst of all, since an
                // utterance is one all-or-nothing burst where a lost keystroke
                // would merely have looked like a typo.
                self?.fail(reason: "\(kind) stream failed: \(error)")
            case .cancelled:
                // Already on `queue` — see the note in `pump`.
                self?.streams.removeValue(forKey: kind)
            default:
                break
            }
        }
        stream.start(queue: queue)
        pump(stream, kind: kind)
    }

    private func pump(_ stream: NWConnection, kind: ChannelKind) {
        stream.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                // ALREADY ON `queue`: NWConnection delivers this completion on the
                // queue the connection was started with. A `queue.sync` here would
                // be a same-queue sync, which libdispatch traps (SIGTRAP) rather
                // than merely deadlocking — so the decoder is touched directly.
                var decoder = self.decoders[kind] ?? FrameDecoder()
                do {
                    let frames = try decoder.push(Array(data))
                    self.decoders[kind] = decoder
                    for frame in frames { self.onFrame?(frame) }
                } catch {
                    // Also a failure, not a choice: an undecodable stream is a dead
                    // connection, and the client must be told so it can redial.
                    self.fail(reason: "protocol error on \(kind): \(error)")
                    return
                }
            }
            if isComplete || error != nil {
                if kind == .control {
                    // These are NOT the same event, and M4 has to tell them apart.
                    //
                    // `isComplete` is a clean FIN: the daemon really did end the
                    // stream, and redialling would resurrect a session its owner
                    // closed. `error` is the transport giving up — an idle timeout
                    // after the path went silent — where the daemon said nothing and
                    // may not even know. That one must redial.
                    //
                    // Reporting both as "the daemon closed the control stream" was
                    // wrong twice over: it drove the wrong recovery, and it told the
                    // user their session had ended when their network had dropped.
                    // Measured with the 1d-bis relay, where black-holing BOTH
                    // directions still produced "the daemon closed the control
                    // stream" — a message the daemon could not possibly have sent.
                    if let error {
                        self.fail(reason: "the connection to the daemon failed: \(error)")
                    } else {
                        self.close(reason: "the daemon closed the control stream")
                    }
                }
                return
            }
            self.pump(stream, kind: kind)
        }
    }

    // MARK: - Send

    public func send(_ envelope: FrameEnvelope) throws {
        try queue.sync {
            guard group != nil, !closed else { throw ConnectionError.notConnected }
            if streams[envelope.kind] == nil { try openStream(for: envelope.kind) }
            guard let stream = streams[envelope.kind] ?? streams[.control] else {
                throw ConnectionError.notConnected
            }
            stream.send(content: Data(envelope.encoded), completion: .contentProcessed { _ in })
        }
    }

    public func send(_ frame: ControlFrame) throws {
        try send(.control(frame))
    }

    public func sendKeystrokes(_ bytes: [UInt8]) throws {
        try send(.pty(0, bytes))
    }

    // MARK: - Lifetime

    public var currentState: MeshyyConnectionState {
        queue.sync { state }
    }

    /// Only ever called from `connect`, which runs on the caller's context rather
    /// than on `queue` — so the sync is safe. Anything on `queue` must set `state`
    /// directly instead, as `close` does.
    private func transition(_ new: MeshyyConnectionState) {
        queue.sync { state = new }
        onState?(new)
    }

    public func close(reason: String = "client closed the connection") {
        teardown(to: .closed(reason: reason))
    }

    /// Tears down and reports `.failed` rather than `.closed`.
    ///
    /// The distinction is what M4 dispatches on: `.failed` means the path died and a
    /// redial is the right answer, `.closed` means the peer or the user ended the
    /// session and redialling would resurrect it. Design doc §3.5 — fail visible, and
    /// visibly the *right* failure.
    func fail(reason: String) {
        teardown(to: .failed(reason: reason))
    }

    private func teardown(to end: MeshyyConnectionState) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            for stream in self.streams.values { stream.cancel() }
            self.streams.removeAll()
            self.decoders.removeAll()
            self.group?.cancel()
            self.group = nil
            self.state = end
            self.onState?(end)
        }
    }
}
