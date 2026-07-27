// meshyy — the session protocol, independent of how bytes arrive.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Design doc §3.3: "Transport is replaceable. The resume protocol is the core."
// This is where that is enforced rather than asserted. Everything about attaching,
// resuming, resizing, acking and tearing down lives here; a transport supplies a
// way to send a `FrameEnvelope` and hands over the ones it receives.
//
// The unix socket (M1) and QUIC (M2) are both thin wrappers around this, which is
// why the M1 socket tests are also tests of the QUIC path's behaviour.

import Foundation
import MeshyyCore
import Synchronization

/// Serialises access to the daemon's bootstrap tokens.
public actor TokenActor {
    private var store: TokenStore
    private let clock = ContinuousClock()

    public init(ttl: Duration = TokenStore.defaultTTL) {
        self.store = TokenStore(ttl: ttl)
    }

    public func issue(sessionID: String) -> String {
        store.issue(sessionID: sessionID, now: clock.now)
    }

    public func redeem(
        token: String,
        assertingSession: String? = nil
    ) -> Result<String, TokenStore.RedemptionFailure> {
        store.redeem(token: token, assertingSession: assertingSession, now: clock.now)
    }

    public func revokeAll(sessionID: String) {
        store.revokeAll(sessionID: sessionID)
    }

    public var outstandingCount: Int { store.outstandingCount }
}

/// How a transport proves the client is allowed to attach.
public enum AttachAuthority: Sendable {
    /// Filesystem permissions did it. The socket is 0600 in a 0700 directory, so
    /// opening it already proved the caller is this user, and the session is named
    /// directly. Inventing a token here would be theatre.
    case localSocket
    /// Design doc §5.1. The client presents a single-use token issued over the
    /// already-authenticated SSH channel; the session comes *from the token*, so a
    /// client never gets to name a session it was not given.
    case bootstrapToken(TokenActor)
}

/// Drives one client's session over any transport.
public final class SessionAttachment: @unchecked Sendable {
    private let store: SessionStore
    private let authority: AttachAuthority
    private let send: @Sendable (FrameEnvelope) -> Void
    private let closeTransport: @Sendable () -> Void

    /// All mutable state behind one lock.
    ///
    /// A `Mutex` rather than an `NSLock` because Swift 6 forbids `NSLock.lock()`
    /// from an async context, and rather than an actor because `receive` is called
    /// from a transport's read callback on the hot path — making it `async` would
    /// put an await between every arriving frame and the PTY.
    private struct State {
        var session: PTYSession?
        var subscription: UUID?
        var pumpTask: Task<Void, Never>?
        var attached = false
        var finished = false
        /// Highest offset the client has confirmed consuming. Design doc §6.2:
        /// this is what a reconnect resumes from, and the client is the only thing
        /// that knows it — so the daemon records what it is told, never guesses.
        var ackedOffset: UInt64 = 0
    }

    private let state = Mutex(State())

    public init(
        store: SessionStore,
        authority: AttachAuthority,
        send: @escaping @Sendable (FrameEnvelope) -> Void,
        close: @escaping @Sendable () -> Void
    ) {
        self.store = store
        self.authority = authority
        self.send = send
        self.closeTransport = close
    }

    // MARK: - Inbound

    public func receive(_ envelope: FrameEnvelope) {
        switch envelope.kind {
        case .control:
            guard let frame = try? ControlFrame.decode(envelope.payload) else {
                // Design doc §5.3: an undecodable control frame from a newer peer
                // is ignored, not fatal.
                return
            }
            handle(frame)

        case .pty:
            let bytes = envelope.payload
            guard let session = currentSession else { return }
            Task { try? await session.send(bytes) }

        case .blob:
            // M7. Answered rather than silently dropped, so a client that tries it
            // learns why nothing happened.
            send(.control(.error(code: 501, message: "blob channels are not implemented (M7)")))
        }
    }

    private func handle(_ frame: ControlFrame) {
        switch frame {
        case .hello(let hello):
            attach(hello)

        case .resize(let cols, let rows):
            guard let session = currentSession else { return }
            let size = TerminalSize(cols: cols, rows: rows)
            Task { try? await session.resize(to: size) }

        case .ack(_, let offset):
            // Monotonic: a client must never be able to walk its own offset
            // backwards, or a replayed/reordered Ack would make the next resume
            // re-send bytes it already had and duplicate them on screen.
            state.withLock { $0.ackedOffset = max($0.ackedOffset, offset) }

        case .bye:
            finish()

        // Everything else is server-to-client only. Receiving one means a confused
        // peer, not an attack, so it is ignored rather than fatal.
        default:
            break
        }
    }

    // MARK: - Attach

