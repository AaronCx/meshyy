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
    /// A reconnect was triggered (M4). Carries the trigger so a diagnostics screen —
    /// and a bug report — can say *why* the session dropped rather than only that it
    /// did. §3.5: fail visible.
    case reconnecting(trigger: String)
    /// Release terminal state belonging to the geometry a replay was captured at.
    ///
    /// A SEPARATE event rather than `.output`, so `.output` remains exactly the bytes
    /// the pty produced — which is what §6.4 is a statement about. Feeding these
    /// through `.output` made the byte-exactness tests red, and the right answer was
    /// not to relax the invariant but to stop pretending locally-generated escapes are
    /// remote output.
    ///
    /// A renderer applies `TerminalGeometry.reset` on receipt.
    case geometryReset
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

    /// The replay, accumulated so the restored screen reaches the emulator as ONE
    /// `.output`. Nil once flushed — which is also "not in a replay".
    ///
    /// A terminal repaints once per delivery it is handed, and a replay is by
    /// definition a screen that was already whole: there is no reason to show it being
    /// assembled. This changes only how many events the same bytes arrive in, so
    /// §6.4 byte-exactness is untouched — `outputBytes` concatenated is identical.
    ///
    /// **What ends a replay, and why it is not an end-of-replay frame.** The first
    /// non-PTY frame after `replayBase` does. The daemon always sends `termios` and
    /// `screenMode` immediately after the replay — before it starts forwarding live
    /// events — so that terminator always arrives, promptly, from every daemon version.
    /// An earlier attempt waited for a marker the daemon does not send when the replay
    /// is empty, and buffered live output forever on every fresh session; two tests
    /// caught it. A structural terminator cannot have that failure mode, and needs no
    /// protocol change: an older daemon that never sends `resetGeometry` still ends its
    /// replay with `termios`.
    private var replayPaint: [UInt8]?

    private var lastAckSent: ContinuousClock.Instant?
    private var lastAckedOffset: UInt64 = 0
    private let clock = ContinuousClock()
    private var size: TerminalSize

    // MARK: - M4 reconnect

    /// How to obtain a fresh bootstrap. Every reconnect needs one: tokens are
    /// single-use, so a stored bootstrap cannot be replayed.
    ///
    /// Supplied by the app because only the app knows how to reach the host —
    /// running `meshyyd attach --json` over its SSH channel. A library that tried to
    /// own this would have to own SSH.
    public typealias BootstrapProvider = @Sendable () async throws -> (BootstrapResponse, String)
    private var bootstrapProvider: BootstrapProvider?
    private let reconnects = ReconnectCoordinator()
    private let pathWatcher = PathWatcher()
    private var heartbeat = HeartbeatMonitor()
    private var heartbeatTask: Task<Void, Never>?
    /// False until the daemon proves it answers pings. See `startHeartbeat`.
    private var heartbeatConfirmed = false

    // MARK: - M6 quick actions

    /// Last status the daemon reported. `nil` means it has said nothing yet, which is
    /// not the same as `.idle` — one is "no agent here", the other is "we do not know".
    /// Actions are refused in both, but only one of them is worth telling a user about.
    private var agentStatus: AgentEventKind?

    /// The tier-1 palette, offered only while the agent is waiting (M6).
    ///
    /// Empty at every other moment, which is the acceptance criterion "actions are
    /// unavailable when status is not `waiting`. No stray sends." A client can bind a
    /// row of buttons straight to this and get the gating for free rather than
    /// reimplementing it, which is the whole reason it lives here and not in the app.
    public var availableQuickActions: [QuickActionDefinition] {
        agentStatus == .waiting ? QuickActionPalette.tier1 : []
    }

    /// Whether the agent is waiting on a human right now.
    public var isAwaitingInput: Bool { agentStatus == .waiting }

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

    /// Turns on automatic reconnect (M4).
    ///
    /// Opt-in rather than automatic on `attach`, because a caller that has no way to
    /// mint a fresh bootstrap cannot reconnect at all, and silently doing nothing
    /// would be worse than never having offered.
    public func enableAutomaticReconnect(bootstrap provider: @escaping BootstrapProvider) {
        bootstrapProvider = provider
        // 4a. The path callback is the trigger, not a failed write.
        pathWatcher.start { [weak self] change in
            guard let self else { return }
            Task { await self.reconnect(because: .pathChanged(change)) }
        }
    }

    /// 4c. Call from `willEnterForeground`.
    ///
    /// A `public` entry point rather than a `UIApplication` observer inside the
    /// library: MeshyyKit builds for macOS too, and a library that reaches for UIKit
    /// cannot. It also keeps the trigger explicit — the app decides what counts as
    /// coming back, which for a terminal is not always the same as the OS's idea.
    ///
    /// This is the most common reconnect in real use and it should be in flight
    /// before the user's thumb reaches the screen, so it does not wait for a
    /// keystroke or a failed probe.
    public func applicationWillEnterForeground() {
        Task { await reconnect(because: .foreground) }
    }

    /// Requests a reconnect. Every trigger funnels through here and therefore through
    /// the coordinator, which is what makes "one in flight" true rather than hoped.
    public func reconnect(because trigger: ReconnectTrigger) async {
        guard let provider = bootstrapProvider else { return }
        emit(.reconnecting(trigger: "\(trigger)"))
        await reconnects.request(trigger) { [weak self] in
            guard let self else { return }
            let (bootstrap, host) = try await provider()
            try await self.attach(bootstrap: bootstrap, sshHost: host)
        }
    }

    /// Reconnect counters, for tests and for a diagnostics screen.
    public func reconnectCounters() async -> ReconnectCoordinator.Counters {
        await reconnects.snapshot()
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
    /// - Parameter timeout: how long to wait for the QUIC connection.
    ///
    ///   Exposed because the caller knows what the wait costs. In a+Terminal this sits
    ///   between tapping a server and seeing a prompt, and a path that cannot work — a
    ///   daemon unreachable from that network — must fail fast and let SSH take over.
    ///   The 10s default spent most of a "slow to connect" complaint waiting for a
    ///   connection that was never going to arrive.
    public func attach(
        bootstrap: BootstrapResponse,
        sshHost: String,
        timeout: Duration = .seconds(10)
    ) async throws {
        connection?.close(reason: "reattaching")

        startIngress()

        let connection = MeshyyConnection(bootstrap: bootstrap, sshHost: sshHost)
        // Yield synchronously from the transport's callback: order in is order out.
        let continuation = ingressContinuation
        connection.onFrame = { envelope in continuation.yield(envelope) }
        connection.onState = { [weak self] state in
            guard let self, case .failed(let reason) = state else { return }
            Task {
                await self.emit(.failed(reason: reason))
                // `.failed` now means the transport gave up on a path that went
                // silent, not that the daemon ended the session — the two were
                // conflated until 1d-bis measured the difference. A dead path is
                // exactly what a redial fixes, so this is a trigger.
                await self.reconnect(because: .transportFailed(reason))
            }
        }
        self.connection = connection

        try await connection.connect(timeout: timeout)

        resetForAttach(resumeFrom: nil)
        startHeartbeat()
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
        // The structural end of a replay: the first frame after `replayBase` that is
        // not PTY bytes and not the geometry reset that belongs to the replay. The
        // daemon always sends `termios` here, so this always fires — including when the
        // replay was empty, which is the case the previous attempt hung on.
        switch frame {
        case .replayBase, .resetGeometry:
            break
        default:
            flushReplayPaint()
        }

        switch frame {
        case .welcome:
            // The buffered window is informational; the replay base is what the
            // arithmetic needs, and it arrives next.
            break

        case .replayBase(_, let offset):
            // Everything until the first non-PTY frame is the replay, and paints once.
            replayPaint = []
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

        case .pong(let nonce):
            heartbeat.received(nonce: nonce)
            // The first answer is the proof that this daemon speaks ping at all. Until
            // one arrives the monitor cannot declare anything dead, or a client talking
            // to an older daemon would redial every few seconds forever — the classic
            // way an additive frame stops being additive.
            heartbeatConfirmed = true

        case .resetGeometry:
            // Emitted to the renderer, and returned as NOTHING.
            //
            // `handle`'s return value means "resumed pty bytes" — it is what the §6.4
            // conformance harness compares against the daemon's buffer and what the
            // abrupt-loss accounting balances against `consumedOffset`. These bytes are
            // generated locally, not resumed, so including them in that return value
            // would fail byte-exactness (it did, immediately) and would make the offset
            // arithmetic disagree with itself.
            //
            // The emulator still gets them, because the event stream — not this return
            // value — is what production renders from.
            //
            // It does NOT get folded into the replay's `.output` to save the renderer a
            // second delivery, tempting as that is: `outputBytes` across a reattach is
            // compared against the PTY's own stream byte for byte, and 13 locally
            // generated bytes on the end fail it. That is the invariant, not a detail of
            // the test — a client whose `.output` is not exactly the daemon's stream
            // cannot resume from an offset into it. Coalescing the RESUMED bytes is
            // free; coalescing anything else is not. The renderer merges the two
            // deliveries instead, where merging costs nothing.
            flushReplayPaint()
            emit(.geometryReset)

        case .resumeTooOld:
            // Already reported through screenRebuilt when the base arrives, which
            // carries the offsets. Nothing to add here.
            break

        case .termios(let state):
            emit(.termios(state))

        case .screenMode(let alt):
            emit(.screenMode(alt: alt))

        case .agentEvent(let kind, let agentID, let detail):
            // Retained, not merely forwarded: the quick-action gate below is defined
            // against the CURRENT status, and a client that only passes the event on
            // has no way to answer "is this tap allowed right now".
            agentStatus = kind
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

    /// Probes the path once per interval, and asks for a reconnect when enough go
    /// unanswered (M4 4b).
    ///
    /// Restarted on every attach: probes sent down a connection that no longer exists
    /// can never be answered, and carrying them across would declare the fresh
    /// connection dead on arrival.
    ///
    /// **Runs whether or not this session can reconnect itself.** It used to return
    /// early without a `bootstrapProvider`, on the reasoning that there was "nothing to
    /// reconnect with" — which conflated the loop's two jobs. Detecting a dead path
    /// needs a provider. Putting TRAFFIC on the connection does not, and that is the
    /// only thing keeping a quiet session alive: `idleTimeout` is 5 seconds, so a
    /// client that never probes is dropped five seconds after the user stops typing.
    ///
    /// That is exactly what happened. The app drives its own reconnection, so it sets
    /// no provider, so it sent no probes, so every pause in typing killed the transport
    /// — surfacing as a "Reconnecting" flash every few seconds, a replayed screen each
    /// time, and a terminal that only picked up its true size after one of those
    /// reconnects. All of it read as three unrelated bugs.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeat.reset()
        heartbeatConfirmed = false

        let interval = heartbeat.interval
        heartbeatTask = Task { [weak self] in
            // The FIRST probe goes out immediately, not after one interval.
            //
            // Found by the M4 acceptance test, and it was a real hole rather than a
            // test artefact: `heartbeatConfirmed` gates the whole mechanism on having
            // seen at least one pong, so if the path died inside the first interval
            // the confirmation never arrived and the heartbeat stayed disabled for the
            // life of the session — exactly when it was needed. Probing at once closes
            // the window: a pong comes back in ~1ms even under a firehose (measured,
            // see docs/provenance.md), so confirmation is established long before any
            // realistic failure.
            // `self` is re-read from the weak capture on EVERY iteration rather than
            // bound once. Binding it once outside the loop would have the task hold the
            // session strongly for the loop's life while the session holds the task —
            // a cycle that leaks a live transport and its PTY.
            guard let first = self, await first.probeOnce() else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let session = self, await session.probeOnce() else { return }
            }
        }
    }

    /// One heartbeat tick. Returns false when the loop should stop.
    private func probeOnce() -> Bool {
        guard let connection, heartbeatTask?.isCancelled == false else { return false }

        if heartbeat.isDead, heartbeatConfirmed {
            let misses = heartbeat.missed
            heartbeat.reset()
            guard bootstrapProvider != nil else {
                // No way to redial from in here, so the caller owns recovery. Keep
                // probing rather than stopping: the probes are also what hold a healthy
                // connection open, and a session that gives up on them guarantees the
                // idle timeout it was trying to detect.
                return true
            }
            Task { await self.reconnect(because: .heartbeatLost(misses: misses)) }
            return false   // the attach that follows starts a fresh loop
        }

        let nonce = heartbeat.nextPing()
        // A send failure is itself evidence, but not conclusive: measured in 1d-bis,
        // sends keep succeeding long after the path is dead. The pong is the evidence.
        try? connection.send(.ping(nonce: nonce.value))
        return true
    }

    /// Resets the protocol state for a new attach.
    ///
    /// Called by `attach` and by the conformance harness, so the harness exercises
    /// the same reset the shipping path does rather than a test-only imitation.
    func resetForAttach(resumeFrom: UInt64?) {
        // The agent may have finished while the client was away, so a status from
        // before the disconnect is a guess. Clearing it means the palette is hidden
        // until the daemon says otherwise, which is the safe direction: a missing
        // button costs a keyboard tap, a stale one sends a keystroke into a running
        // agent.
        agentStatus = nil
        baseEstablished = false
        pendingOutput.removeAll()
        // A replay interrupted by a drop has already been COUNTED into consumedOffset,
        // so the next attach will resume past it. Paint it before letting go of it, or
        // those bytes are lost silently — the exact failure mode §6.4 exists to prevent.
        flushReplayPaint()
        if let resumeFrom { consumedOffset = resumeFrom }
    }

    private func deliver(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        // Counted and acked exactly as before whether or not it paints now: these ARE
        // resumed bytes, and the offset arithmetic must not depend on when they reach
        // the screen.
        consumedOffset += UInt64(bytes.count)
        if replayPaint != nil {
            replayPaint?.append(contentsOf: bytes)
        } else {
            emit(.output(bytes))
        }
        maybeAck()
    }

    /// Hands the accumulated replay to the emulator as a single delivery, and leaves
    /// replay mode. Safe to call when there is no replay in progress.
    private func flushReplayPaint() {
        guard let paint = replayPaint else { return }
        replayPaint = nil
        guard !paint.isEmpty else { return }
        emit(.output(paint))
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
        // Same gate as the tier-1 path. A profile-declared action is no less a
        // one-tap send into a live PTY.
        guard agentStatus == .waiting else {
            throw QuickActionError.notAwaitingInput(status: agentStatus?.rawValue ?? "unknown")
        }
        try send(definition.sends)
    }

    public enum QuickActionError: Error, Equatable, CustomStringConvertible {
        case unknownAction(id: String)
        /// The agent is not waiting, so nothing may be sent on its behalf.
        case notAwaitingInput(status: String)

        public var description: String {
            switch self {
            case .unknownAction(let id):
                "meshyy: no local definition for quick action \(id.debugDescription). "
                    + "Actions are resolved from local profiles, never from the wire, "
                    + "so an id this client does not know is refused rather than guessed."
            case .notAwaitingInput(let status):
                "meshyy: refused a quick action while the agent is \(status). A one-tap "
                    + "send is only ever an answer to a question that was asked; firing "
                    + "one at a working agent injects a keystroke into whatever it is "
                    + "doing."
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

    /// Performs one of the fixed tier-1 actions (M6).
    ///
    /// Gated on the agent actually waiting. The gate is here rather than in the UI
    /// because "the button was hidden" is not a guarantee: a stale view, a queued tap
    /// delivered after the status moved, or a keyboard shortcut all reach this method
    /// with the button gone from the screen. A tap that arrives late must fail, not
    /// land in the middle of whatever the agent went on to do.
    public func performTier1Action(id: String) throws {
        guard let definition = QuickActionPalette.tier1.first(where: { $0.id == id }) else {
            throw QuickActionError.unknownAction(id: id)
        }
        guard agentStatus == .waiting else {
            throw QuickActionError.notAwaitingInput(status: agentStatus?.rawValue ?? "unknown")
        }
        try send(definition.sends)
    }

    public func detach(reason: String = "client detached") {
        flushAck()
        connection?.close(reason: reason)
        connection = nil
        continuation.yield(.ended(reason: reason))
    }

    /// Ends the session for good and stops the ingress consumer.
    public func shutdown(reason: String = "client shut down") {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pathWatcher.stop()
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
