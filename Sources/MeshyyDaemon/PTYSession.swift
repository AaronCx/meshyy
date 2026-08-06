// meshyy — one live session: a PTY, its replay buffer, and its watchers.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.

import Darwin
import Foundation
import MeshyyCore

/// Everything a subscriber learns about a session.
public enum SessionEvent: Sendable, Equatable {
    /// PTY output, with the absolute offset of its first byte so a client can
    /// track what to acknowledge (design doc §6.2).
    case output(offset: UInt64, bytes: [UInt8])
    /// The line discipline changed (design doc §7.1). Prediction must be
    /// re-evaluated and outstanding predictions killed.
    case termios(TermiosState)
    /// An alternate-screen application started or stopped.
    case screenMode(alt: Bool)
    /// The set of tracked DEC private modes changed (mouse, focus, paste,
    /// cursor keys — ScreenScanner.trackedModes). Carries the whole current
    /// set: idempotent to apply, impossible to mis-order.
    case modes(active: Set<Int>)
    /// Agent status derived from the output stream (design doc §5, M5).
    case agent(kind: AgentEventKind, agentID: String?, detail: String?)
    /// One-tap actions now answerable, or an empty list withdrawing a previous
    /// offer (design doc §7.3). Only ids and labels travel; what a tap sends comes
    /// from the client's own profile.
    case quickActions([QuickAction])
    /// The child exited. The session is over; the buffer stays readable until
    /// the session is closed so a late client can still see the last output.
    case exited(status: Int32)
}

/// A session's identity and current state, for `meshyyd list`.
public struct SessionInfo: Sendable, Equatable {
    public var name: String
    public var sessionID: String
    public var size: TerminalSize
    public var bufferedFrom: UInt64
    public var bufferedTo: UInt64
    public var altScreen: Bool
    public var termios: TermiosState
    public var childPID: pid_t
    public var isAlive: Bool
    /// Clients currently attached — the count a "detached session" claim rests on.
    /// Observers (the daemon's own notification watcher) are excluded: they hold a
    /// subscription on EVERY session for its whole life, so counting them would make
    /// "detached" a state no session could ever be in.
    public var attachedClients: Int
    public var createdAt: Date
    /// Seconds since the most recently active client was last heard from, or nil
    /// when nobody is attached. A client that has said nothing for longer than it
    /// could plausibly go quiet — the client heartbeat is 1s — is a corpse the
    /// transport has not reaped yet, not a live screen.
    public var clientQuietFor: TimeInterval?
    /// When the PTY last produced output. Nil for a session that has said nothing.
    public var lastOutputAt: Date?
}