    private func attach(_ hello: ControlFrame.Hello) {
        let alreadyAttached = state.withLock { current -> Bool in
            let was = current.attached
            current.attached = true
            return was
        }

        guard !alreadyAttached else {
            send(.control(.error(code: 400, message: "already attached on this connection")))
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await self.resolveSession(hello)
                try await self.begin(session: session, hello: hello)
            } catch {
                self.send(.control(.error(code: 400, message: "\(error)")))
                self.finish()
            }
        }
    }

    private enum AttachError: Error, CustomStringConvertible {
        case tokenRejected(TokenStore.RedemptionFailure)
        case sessionGone(String)
        case noSessionNamed

        var description: String {
            switch self {
            case .tokenRejected(let failure): "attach refused: \(failure)"
            case .sessionGone(let id): "attach refused: session \(id) no longer exists"
            case .noSessionNamed: "attach refused: no session named"
            }
        }
    }

    /// Turns a `Hello` into the session it is entitled to, per the transport's
    /// authority. This is the only place authorisation happens.
    private func resolveSession(_ hello: ControlFrame.Hello) async throws -> PTYSession {
        switch authority {
        case .localSocket:
            let name = hello.session ?? "default"
            return try await store.attachOrCreate(
                name: name,
                size: TerminalSize(cols: hello.cols, rows: hello.rows)
            )

        case .bootstrapToken(let tokens):
            // The token names the session. `hello.session` is deliberately NOT
            // consulted: honouring it would let a client with any valid token
            // attach to any session, which is the confused-deputy hole the
            // token-to-session binding exists to close.
            switch await tokens.redeem(token: hello.token) {
            case .failure(let failure):
                throw AttachError.tokenRejected(failure)
            case .success(let sessionID):
                guard let session = await store.session(withID: sessionID) else {
                    throw AttachError.sessionGone(sessionID)
                }
                return session
            }
        }
    }

    private func begin(session: PTYSession, hello: ControlFrame.Hello) async throws {
        // Apply the client's size unconditionally. On the local path the session
        // may have been created with it, but on the QUIC path the session already
        // existed — it was created during bootstrap, before any client had said how
        // big its screen was — so relying on creation-time size left every QUIC
        // session at the 80x24 default.
        try? await session.resize(to: TerminalSize(cols: hello.cols, rows: hello.rows))

        let (decision, events, token) = await session.attach(resumeFrom: hello.resumeFrom)
        let info = await session.info

        state.withLock {
            $0.session = session
            $0.subscription = token
            $0.ackedOffset = hello.resumeFrom ?? 0
        }

        send(.control(.welcome(.init(
            sessionID: info.sessionID,
            bufferedFrom: info.bufferedFrom,
            bufferedTo: info.bufferedTo
        ))))

        // Design doc §3.5: never silently degrade. The client is told the screen
        // was rebuilt rather than continued *before* the bytes arrive, so it can
        // clear instead of splicing a hole into its scrollback.
        switch decision {
        case .replay, .fresh:
            break
        case .replayFromAnchor(let anchor, _, _):
            send(.control(.resumeTooOld(ptyID: 0, earliestOffset: anchor)))
        case .mustRedraw(let earliest, _):
            send(.control(.resumeTooOld(ptyID: 0, earliestOffset: earliest)))
        case .impossible(let latest):
            send(.control(.error(
                code: 409,
                message: "resume offset is ahead of the session; latest is \(latest)"
            )))
        }

        if !decision.bytes.isEmpty {
            for chunk in decision.bytes.chunked(into: FrameEnvelope.maximumPayload) {
                send(.pty(0, chunk))
            }
        }

        // Tell the client the current line discipline and screen mode immediately,
        // so it does not have to wait for a change to know the state.
        send(.control(.termios(info.termios)))
        send(.control(.screenMode(alt: info.altScreen)))

        let pump = Task { [weak self] in
            for await event in events {
                guard let self, !self.isFinished else { return }
                self.forward(event)
            }
        }
        state.withLock { $0.pumpTask = pump }
    }

    // MARK: - Outbound

    private func forward(_ event: SessionEvent) {
        switch event {
        case .output(_, let bytes):
            // A single PTY read is at most 64 KiB and the frame cap is 1 MiB, so
            // chunking never triggers in practice — but a replay of a full 4 MB
            // ring buffer would, and a frame larger than the cap would be
            // rejected by the peer's decoder rather than delivered.
            for chunk in bytes.chunked(into: FrameEnvelope.maximumPayload) {
                send(.pty(0, chunk))
            }
        case .termios(let state):
            send(.control(.termios(state)))
        case .screenMode(let alt):
            send(.control(.screenMode(alt: alt)))
        case .agent(let kind, let agentID, let detail):
            send(.control(.agentEvent(kind: kind, agentID: agentID, detail: detail)))
        case .exited(let status):
            send(.control(.bye(reason: "session exited with status \(status)")))
            finish()
        }
    }

    // MARK: - Lifetime

    private var currentSession: PTYSession? {
        state.withLock { $0.session }
    }

    public var isFinished: Bool {
        state.withLock { $0.finished }
    }

    /// The offset the client last confirmed. Exposed for tests and diagnostics.
    public var confirmedOffset: UInt64 {
        state.withLock { $0.ackedOffset }
    }

    public func finish() {
        let teardown = state.withLock { current -> (Task<Void, Never>?, PTYSession?, UUID?)? in
            guard !current.finished else { return nil }
            current.finished = true
            let captured = (current.pumpTask, current.session, current.subscription)
            current.pumpTask = nil
            return captured
        }
        guard let teardown else { return }

        teardown.0?.cancel()
        if let session = teardown.1, let subscription = teardown.2 {
            Task { await session.detach(subscription) }
        }
        closeTransport()
    }
}

extension Array {
    /// Splits into runs of at most `size`. Returns `[self]` when it already fits,
    /// so the common path allocates nothing extra.
    func chunked(into size: Int) -> [[Element]] {
        guard count > size else { return [Array(self)] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
