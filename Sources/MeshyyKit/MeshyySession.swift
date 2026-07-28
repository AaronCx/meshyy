// meshyy — the client-facing session (design doc §6.2, M3). What a+Terminal uses.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Owns the one piece of state that makes resume work: how many bytes this client
// has actually consumed. The daemon cannot know that — only the client does — so
// design doc §6.2 has the client acknowledge an offset and resume from it.
//
// Everything here is deliberately about bookkeeping, not rendering. The byte
// stream comes out of `events` and goes straight into SwiftTerm; §3.2 is emphatic
// that meshyy syncs bytes and runs no terminal emulator of its own.

import Foundation
import MeshyyCore

/// What a session tells its owner.
public enum MeshyySessionEvent: Sendable {
    /// PTY bytes, in order, to feed the emulator verbatim.
    case output([UInt8])
    /// The screen was rebuilt rather than continued: bytes were lost and the
    /// client should clear before applying what follows. Design doc §3.5 — this is
    /// surfaced rather than swallowed, because a spliced hole shows up as corrupt
    /// scrollback that nobody can explain later.
    case screenRebuilt(skippedFrom: UInt64, resumedAt: UInt64)
    /// Line discipline changed (design doc §7.1). Retained because §7's rewrite
    /// keeps the fact useful even though prediction is gone: a UI can explain why
    /// nothing echoes locally.
    case termios(TermiosState)
    case screenMode(alt: Bool)
    case agent(kind: AgentEventKind, agentID: String?, detail: String?)
    /// One-tap actions currently answerable (design doc §7.3). Empty withdraws.
    case quickActions([QuickAction])
    case ended(reason: String)
    /// Something went wrong that the user should see.
    case failed(reason: String)
}

