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

/// Stops a write to a hung-up peer from killing the process.
///
/// On Darwin, `write` to a socket whose peer has closed raises SIGPIPE, whose
/// default disposition is to terminate. For a daemon that is fatal and absurd:
/// one client quitting at the wrong moment takes down every other session. This
/// makes the write return EPIPE instead, which the write loops handle.
///
/// Found by `LocalSocketTests.overrunIsAnnounced`, which closes clients while the
/// server is mid-burst; the whole test process died with signal 13.
public func silenceSIGPIPE(on fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
}

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
    private let tokens: TokenActor?
    private let queue = DispatchQueue(label: "meshyy.local.accept")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [ObjectIdentifier: LocalClient] = [:]
    private var quic: QUICServer?
    private var fingerprint: String?

    public init(path: String, store: SessionStore, tokens: TokenActor? = nil) {
        self.path = path
        self.store = store
        self.tokens = tokens
    }

    /// Lets the local socket answer §5.1 bootstrap requests once a QUIC listener
    /// exists. A separate call rather than an init parameter because the QUIC
    /// listener may fail to start and the local socket must still work — a daemon
    /// that refuses to run because one of two transports is unavailable is worse
    /// than one that says so and carries on.
    public func attachQUIC(_ server: QUICServer, fingerprint: String) {
        queue.sync {
            quic = server
            self.fingerprint = fingerprint
        }
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
            silenceSIGPIPE(on: accepted)
            let client = LocalClient(
                fd: accepted,
                store: store,
                bootstrap: BootstrapProvider(
                    tokens: tokens,
                    port: { [weak self] in self?.queue.sync { self?.quic?.boundPort } ?? nil },
                    fingerprint: { [weak self] in self?.queue.sync { self?.fingerprint } ?? nil }
                )
            ) { [weak self] finished in
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

/// Everything needed to answer a §5.1 bootstrap request.
///
/// The port and fingerprint are read through closures rather than captured,
/// because the QUIC listener is attached after the socket server starts and may
/// never be attached at all.
struct BootstrapProvider: Sendable {
    let tokens: TokenActor?
    let port: @Sendable () -> UInt16?
    let fingerprint: @Sendable () -> String?
}

/// One attached client on the local socket.
///
/// Deliberately thin: it moves bytes between the socket and `FrameDecoder`, and
/// hands every frame to `SessionAttachment`, which owns the protocol. The QUIC
/// transport is the same shape — that is what makes design doc §3.3's
/// "transport is replaceable" true rather than aspirational.
final class LocalClient: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private let onFinish: (LocalClient) -> Void

    private let store: SessionStore
    private let bootstrap: BootstrapProvider
    private var readSource: DispatchSourceRead?
    private var decoder = FrameDecoder()
    private var attachment: SessionAttachment?
    private var closed = false

    init(
        fd: Int32,
        store: SessionStore,
        bootstrap: BootstrapProvider,
        onFinish: @escaping (LocalClient) -> Void
    ) {
        self.fd = fd
        self.store = store
        self.bootstrap = bootstrap
        self.onFinish = onFinish
        self.queue = DispatchQueue(label: "meshyy.local.client.\(fd)")
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        self.attachment = SessionAttachment(
            store: store,
            // Opening a 0600 socket in a 0700 directory already proved the caller
            // is this user, so there is nothing for a token to add here.
            authority: .localSocket,
            send: { [weak self] envelope in self?.write(envelope) },
            close: { [weak self] in self?.closeConnection() }
        )
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
                        // Bootstrap is a local-transport concern, not part of the
                        // session protocol, so it is answered here rather than
                        // inside SessionAttachment.
                        if frame.kind == .control,
                           let control = try? ControlFrame.decode(frame.payload),
                           case .bootstrapRequest(let session) = control {
                            handleBootstrap(session: session)
                            continue
                        }
                        attachment?.receive(frame)
                    }
                } catch {
                    // A length-prefixed stream cannot resynchronise, so a
                    // malformed frame is terminal. Say so rather than guessing.
                    write(.control(.error(code: 400, message: "\(error)")))
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

    /// Answers a §5.1 bootstrap request: ensure the session exists, mint a
    /// single-use token bound to its id, and hand back the JSON verbatim.
    private func handleBootstrap(session name: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let tokens = self.bootstrap.tokens else {
                self.write(.control(.error(code: 503, message: "no token store configured")))
                return
            }
            guard let port = self.bootstrap.port(), port != 0 else {
                self.write(.control(.error(
                    code: 503,
                    message: "the QUIC listener is not running; use the unix socket directly"
                )))
                return
            }
            guard let fingerprint = self.bootstrap.fingerprint() else {
                self.write(.control(.error(code: 503, message: "no certificate fingerprint")))
                return
            }
            guard SessionStore.isValidName(name) else {
                self.write(.control(.error(
                    code: 400,
                    message: "session name \(name.debugDescription) is not allowed"
                )))
                return
            }

            do {
                // Created here rather than on QUIC attach, because the token has to
                // be bound to a session id that already exists.
                let session = try await self.store.attachOrCreate(name: name, size: .default)
                let info = await session.info
                let token = await tokens.issue(sessionID: info.sessionID)
                let response = BootstrapResponse(
                    port: port,
                    token: token,
                    certSHA256: fingerprint,
                    sessionID: info.sessionID
                )
                let json = String(decoding: try response.encoded(), as: UTF8.self)
                self.write(.control(.bootstrapResponse(json: json)))
            } catch {
                self.write(.control(.error(code: 500, message: "\(error)")))
            }
        }
    }

    /// Writes a frame, looping until the whole thing is out.
    ///
    /// Retrying on EAGAIN is acceptable because the peer is a local process
    /// reading as fast as it can; a slow local reader costs this one client's
    /// queue and nothing else. EPIPE lands in the final branch and closes.
    private func write(_ envelope: FrameEnvelope) {
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
                // EPIPE: the peer hung up mid-write. Routine, not exceptional.
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
        readSource?.cancel()
        readSource = nil
        let attachment = self.attachment
        self.attachment = nil
        // finish() calls back into closeTransport, which re-enters closeLocked —
        // harmless now that `closed` is already true.
        attachment?.finish()
        onFinish(self)
    }
}
