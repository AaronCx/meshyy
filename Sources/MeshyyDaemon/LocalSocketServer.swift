// meshyy — the daemon's local control plane (design doc §10, M1).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// A unix socket speaking the same framing and the same control frames the QUIC
// transport will. That is deliberate: it makes design doc §3.3 ("transport is
// replaceable") true from M1 instead of a claim to be retrofitted, and it means
// the session logic is exercised end to end before any network code exists.
//
// Authentication is filesystem permissions. The socket is 0600 in a 0700
// directory, so opening it already proves the caller is this user. There is no
// token here — §5.1's token exists to bind a QUIC connection to a session across
// an *unauthenticated* path, and inventing a local one would be theatre.

import Darwin
import Foundation
import MeshyyCore

public final class LocalSocketServer: @unchecked Sendable {
    public enum ServerError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case socketFailed(errno: Int32)
        case bindFailed(path: String, errno: Int32)
        case listenFailed(errno: Int32)
        case alreadyRunning(path: String)

        public var description: String {
            switch self {
            case .pathTooLong(let path):
                "meshyyd: socket path is too long for sockaddr_un: \(path)"
            case .socketFailed(let code):
                "meshyyd: socket() failed: \(String(cString: strerror(code)))"
            case .bindFailed(let path, let code):
                "meshyyd: cannot bind \(path): \(String(cString: strerror(code)))"
            case .listenFailed(let code):
                "meshyyd: listen() failed: \(String(cString: strerror(code)))"
            case .alreadyRunning(let path):
                "meshyyd: another daemon is already listening on \(path)"
            }
        }
    }

    private let path: String
    private let store: SessionStore
    private let queue = DispatchQueue(label: "meshyy.local.accept")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [ObjectIdentifier: LocalClient] = [:]

    public init(path: String, store: SessionStore) {
        self.path = path
        self.store = store
    }

    /// Default socket location. Under the user's own directory rather than
    /// /var/run: meshyyd is a per-user agent, not a system daemon, and a
    /// system-wide socket would invite the multi-user question the design does
    /// not answer.
    public static var defaultSocketPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".meshyy/meshyyd.sock")
    }

    public func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            // 0700: the socket's permissions are the whole authentication story,
            // so the directory has to be private too.
            attributes: [.posixPermissions: 0o700]
        )

        // A stale socket from a crashed daemon must be cleared, but a *live* one
        // means another daemon owns this path and we must not steal it.
        if FileManager.default.fileExists(atPath: path) {
            if Self.isLive(path: path) {
                throw ServerError.alreadyRunning(path: path)
            }
            try? FileManager.default.removeItem(atPath: path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketFailed(errno: errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            close(fd)
            throw ServerError.pathTooLong(path)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                _ = strlcpy(
                    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
                    source,
                    capacity
                )
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, size)
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw ServerError.bindFailed(path: path, errno: code)
        }

        // Restrict before listening, so there is no window in which the socket is
        // reachable by another user.
        chmod(path, 0o600)

        guard Darwin.listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw ServerError.listenFailed(errno: code)
        }

        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    /// True if something is accepting on `path` right now.
    private static func isLive(path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return false }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                _ = strlcpy(
                    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
                    source,
                    capacity
                )
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, size) == 0
            }
        }
    }

    private func acceptPending() {
        while true {
            let fd = Darwin.accept(listenFD, nil, nil)
            if fd < 0 { return } // EAGAIN: no more pending
            let accepted = fd
            let client = LocalClient(fd: accepted, store: store) { [weak self] finished in
                guard let self else { return }
                self.queue.async { [weak self] in
                    self?.clients.removeValue(forKey: ObjectIdentifier(finished))
                }
            }
            clients[ObjectIdentifier(client)] = client
            client.start()
        }
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        queue.sync {
            for client in clients.values { client.closeConnection() }
            clients.removeAll()
        }
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// One attached client on the local socket.
final class LocalClient: @unchecked Sendable {
    private let fd: Int32
    private let store: SessionStore
    private let queue: DispatchQueue
    private let onFinish: (LocalClient) -> Void

    private var readSource: DispatchSourceRead?
    private var decoder = FrameDecoder()
    private var session: PTYSession?
    private var subscription: UUID?
    private var pumpTask: Task<Void, Never>?
    private var closed = false

    init(fd: Int32, store: SessionStore, onFinish: @escaping (LocalClient) -> Void) {
        self.fd = fd
        self.store = store
        self.onFinish = onFinish
        self.queue = DispatchQueue(label: "meshyy.local.client.\(fd)")
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        // Darwin.close, not the instance method of the same name — the shadowing
        // is why this is spelled out.
        let descriptor = fd
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        readSource = source
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 65536) }
            if count > 0 {
                do {
                    for frame in try decoder.push(Array(buffer[0..<count])) {
                        handle(frame)
                    }
                } catch {
                    // A length-prefixed stream cannot resynchronise, so a
                    // malformed frame is terminal. Say so rather than guessing.
                    send(.control(.error(code: 400, message: "\(error)")))
                    closeConnection()
                    return
                }
                continue
            }
            if count == 0 { closeConnection(); return } // peer hung up
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            if errno == EINTR { continue }
            closeConnection()
            return
        }
    }

    private func handle(_ frame: FrameEnvelope) {
        switch frame.kind {
        case .control:
            guard let control = try? ControlFrame.decode(frame.payload) else {
                // Design doc §5.3: an undecodable control frame from a newer peer
                // is ignored, not fatal.
                return
            }
            handle(control)
        case .pty:
            let bytes = frame.payload
            Task { [weak self] in
                guard let session = self?.currentSession else { return }
                try? await session.send(bytes)
            }
        case .blob:
            // M7. Acknowledged as unimplemented rather than silently dropped.
            send(.control(.error(code: 501, message: "blob channels are not implemented (M7)")))
        }
    }

    private var currentSession: PTYSession? {
        queue.sync { session }
    }

    private func handle(_ control: ControlFrame) {
        switch control {
        case .hello(let hello):
            attach(hello)
        case .resize(let cols, let rows):
            let size = TerminalSize(cols: cols, rows: rows)
            Task { [weak self] in
                guard let session = self?.currentSession else { return }
                try? await session.resize(to: size)
            }
        case .ack:
            // The local socket cannot drop bytes, so an ack carries no
            // information here. It matters on QUIC (M3), where the client's
            // acked offset is what a reconnect resumes from.
            break
        case .bye:
            closeConnection()
        default:
            break
        }
    }

    private func attach(_ hello: ControlFrame.Hello) {
        let name = hello.session ?? "default"
        let size = TerminalSize(cols: hello.cols, rows: hello.rows)

        Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await self.store.attachOrCreate(name: name, size: size)
                let (decision, events, token) = await session.attach(resumeFrom: hello.resumeFrom)
                let info = await session.info

                self.queue.sync {
                    self.session = session
                    self.subscription = token
                }

                self.send(.control(.welcome(.init(
                    sessionID: info.sessionID,
                    bufferedFrom: info.bufferedFrom,
                    bufferedTo: info.bufferedTo
                ))))

                // Design doc §3.5: never silently degrade. A client whose resume
                // could not be honoured is told before the bytes arrive, so it
                // can clear rather than splice a hole into its scrollback.
                switch decision {
                case .replay, .fresh:
                    break
                case .replayFromAnchor(let anchor, _, _):
                    self.send(.control(.resumeTooOld(ptyID: 0, earliestOffset: anchor)))
                case .mustRedraw(let earliest, _):
                    self.send(.control(.resumeTooOld(ptyID: 0, earliestOffset: earliest)))
                case .impossible(let latest):
                    self.send(.control(.error(
                        code: 409,
                        message: "resume offset is ahead of the session; latest is \(latest)"
                    )))
                }

                if !decision.bytes.isEmpty {
                    self.send(.pty(0, decision.bytes))
                }

                let pump = Task { [weak self] in
                    for await event in events {
                        guard let self, !self.isClosed else { return }
                        self.forward(event)
                    }
                }
                self.queue.sync { self.pumpTask = pump }
            } catch {
                self.send(.control(.error(code: 400, message: "\(error)")))
                self.closeConnection()
            }
        }
    }

    private func forward(_ event: SessionEvent) {
        switch event {
        case .output(_, let bytes):
            send(.pty(0, bytes))
        case .termios(let state):
            send(.control(.termios(state)))
        case .screenMode(let alt):
            send(.control(.screenMode(alt: alt)))
        case .agent(let kind, let agentID, let detail):
            send(.control(.agentEvent(kind: kind, agentID: agentID, detail: detail)))
        case .exited(let status):
            send(.control(.bye(reason: "session exited with status \(status)")))
            closeConnection()
        }
    }

    private var isClosed: Bool { queue.sync { closed } }

    /// Writes a frame, looping until the whole thing is out.
    ///
    /// Blocking on a non-blocking fd via a retry loop is acceptable here because
    /// the peer is a local process reading as fast as it can; a slow local reader
    /// costs this one client's queue and nothing else.
    private func send(_ envelope: FrameEnvelope) {
        let bytes = envelope.encoded
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes {
                    Darwin.write(self.fd, $0.baseAddress, $0.count)
                }
                if written > 0 { offset += written; continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { usleep(1_000); continue }
                if errno == EINTR { continue }
                self.closeLocked()
                return
            }
        }
    }

    /// Named `closeConnection` rather than `close` so it cannot be confused with
    /// `Darwin.close` at a call site inside this file.
    func closeConnection() {
        queue.async { [weak self] in self?.closeLocked() }
    }

    private func closeLocked() {
        guard !closed else { return }
        closed = true
        pumpTask?.cancel()
        readSource?.cancel()
        readSource = nil
        if let session, let subscription {
            Task { await session.detach(subscription) }
        }
        onFinish(self)
    }
}
