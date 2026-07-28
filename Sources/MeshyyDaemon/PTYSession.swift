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
    /// Agent status derived from the output stream (design doc §5, M5).
    case agent(kind: AgentEventKind, agentID: String?, detail: String?)
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
}

/// A PTY, the replay buffer behind it, and the watchers design doc §7.1 needs.
///
/// One actor per session. The PTY read loop runs on a DispatchSource and hands
/// bytes in, so nothing touches the buffer off-actor.
public actor PTYSession {
    public let name: String
    public let sessionID: String

    private let pty: PTY
    private var buffer: SessionBuffer
    private var size: TerminalSize
    private var lastTermios: TermiosState
    private var lastAltScreen = false
    private var exitStatus: Int32?

    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var termiosTimer: DispatchSourceTimer?
    private let queue: DispatchQueue

    /// Live subscribers, keyed by an opaque token so a detach can remove exactly
    /// one without disturbing the others.
    private var subscribers: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]

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
        bufferCapacity: Int = RingBuffer.defaultCapacity
    ) throws {
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
            size: size
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
            Task { await self.drain() }
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
    }

    /// Drains whatever the child wrote before exiting, then reports the exit.
    ///
    /// The drain has to come first. A child that prints and exits in the same
    /// breath has its output sitting in the tty buffer when the process source
    /// fires, and reporting the exit before reading it would lose the last thing
    /// the session ever said.
    private func childExited() {
        guard exitStatus == nil else { return }
        drain()

        let status = pty.reap() ?? 0
        exitStatus = status
        emit(.exited(status: status))

        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
        termiosTimer?.cancel()
        termiosTimer = nil
    }

    /// Reads the master until it would block, then ingests what arrived.
    ///
    /// The fd is non-blocking and the source is level-triggered, so this may be
    /// entered again before it finishes; the actor serialises those, and draining
    /// to EAGAIN each time means no wake-up is ever lost.
    private func drain() {
        var chunks: [[UInt8]] = []
        var reachedEOF = false
        while true {
            do {
                guard let chunk = try pty.read() else { reachedEOF = true; break }
                if chunk.isEmpty { break } // EAGAIN: nothing left for now
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
        for chunk in chunks {
            let offset = buffer.totalWritten
            let events = buffer.write(chunk)
            emit(.output(offset: offset, bytes: chunk))

            for event in events {
                switch event {
                case .altScreen(let active, _):
                    if active != lastAltScreen {
                        lastAltScreen = active
                        emit(.screenMode(alt: active))
                    }
                case .fullClear:
                    // Anchor bookkeeping only; nothing for a client to act on.
                    break
                }
            }
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
        resumeFrom: UInt64?
    ) -> (decision: ResumeDecision, events: AsyncStream<SessionEvent>, token: UUID) {
        let decision = buffer.resume(from: resumeFrom)
        let token = UUID()
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream(
            // Unbounded: dropping PTY output to relieve backpressure would break
            // the §6.4 invariant. A slow client must fall behind, not lose bytes.
            bufferingPolicy: .unbounded
        )
        subscribers[token] = continuation
        // Tell a new subscriber the current state immediately, so it does not
        // have to wait for the next change to know whether to predict.
        continuation.yield(.termios(lastTermios))
        continuation.yield(.screenMode(alt: lastAltScreen))
        if let exitStatus {
            continuation.yield(.exited(status: exitStatus))
        }
        return (decision, stream, token)
    }

    public func detach(_ token: UUID) {
        subscribers.removeValue(forKey: token)?.finish()
    }

    /// Forwards keystrokes to the child.
    public func send(_ bytes: [UInt8]) throws {
        guard exitStatus == nil else { return }
        try pty.write(bytes)
    }

    public func resize(to newSize: TerminalSize) throws {
        guard exitStatus == nil else { return }
        guard newSize != size else { return }
        size = newSize
        try pty.resize(to: newSize)
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
            isAlive: exitStatus == nil
        )
    }

    public var isAlive: Bool { exitStatus == nil }

    /// Ends the session: signals the child's group and finishes every stream.
    public func close() {
        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
        termiosTimer?.cancel()
        termiosTimer = nil
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
