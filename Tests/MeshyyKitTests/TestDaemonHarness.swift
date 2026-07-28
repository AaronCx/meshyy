import Testing
import Synchronization
// meshyy — a real daemon on throwaway paths, for the client-side tests.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Both transports up, a real identity in a real (per-test) keychain, a real QUIC
// listener and a real PTY. Only SSH is stubbed: the bootstrap response is fetched
// over the unix socket rather than an exec channel, which is exactly what
// `meshyyd attach --json` does on the far side of one anyway.

import Darwin
import Foundation
import MeshyyCore
@testable import MeshyyDaemon

/// A daemon with both transports up, on throwaway paths.
///
/// `@unchecked Sendable` because the suite is `.serialized`: exactly one test
/// touches an instance at a time, and the daemon's own internals are already
/// queue- or actor-confined.
final class TestDaemonHarness: @unchecked Sendable {
    let socketPath: String
    let store: SessionStore
    let tokens: TokenActor
    let identity: DaemonIdentity
    let quic: QUICServer
    let quicPort: UInt16
    private let socketServer: LocalSocketServer
    private let directory: String

    init(bufferCapacity: Int = RingBuffer.defaultCapacity) throws {
        // sockaddr_un.sun_path is 104 bytes on Darwin, so the path is short by
        // construction rather than by luck.
        let token = UUID().uuidString.prefix(8).lowercased()
        directory = "/tmp/meshyy-q-\(token)"
        socketPath = directory + "/d.sock"

        var config = DaemonConfig()
        config.shell = "/bin/sh"
        // Non-login: rc files would make output vary per machine.
        config.shellArguments = []
        config.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color",
            "HOME": NSHomeDirectory(),
        ]
        config.bufferCapacity = bufferCapacity

        store = SessionStore(config: config)
        tokens = TokenActor()
        // A per-test keychain directory, so a test never touches ~/.meshyy and
        // tests cannot interfere with each other or with a real daemon.
        identity = try DaemonIdentity.loadOrCreate(directory: directory)
        quic = QUICServer(identity: identity, store: store, tokens: tokens)
        quicPort = try quic.start()
        socketServer = LocalSocketServer(path: socketPath, store: store, tokens: tokens)
        try socketServer.start()
        socketServer.attachQUIC(quic, fingerprint: identity.fingerprint)
    }

    /// Design doc §5.1 steps 2-3, over the unix socket instead of an SSH exec
    /// channel. Returns the parsed handshake.
    func bootstrap(session: String) throws -> BootstrapResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket }
        defer { Darwin.close(fd) }
        silenceSIGPIPE(on: fd)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            socketPath.withCString { source in
                _ = strlcpy(
                    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
                    source,
                    capacity
                )
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, size) == 0
            }
        }
        guard connected else { throw Failure.connect }

        let request = FrameEnvelope.control(.bootstrapRequest(session: session)).encoded
        _ = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }

        var decoder = FrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 65536) }
            if count <= 0 {
                if count < 0 && (errno == EINTR || errno == EAGAIN) { usleep(5_000); continue }
                break
            }
            for frame in try decoder.push(Array(buffer[0..<count])) where frame.kind == .control {
                guard let control = try? ControlFrame.decode(frame.payload) else { continue }
                if case .bootstrapResponse(let json) = control {
                    return try BootstrapResponse.parse(json)
                }
                if case .error(let code, let message) = control {
                    throw Failure.refused("\(code): \(message)")
                }
            }
        }
        throw Failure.timeout
    }

    enum Failure: Error { case socket, connect, timeout, refused(String) }

    func shutdown() async {
        quic.stop()
        socketServer.stop()
        await store.closeAll()
        try? FileManager.default.removeItem(atPath: directory)
    }
}


/// Whether this machine can run the integration suites at all.
///
/// They need three things a plain unit test does not: a QUIC listener, a unix
/// socket, and a **file keychain** for the daemon's TLS identity. The keychain is
/// the fragile one — `SecKeychainCreate` needs a Security session, and a CI runner
/// may not have one. When it does not, the call does not fail cleanly; it blocks,
/// and the whole suite hangs with no output rather than failing.
///
/// So the capability is probed once, on a thread, behind a deadline. An
/// environment that cannot support these suites SKIPS them with a reason, which is
/// honest, instead of hanging for the job's timeout, which is not.
enum IntegrationSupport {
    nonisolated(unsafe) static let isAvailable: Bool = probe()

    private static func probe() -> Bool {
        let finished = DispatchSemaphore(value: 0)
        let box = Mutex(false)
        // Detached rather than a Task: if the Security call blocks, this thread is
        // stuck forever and must not be holding a cooperative-pool slot.
        Thread.detachNewThread {
            let directory = "/tmp/meshyy-probe-" + UUID().uuidString.prefix(8).lowercased()
            defer { try? FileManager.default.removeItem(atPath: directory) }
            if (try? DaemonIdentity.loadOrCreate(directory: directory)) != nil {
                box.withLock { $0 = true }
            }
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 20) == .success else {
            FileHandle.standardError.write(Data("""
                meshyy tests: a file keychain could not be created within 20s, so the                 socket/QUIC integration suites are SKIPPED in this environment. They                 are not disabled — run them on a machine with a Security session.

                """.utf8))
            return false
        }
        return box.withLock { $0 }
    }
}

/// Parent suite for everything that binds a real socket.
///
/// swift-testing runs distinct top-level suites in PARALLEL. These tests each
/// stand up a QUIC listener, a unix socket and a file keychain, and running two
/// such suites at once made the refused-attach tests fail in the suite while
/// passing alone — which reads exactly like a product bug and is not one. Nesting
/// them under one `.serialized` suite states the real constraint instead of
/// relying on a command-line flag.
@Suite(
    "MeshyyKit (real sockets, serialized)",
    .serialized,
    .enabled(if: IntegrationSupport.isAvailable, "needs a file keychain and real sockets")
)
struct MeshyyKitSuite {}

/// Runs `body` against a fresh daemon and guarantees it is shut down first.
///
/// The obvious `defer { Task { await daemon.shutdown() } }` does NOT wait, so
/// listeners, sessions, shells and file keychains accumulate across a suite. That
/// made "A fabricated token is refused" pass alone and fail in the suite — the
/// classic shape of a test-hygiene bug being mistaken for a product bug.
func withHarness<T>(
    bufferCapacity: Int = RingBuffer.defaultCapacity,
    _ body: (TestDaemonHarness) async throws -> T
) async throws -> T {
    let daemon = try TestDaemonHarness(bufferCapacity: bufferCapacity)
    do {
        let result = try await body(daemon)
        await daemon.shutdown()
        return result
    } catch {
        await daemon.shutdown()
        throw error
    }
}