/// A PTY, the replay buffer behind it, and the watchers design doc §7.1 needs.
///
/// One actor per session. The PTY read loop runs on a DispatchSource and hands
/// bytes in, so nothing touches the buffer off-actor.
public actor PTYSession {
    // Immutable identity, readable without a hop — callers compare and log these
    // constantly and an `await` per read is isolation theatre for a `let`.
    public nonisolated let name: String
    public nonisolated let sessionID: String

    private let pty: PTY
    private var buffer: SessionBuffer
    private var size: TerminalSize
    private var lastTermios: TermiosState
    private var lastAltScreen = false
    private var exitStatus: Int32?
    /// Reentrancy guard for `childExited` — see the note there.
    private var exiting = false

    /// Derives agent status and quick-action availability from the output stream.
    /// Never inspects commands, and never names an agent itself — identity is data
    /// supplied as profiles (design doc §4).
    private var agentMonitor: AgentActivityMonitor
    /// Fires while output is quiet, which is how "waiting" is detected.
    private var agentTimer: DispatchSourceTimer?
    private let clock = ContinuousClock()
    /// What the agent monitor last reported, so a frame is only sent on a change.
    private var lastAgentStatus: AgentActivityMonitor.Status = .none

    private var readSource: DispatchSourceRead?
    /// Fires when the PTY will accept more input, draining `pendingWrite`.
    private var writeSource: DispatchSourceWrite?
    /// Input the PTY has not accepted yet.
    ///
    /// A PTY's input buffer is a few KiB, so anything larger than that — a paste, a
    /// here-doc — cannot be handed over in one call. It must be queued rather than
    /// waited on: waiting would block this actor, which also runs the read loop that
    /// drains the child's output, so the child would block on stdout and stop
    /// reading stdin. See `PTY.writeSome`.
    private var pendingWrite: [UInt8] = []
    private var exitSource: DispatchSourceProcess?
    private var termiosTimer: DispatchSourceTimer?
    private let queue: DispatchQueue

    /// Live subscribers, keyed by an opaque token so a detach can remove exactly
    /// one without disturbing the others.
    private var subscribers: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]
    /// The subset of `subscribers` that are clients rather than observers — what
    /// `SessionInfo.attachedClients` reports.
    /// Client subscriptions and when each was last heard from. A COUNT alone is
    /// not enough to answer "is anyone actually there": a force-quit phone's QUIC
    /// peer lingers on the daemon until the idle timeout, still counted, so a
    /// session that is in truth abandoned reads as someone's live screen and is
    /// never offered back. The timestamp is what tells the two apart.
    private var clientTokens: [UUID: Date] = [:]
    private let createdAt = Date()
    private var lastOutputAt: Date?

    /// Design doc §7.1: poll termios at 50ms while a prediction is outstanding,
    /// 500ms otherwise. The daemon does not know about outstanding predictions,
    /// so it polls at the slow rate and switches to fast when a client says it is
    /// predicting.
    private static let slowTermiosPoll = Duration.milliseconds(500)
    private static let fastTermiosPoll = Duration.milliseconds(50)
    private var termiosPollInterval = PTYSession.slowTermiosPoll

    public init(
        name: String,
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String? = nil,
        size: TerminalSize = .default,
        bufferCapacity: Int = RingBuffer.defaultCapacity,
        agentProfiles: [AgentProfile] = [],
        rawMode: Bool = false
    ) throws {
        self.agentMonitor = AgentActivityMonitor(candidates: agentProfiles)
        self.name = name
        self.sessionID = Self.makeSessionID()
        self.size = size
        self.buffer = SessionBuffer(capacity: bufferCapacity)
        self.queue = DispatchQueue(label: "meshyy.session.\(name)")
        self.pty = try PTY(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            size: size,
            rawMode: rawMode
        )
        self.lastTermios = pty.termios() ?? .cooked
    }

    /// 128-bit random, per design doc §8. A stolen session id alone is useless —
    /// resume also needs a fresh SSH-issued token — but it must still not be
    /// guessable.
    private static func makeSessionID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytesShim(&bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Starts the read loop and the termios watcher. Separate from `init` so the
    /// actor is fully formed before any callback can reach it.
    public func start() {
        guard readSource == nil else { return }

        // The DispatchSource fires on `queue`, which is outside the actor, so the
        // handler does nothing but hop in. Draining the fd out here would be one
        // fewer await but would touch actor-isolated state from a nonisolated
        // context — the sort of thing that compiles under -swift-version 5 and is
        // a data race either way.
        let source = DispatchSource.makeReadSource(fileDescriptor: pty.masterFD, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Suspend before hopping to the actor, resume after the drain.
            //
            // Without this the source is level-triggered against a fd that is
            // almost always readable, so it fires continuously and enqueues an
            // unbounded pile of drain tasks on the actor. Every other actor call —
            // `send`, `resize`, `attach`, `info` — then starves behind them, and a
            // session with a busy producer becomes unresponsive rather than merely
            // busy. Measured with `yes` as the child: 47 s at 251% CPU and no
            // progress. Bounding bytes per drain was not enough on its own; the
            // queue depth is the thing that has to be bounded.
            source.suspend()
            Task {
                await self.drain()
                source.resume()
            }
        }
        source.resume()
        readSource = source

        // Child exit arrives from a process source, not from end of file on the
        // master: the daemon holds a slave descriptor so that a short-lived
        // child's output is not discarded (see PTY.slaveFD), which means EOF never
        // comes. waitpid is the better signal regardless — it carries the status.
        let exits = DispatchSource.makeProcessSource(
            identifier: pty.childPID,
            eventMask: .exit,
            queue: queue
        )
        exits.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.childExited() }
        }
        exits.resume()
        exitSource = exits

        scheduleTermiosPoll()
        scheduleAgentTick()
    }

    /// The quiet detector. Design doc's heuristic needs a clock that keeps running
    /// when the PTY has gone silent, because silence is the signal.
    private func scheduleAgentTick() {
        agentTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.tickAgent() }
        }
        timer.resume()
        agentTimer = timer
    }

    private func tickAgent() {
        applyAgentChanges(agentMonitor.tick(now: clock.now))
    }

    private func applyAgentChanges(_ changes: AgentActivityMonitor.Changes) {
        guard !changes.isEmpty else { return }

        if let status = changes.status, status != lastAgentStatus {
            lastAgentStatus = status
            let kind: AgentEventKind? = switch status {
            case .working: .working
            case .waiting: .waiting
            case .none: .idle
            }
            if let kind {
                emit(.agent(
                    kind: kind,
                    agentID: agentMonitor.detected?.id,
                    detail: agentMonitor.detected?.displayName
                ))
            }
        } else if changes.detected != nil, lastAgentStatus != .none {
            // The name resolved without the status moving — "Agent" became
            // "Claude Code". Worth re-emitting so a label updates.
            let kind: AgentEventKind = lastAgentStatus == .working ? .working : .waiting
            emit(.agent(
                kind: kind,
                agentID: agentMonitor.detected?.id,
                detail: agentMonitor.detected?.displayName
            ))
        }

        if let actions = changes.actions {
            emit(.quickActions(actions.map(\.advertised)))
        }
    }

    /// Drains whatever the child wrote before exiting, then reports the exit.
    ///
    /// The drain has to come first. A child that prints and exits in the same
    /// breath has its output sitting in the tty buffer when the process source
    /// fires, and reporting the exit before reading it would lose the last thing
    /// the session ever said.
    private func childExited() {
        // `exitStatus` is set below, AFTER the final drain — so it cannot guard this
        // path against itself: the drain ingests, the ingest sees EOF with
        // `exitStatus` still nil, and calls back in here. That recursion ran until
        // the stack died (SIGBUS, `drain → childExited → ingest → drain …`), taking
        // the whole daemon with it — every session, not just the exiting one. A
        // separate flag, set before the drain, is what actually closes the cycle.
        guard !exiting, exitStatus == nil else { return }
        exiting = true
        drain()

        let status = pty.reap() ?? 0
        exitStatus = status
        emit(.exited(status: status))

        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        exitSource?.cancel()
        exitSource = nil
        termiosTimer?.cancel()
        termiosTimer = nil
        agentTimer?.cancel()
        agentTimer = nil
    }

    /// Most bytes read in one pass before yielding the actor.
    ///
    /// **Bounded on purpose.** Draining "until EAGAIN" assumes the producer pauses.
    /// An unbounded one — `yes`, a runaway build, `cat /dev/urandom` — never does, so
    /// the loop never exits and this actor never returns: input, resizes, attaches and
    /// exit handling all starve behind it. The read source is level-triggered, so
    /// returning early costs nothing; it fires again immediately and other actor work
    /// gets a turn in between.
    ///
    /// Found by the 1d firehose test, which hung until this cap existed.
    private static let maximumBytesPerDrain = 1 << 20  // 1 MiB

    /// Reads what is available, up to `maximumBytesPerDrain`, then ingests it.
    private func drain() {
        var chunks: [[UInt8]] = []
        var total = 0
        var reachedEOF = false
        while total < Self.maximumBytesPerDrain {
            do {
                guard let chunk = try pty.read() else { reachedEOF = true; break }
                if chunk.isEmpty { break } // EAGAIN: nothing left for now
                total += chunk.count
                chunks.append(chunk)
            } catch {
                reachedEOF = true
                break
            }
        }
        ingest(chunks: chunks, reachedEOF: reachedEOF)
    }

    private func scheduleTermiosPoll() {
        termiosTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + termiosPollInterval.timeInterval,
            repeating: termiosPollInterval.timeInterval
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.pollTermios() }
        }
        timer.resume()
        termiosTimer = timer
    }

    private func pollTermios() {
        observeTermios(pty.termios())
    }

    /// A client that is predicting asks for the fast poll, so a mode change
    /// invalidates its predictions within 50ms rather than 500 (design doc §7.1).
    public func setPredicting(_ predicting: Bool) {
        let wanted = predicting ? Self.fastTermiosPoll : Self.slowTermiosPoll
        guard wanted != termiosPollInterval else { return }
        termiosPollInterval = wanted
        scheduleTermiosPoll()
    }

    // MARK: - Ingest

    private func ingest(chunks: [[UInt8]], reachedEOF: Bool) {
        if !chunks.isEmpty { lastOutputAt = Date() }
        var modesChanged = false
        for chunk in chunks {
            let offset = buffer.totalWritten
            let events = buffer.write(chunk)
            emit(.output(offset: offset, bytes: chunk))

            applyAgentChanges(agentMonitor.observe(chunk, now: clock.now))

            for event in events {
                switch event {
                case .altScreen(let active, _):
                    if active != lastAltScreen {
                        lastAltScreen = active
                        emit(.screenMode(alt: active))
                    }
                    // Design doc §7.3: withdraw any offer on an alt-screen
                    // transition. The text a match was based on is gone.
                    applyAgentChanges(agentMonitor.screenChanged())
                case .fullClear:
                    // The anchor is buffer bookkeeping, but a clear also means the
                    // matched prompt has left the screen.
                    applyAgentChanges(agentMonitor.screenChanged())
                case .mode:
                    // Coalesced below: one event per chunk however many modes
                    // a combined sequence flipped.
                    modesChanged = true
                }
            }
        }

        if modesChanged {
            emit(.modes(active: buffer.activeModes))
        }

        // EOF on the master should be unreachable while the daemon holds a slave
        // descriptor, so if it happens the PTY has been torn down under us. Treat
        // it as exit rather than looping on a dead fd.
        if reachedEOF, exitStatus == nil {
            childExited()
        }
    }

    private func observeTermios(_ observed: TermiosState?) {
        guard let observed, observed != lastTermios else { return }
        lastTermios = observed
        emit(.termios(observed))
    }

    private func emit(_ event: SessionEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    // MARK: - Client-facing

    /// Attaches a subscriber.
    ///
    /// Returns the resume decision for `resumeFrom` **and** a stream of
    /// everything after it. The two are returned together so there is no window
    /// between "what do I replay" and "start sending me live output" in which
    /// bytes could be lost — which is exactly how a resume protocol grows a gap.
    public func attach(
        resumeFrom: UInt64?,
        observer: Bool = false
    ) -> (decision: ResumeDecision, events: AsyncStream<SessionEvent>, token: UUID) {
        let decision = buffer.resume(from: resumeFrom)
        let token = UUID()
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream(
            // Unbounded: dropping PTY output to relieve backpressure would break
            // the §6.4 invariant. A slow client must fall behind, not lose bytes.
            bufferingPolicy: .unbounded
        )
        subscribers[token] = continuation
        if !observer { clientTokens[token] = Date() }
        // Tell a new subscriber the current state immediately, so it does not
        // have to wait for the next change to know whether to predict.
        continuation.yield(.termios(lastTermios))
        continuation.yield(.screenMode(alt: lastAltScreen))
        continuation.yield(.modes(active: buffer.activeModes))
        continuation.yield(.quickActions(agentMonitor.offeredActions.map(\.advertised)))
        if let exitStatus {
            continuation.yield(.exited(status: exitStatus))
        }
        return (decision, stream, token)
    }

    /// Records that a client was heard from. Every inbound frame counts —
    /// including pings, which are the only traffic a watching client produces.
    public func noteClientActivity(_ token: UUID) {
        guard clientTokens[token] != nil else { return }
        clientTokens[token] = Date()
    }

    public func detach(_ token: UUID) {
        subscribers.removeValue(forKey: token)?.finish()
        clientTokens.removeValue(forKey: token)
    }

    /// Forwards keystrokes to the child. Returns immediately, always.
    ///
    /// Whatever the PTY will not take right now is queued and flushed from a write
    /// source. Never blocks: this actor also drains the child's output, and blocking
    /// here deadlocks the session. See `PTY.writeSome`.
    public func send(_ bytes: [UInt8]) throws {
        guard exitStatus == nil, !bytes.isEmpty else { return }

        if pendingWrite.isEmpty {
            let accepted = try pty.writeSome(bytes)
            if accepted == bytes.count { return }
            pendingWrite = Array(bytes.dropFirst(accepted))
        } else {
            // Append rather than attempt: writing now would reorder this chunk ahead
            // of what is already queued.
            pendingWrite += bytes
        }
        scheduleWriteFlush()
    }

    /// Arms the write source, if it is not already armed.
    private func scheduleWriteFlush() {
        guard writeSource == nil, !pendingWrite.isEmpty else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: pty.masterFD, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.flushPendingWrite() }
        }
        source.resume()
        writeSource = source
    }

    private func flushPendingWrite() {
        guard !pendingWrite.isEmpty else {
            // Disarm: a level-triggered write source on a writable fd fires
            // continuously and would spin a core for nothing.
            writeSource?.cancel()
            writeSource = nil
            return
        }
        do {
            let accepted = try pty.writeSome(pendingWrite)
            if accepted > 0 { pendingWrite.removeFirst(accepted) }
        } catch {
            // The PTY is gone; there is nobody left to write to.
            pendingWrite = []
        }
        if pendingWrite.isEmpty {
            writeSource?.cancel()
            writeSource = nil
        }
    }

    /// Bytes accepted from clients but not yet handed to the PTY. Exposed so a
    /// backpressure test can assert the queue drains rather than grows without bound.
    public var pendingWriteCount: Int { pendingWrite.count }

    /// Applies a client's size and makes the foreground program re-read it — even
    /// when nothing changed.
    ///
    /// This used to early-return on an unchanged size, which was right when the
    /// transport flapped every few seconds: any program that missed a SIGWINCH was
    /// repaired moments later by the next attach's resync. The premise died when
    /// the heartbeat fix made sessions long-lived — measured on a real one: a tmux
    /// client that missed a single WINCH stayed at 74x39 against a 74x64 PTY for a
    /// DAY, because the session never reattached and every resize the phone sent
    /// matched the size already recorded, so nothing was ever signalled. A resize
    /// frame is a rare, user-caused event; answering it with one explicit signal
    /// (see `PTY.resyncSize` — exactly one, whichever side produces it) turns every
    /// keyboard show/dismiss into a repair opportunity instead of a no-op.
    public func resize(to newSize: TerminalSize) throws {
        guard exitStatus == nil else { return }
        size = newSize
        try pty.resyncSize(to: newSize)
    }

    /// The attach-time spelling of the same repair (design doc §4.1): kept as its
    /// own entry point because an attach must resync UNCONDITIONALLY, and the
    /// shared mechanics live in `PTY.resyncSize`.
    public func resyncSize(to newSize: TerminalSize) throws {
        guard exitStatus == nil else { return }
        size = newSize
        try pty.resyncSize(to: newSize)
    }

    public var info: SessionInfo {
        let window = buffer.window
        return SessionInfo(
            name: name,
            sessionID: sessionID,
            size: size,
            bufferedFrom: window.from,
            bufferedTo: window.to,
            altScreen: lastAltScreen,
            termios: lastTermios,
            childPID: pty.childPID,
            isAlive: exitStatus == nil,
            attachedClients: clientTokens.count,
            createdAt: createdAt,
            clientQuietFor: clientTokens.values.map { Date().timeIntervalSince($0) }.min(),
            lastOutputAt: lastOutputAt
        )
    }

    public var isAlive: Bool { exitStatus == nil }

    /// Ends the session: signals the child's group and finishes every stream.
    public func close() {
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        pendingWrite = []
        exitSource?.cancel()
        exitSource = nil
        termiosTimer?.cancel()
        termiosTimer = nil
        agentTimer?.cancel()
        agentTimer = nil
        pty.terminate()
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
        if exitStatus == nil { exitStatus = SIGHUP }
    }
}

/// `SecRandomCopyBytes` lives in Security, which the daemon links anyway for the
/// TLS identity. Wrapped so the session id generator does not import Security
/// just for one call and so a Linux port (design doc §12.6) has one place to change.
private func SecRandomCopyBytesShim(_ bytes: inout [UInt8]) -> Int32 {
    var generator = SystemRandomNumberGenerator()
    for index in bytes.indices {
        bytes[index] = UInt8.random(in: 0...255, using: &generator)
    }
    return 0
}