/// One meshyy session: a connection, an offset, and the resume logic between them.
public actor MeshyySession {
    /// Design doc §6.2: "Client sends Ack {offset} periodically, at most every
    /// 250ms." Acking every chunk would put a control frame behind every keystroke
    /// echo for no benefit — the daemon only needs a recent floor, not an exact one.
    public static let ackInterval = Duration.milliseconds(250)

    private var connection: MeshyyConnection?
    private let continuation: AsyncStream<MeshyySessionEvent>.Continuation
    public let events: AsyncStream<MeshyySessionEvent>

    /// Frames enter here, in arrival order, and one task drains them.
    ///
    /// The obvious spelling — `onFrame = { Task { await self.handle($0) } }` — is
    /// WRONG, and subtly so. Tasks enqueued on an actor run in an unspecified
    /// order, not FIFO, so PTY chunks could be delivered to the emulator out of
    /// order: a silent violation of the §6.4 invariant that no test of the daemon
    /// would ever catch, because the daemon did everything right.
    ///
    /// An AsyncStream preserves yield order and has exactly one consumer, so
    /// arrival order is delivery order by construction.
    private let ingress: AsyncStream<FrameEnvelope>
    private let ingressContinuation: AsyncStream<FrameEnvelope>.Continuation
    private var ingressTask: Task<Void, Never>?

    /// Absolute offset one past the last byte handed to the emulator. This is what
    /// a reconnect resumes from, and the only durable state a client needs.
    public private(set) var consumedOffset: UInt64 = 0
    /// True once the daemon has stated a replay base for the current attach. Until
    /// then arriving PTY bytes cannot be counted, because their offset is unknown.
    private var baseEstablished = false
    private var pendingOutput: [[UInt8]] = []

    private var lastAckSent: ContinuousClock.Instant?
    private var lastAckedOffset: UInt64 = 0
    private let clock = ContinuousClock()
    private var size: TerminalSize

    public init(size: TerminalSize = .default) {
        self.size = size
        let (stream, continuation) = AsyncStream<MeshyySessionEvent>.makeStream(
            // Unbounded: dropping PTY output to relieve backpressure would break the
            // §6.4 invariant. A slow consumer must fall behind, never lose bytes.
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.continuation = continuation

        let (frames, frameContinuation) = AsyncStream<FrameEnvelope>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.ingress = frames
        self.ingressContinuation = frameContinuation
    }

    /// Starts the single ordered consumer. Idempotent.
    private func startIngress() {
        guard ingressTask == nil else { return }
        ingressTask = Task { [weak self] in
            guard let self else { return }
            for await frame in self.ingress {
                await self.handle(frame)
            }
        }
    }

    // MARK: - Attach

    /// Connects and attaches, resuming from `consumedOffset` if this session has
    /// seen bytes before.
    ///
    /// Call this again after a suspension with a fresh bootstrap: the SSH channel
    /// is cheap and the token is single-use, so every reconnect gets a new one.
    public func attach(bootstrap: BootstrapResponse, sshHost: String) async throws {
        connection?.close(reason: "reattaching")

        startIngress()

        let connection = MeshyyConnection(bootstrap: bootstrap, sshHost: sshHost)
        // Yield synchronously from the transport's callback: order in is order out.
        let continuation = ingressContinuation
        connection.onFrame = { envelope in continuation.yield(envelope) }
        connection.onState = { [weak self] state in
            guard let self, case .failed(let reason) = state else { return }
            Task { await self.emit(.failed(reason: reason)) }
        }
        self.connection = connection

        try await connection.connect()

        resetForAttach(resumeFrom: nil)
        try connection.send(.hello(.init(
            token: bootstrap.token,
            cols: size.cols,
            rows: size.rows,
            // Only resume if this client has actually consumed something. A first
            // attach must be `fresh` so the daemon shows the current screen rather
            // than replaying from offset zero, which after a wrap does not exist.
            resumeFrom: consumedOffset > 0 ? consumedOffset : nil
        )))
    }

    // MARK: - Inbound

    /// Handles one inbound frame and returns the bytes it caused to be delivered.
    ///
    /// `internal` rather than `private`, and returning what it delivered, so the
    /// conformance harness can drive the **shipping** client with the exact frames a
    /// daemon would send and compare it byte for byte against the reference
    /// `ClientModel`. Without that seam the only way to observe delivery is the event
    /// stream, whose timing depends on another task being scheduled — which is how a
    /// previous attempt at this turned into a flaky test measuring its own scheduler.
    ///
    /// The production path ignores the return value; `events` remains the real
    /// interface.
    @discardableResult
    func handle(_ envelope: FrameEnvelope) -> [UInt8] {
        switch envelope.kind {
        case .pty:
            // Bytes cannot be counted before the base is known, and they must not be
            // dropped either — so they queue until `replayBase` arrives. In practice
            // the base comes first; queueing exists so an out-of-order delivery
            // costs latency rather than correctness.
            guard baseEstablished else {
                pendingOutput.append(envelope.payload)
                return []
            }
            deliver(envelope.payload)
            return envelope.payload

        case .control:
            guard let frame = try? ControlFrame.decode(envelope.payload) else { return [] }
            return handle(frame)

        case .blob:
            return []
        }
    }

    @discardableResult
    private func handle(_ frame: ControlFrame) -> [UInt8] {
        switch frame {
        case .welcome:
            // The buffered window is informational; the replay base is what the
            // arithmetic needs, and it arrives next.
            break

        case .replayBase(_, let offset):
            var flushed: [UInt8] = []
            if offset != consumedOffset, consumedOffset > 0 {
                // The daemon rewound or skipped. `resumeTooOld` (below) explains
                // why; this is where the offset is corrected so subsequent acks are
                // right rather than drifting by the difference.
                emit(.screenRebuilt(skippedFrom: consumedOffset, resumedAt: offset))
            }
            consumedOffset = offset
            lastAckedOffset = offset
            baseEstablished = true
            let queued = pendingOutput
            pendingOutput.removeAll()
            for chunk in queued {
                deliver(chunk)
                flushed += chunk
            }
            return flushed

        case .resumeTooOld:
            // Already reported through screenRebuilt when the base arrives, which
            // carries the offsets. Nothing to add here.
            break

        case .termios(let state):
            emit(.termios(state))

        case .screenMode(let alt):
            emit(.screenMode(alt: alt))

        case .agentEvent(let kind, let agentID, let detail):
            emit(.agent(kind: kind, agentID: agentID, detail: detail))

        case .quickActions(let actions):
            emit(.quickActions(actions))

        case .bye(let reason):
            emit(.ended(reason: reason))
            connection?.close(reason: reason)
            connection = nil

        case .error(_, let message):
            emit(.failed(reason: message))

        default:
            break
        }
        return []
    }

    /// Resets the protocol state for a new attach.
    ///
    /// Called by `attach` and by the conformance harness, so the harness exercises
    /// the same reset the shipping path does rather than a test-only imitation.
    func resetForAttach(resumeFrom: UInt64?) {
        baseEstablished = false
        pendingOutput.removeAll()
        if let resumeFrom { consumedOffset = resumeFrom }
    }

    private func deliver(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        consumedOffset += UInt64(bytes.count)
        emit(.output(bytes))
        maybeAck()
    }

    /// Acks at most every 250ms, and only when the offset has moved.
    private func maybeAck() {
        guard consumedOffset > lastAckedOffset else { return }
        let now = clock.now
        if let last = lastAckSent, now - last < Self.ackInterval { return }
        lastAckSent = now
        lastAckedOffset = consumedOffset
        try? connection?.send(.ack(ptyID: 0, offset: consumedOffset))
    }

    /// Sends any outstanding ack immediately.
    ///
    /// Call this when the app is about to be backgrounded: the throttle means up to
    /// 250ms of consumed output may be unacknowledged, and iOS is about to kill the
    /// socket. The daemon uses its own record only for diagnostics — the client's
    /// `consumedOffset` is what actually drives the resume — but a daemon whose
    /// view is stale reports a misleading buffered window.
    public func flushAck() {
        guard consumedOffset > lastAckedOffset else { return }
        lastAckSent = clock.now
        lastAckedOffset = consumedOffset
        try? connection?.send(.ack(ptyID: 0, offset: consumedOffset))
    }

    // MARK: - Outbound

    public func send(_ bytes: [UInt8]) throws {
        guard let connection else { throw MeshyyConnection.ConnectionError.notConnected }
        try connection.sendKeystrokes(bytes)
    }

    public func resize(to newSize: TerminalSize) throws {
        size = newSize
        try connection?.send(.resize(cols: newSize.cols, rows: newSize.rows))
    }

    /// Performs an offered quick action, resolving its keystrokes **locally**
    /// (design doc §7.3).
    ///
    /// This overload exists so the security property is structural rather than
    /// documentary. The daemon advertises an id and a label; the bytes come from
    /// `profiles`, which is the caller's own data. A remote that forges a
    /// `QuickActions` frame — or draws a convincing fake permission prompt to
    /// provoke a real one — still cannot choose what a tap sends, because the id it
    /// names either matches a local definition or nothing happens.
    ///
    /// Throws `unknownAction` rather than sending anything on a miss. Silently
    /// doing nothing would leave a user tapping a dead button; sending a guess
    /// would be the hole this design closes.
    public func performQuickAction(
        id: String,
        from profiles: [AgentProfile]
    ) throws {
        let definitions = profiles.flatMap(\.quickActions)
        guard let definition = definitions.first(where: { $0.id == id }) else {
            throw QuickActionError.unknownAction(id: id)
        }
        try send(definition.sends)
    }

    public enum QuickActionError: Error, Equatable, CustomStringConvertible {
        case unknownAction(id: String)

        public var description: String {
            switch self {
            case .unknownAction(let id):
                "meshyy: no local definition for quick action \(id.debugDescription). "
                    + "Actions are resolved from local profiles, never from the wire, "
                    + "so an id this client does not know is refused rather than guessed."
            }
        }
    }

    /// Sends raw keystrokes for an action the caller has already resolved.
    ///
    /// Prefer `performQuickAction(id:from:)`, which does the resolution and cannot
    /// be handed bytes that came off the wire.
    public func performQuickAction(sending bytes: [UInt8]) throws {
        try send(bytes)
    }

    public func detach(reason: String = "client detached") {
        flushAck()
        connection?.close(reason: reason)
        connection = nil
        continuation.yield(.ended(reason: reason))
    }

    /// Ends the session for good and stops the ingress consumer.
    public func shutdown(reason: String = "client shut down") {
        detach(reason: reason)
        ingressContinuation.finish()
        ingressTask?.cancel()
        ingressTask = nil
        continuation.finish()
    }

    private func emit(_ event: MeshyySessionEvent) {
        continuation.yield(event)
    }
}
