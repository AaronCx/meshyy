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

    /// Ordered work queue for anything that mutates the PTY.
    ///
    /// `Task { await session.send(bytes) }` per frame is WRONG: tasks enqueued on an
    /// actor run in an unspecified order, not FIFO. Two keystroke chunks arriving
    /// back to back could reach the PTY reversed — scrambled input — and a resize
    /// followed immediately by a command could apply after it. CI caught the resize
    /// case; the input case is the one that would have been blamed on the network.
    ///
    /// An AsyncStream preserves yield order and has one consumer, so wire order is
    /// PTY order by construction. Same fix as `MeshyySession.ingress` on the client.
    private enum PTYWork: Sendable {
        case write([UInt8])
        case resize(TerminalSize)
    }

    private let work: AsyncStream<PTYWork>
    private let workContinuation: AsyncStream<PTYWork>.Continuation
    private let workTask = Mutex<Task<Void, Never>?>(nil)

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

        let (stream, continuation) = AsyncStream<PTYWork>.makeStream(
            // Unbounded: dropping a keystroke to relieve backpressure is not a
            // trade-off, it is data loss the user would attribute to the network.
            bufferingPolicy: .unbounded
        )
        self.work = stream
        self.workContinuation = continuation
    }

    // MARK: - Inbound

    public func receive(_ envelope: FrameEnvelope) {
        // Any frame at all is proof this client still exists — including a ping,
        // which is the only traffic a client that is merely WATCHING produces. A
        // transport does not learn of a force-quit peer until its idle timeout,
        // so this timestamp is the daemon's earliest honest evidence.
        if let session = currentSession, let token = state.withLock({ $0.subscription }) {
            Task { await session.noteClientActivity(token) }
        }
        switch envelope.kind {
        case .control:
            guard let frame = try? ControlFrame.decode(envelope.payload) else {
                // Design doc §5.3: an undecodable control frame from a newer peer
                // is ignored, not fatal.
                return
            }
            handle(frame)

        case .pty:
            // Straight onto the ordered queue. The queue itself holds work until the
            // attach completes, so there is no separate pre-attach path to get wrong.
            workContinuation.yield(.write(envelope.payload))

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
            // Ordered with input, not raced against it: a resize followed by a
            // command must apply before the command runs, or a full-screen program
            // draws at the old size.
            workContinuation.yield(.resize(TerminalSize(cols: cols, rows: rows)))

        case .ack(_, let offset):
            // Monotonic: a client must never be able to walk its own offset
            // backwards, or a replayed/reordered Ack would make the next resume
            // re-send bytes it already had and duplicate them on screen.
            state.withLock { $0.ackedOffset = max($0.ackedOffset, offset) }

        case .ping(let nonce):
            // Answered immediately and unconditionally, ahead of any session state.
            // A ping that queued behind PTY work would measure the daemon's backlog
            // rather than the path, and M4 would then redial a healthy session
            // precisely when it is busiest.
            //
            // Echoing the client's nonce rather than minting one is what lets the
            // client tell a fresh answer from a straggler.
            send(.control(.pong(nonce: nonce)))

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
        //
        // `resyncSize`, not `resize`: unconditionally is not enough on its own. A
        // program inside the session can be out of sync with a PTY that is ALREADY the
        // right size, and then re-sending that size changes nothing and signals nobody,
        // so it stays out of sync for the life of the session. An attach is exactly
        // when that must be repaired, because it is exactly when a client has been
        // away and may have missed the change.
        try? await session.resyncSize(to: TerminalSize(cols: hello.cols, rows: hello.rows))

        let (decision, events, token) = await session.attach(resumeFrom: hello.resumeFrom)
        let info = await session.info

        // The transport can die while this attach is in flight — Hello arrives, the
        // app is force-quit, and `finish()` runs before this point. finish() is
        // one-shot: it already captured session=nil and can never detach what gets
        // stored after it. Storing anyway would leave a subscriber nobody owns —
        // `attachedClients` reads 1 for the session's whole life (so it is never
        // offered for resume), and its unbounded event stream buffers every byte of
        // output with no consumer. So the store is conditional on the same lock
        // finish() uses, and a lost race detaches immediately instead of leaking.
        let lostToFinish = state.withLock { current -> Bool in
            if current.finished { return true }
            current.session = session
            current.subscription = token
            current.ackedOffset = hello.resumeFrom ?? 0
            return false
        }
        if lostToFinish {
            await session.detach(token)
            return
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

        // Always state where the replay starts, even when it is empty and even when
        // it is exactly what the client asked for. A client that has to infer the
        // base gets it wrong on a fresh or anchored attach, and an offset that is
        // wrong by a rewind is worse than no offset at all.
        send(.control(.replayBase(ptyID: 0, offset: decision.replayBase)))

        if !decision.bytes.isEmpty {
            for chunk in decision.bytes.chunked(into: FrameEnvelope.maximumPayload) {
                send(.pty(0, chunk))
            }
            // A REPLAY IS ONLY VALID AT THE GEOMETRY IT WAS CAPTURED AT.
            //
            // The buffer is a byte stream recorded while some earlier client was
            // attached, and it carries that client's geometry inside it — most
            // damagingly DECSTBM, the scroll region. Replaying a stream captured at 24
            // rows into a client that is 60 rows tall leaves `ESC[1;24r` as the last
            // word on the subject, and the emulator then refuses to paint anything
            // below row 24 no matter how tall it is.
            //
            // Measured exactly that: a 60-row client received a replay whose scroll
            // regions were all `1;24`. The user saw a terminal that drew its top half
            // and left the rest black, and it did not happen over plain SSH because
            // SSH never replays anything.
            //
            // So the replay is followed by a reset of the state that is geometry-
            // dependent and NOT content: full-window scroll region, origin mode off,
            // autowrap on. This restores nothing about what is on screen — it only
            // stops a stale frame dictating where the next one may be drawn. A live
            // application sets its own region on its next paint; until it does, "the
            // whole window" is the safe default and "rows 1 to 24" is not.
            send(.control(.resetGeometry))
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

        // Start draining the ordered work queue. Everything that arrived while the
        // attach was in flight is already sitting in it, in arrival order, so this
        // both flushes the backlog and serves all future input through one path.
        //
        // A client may send Hello and start typing in the same breath, and on a fast
        // transport those bytes overtake the attach. Dropping them looked fine in a
        // test that happened to be slow enough and silently ate the first keystrokes
        // after every foreground.
        let drain = Task { [work] in
            for await item in work {
                switch item {
                case .write(let bytes):
                    try? await session.send(bytes)
                case .resize(let size):
                    try? await session.resize(to: size)
                }
            }
        }
        workTask.withLock { $0 = drain }
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
        case .quickActions(let actions):
            send(.control(.quickActions(actions)))
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
        workContinuation.finish()
        workTask.withLock { task in
            task?.cancel()
            task = nil
        }
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
