// meshyy — the local transport, end to end (design doc M1 acceptance, §6 resume).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Drives the real server over a real unix socket with the real framing, so this
// covers the whole stack below the network: framing, control frames, session
// store, PTY, ring buffer, and the resume decision.

import Darwin
import Foundation
import Testing
@testable import MeshyyCore
@testable import MeshyyDaemon

/// A minimal client: connect, frame, unframe. Deliberately not `AttachClient` —
/// a test that drove the shipping client would pass whenever the two agreed with
/// each other rather than with the protocol.
private final class TestClient {
    fileprivate var fd: Int32 = -1
    private var decoder = FrameDecoder()
    private(set) var received: [FrameEnvelope] = []

    init(socketPath: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket }

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
        guard connected else {
            Darwin.close(fd)
            throw Failure.connect(String(cString: strerror(errno)))
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        silenceSIGPIPE(on: fd)
    }

    enum Failure: Error { case socket, connect(String) }

    func send(_ envelope: FrameEnvelope) {
        let bytes = envelope.encoded
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress, $0.count)
            }
            if written > 0 { offset += written; continue }
            if errno == EAGAIN || errno == EINTR { usleep(1_000); continue }
            return
        }
    }

    /// Pumps until `predicate` is satisfied or the deadline passes.
    @discardableResult
    func pump(timeout: TimeInterval = 5, until predicate: ([FrameEnvelope]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        if predicate(received) { return true }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 65536) }
            if count > 0 {
                received += (try? decoder.push(Array(buffer[0..<count]))) ?? []
                if predicate(received) { return true }
                continue
            }
            usleep(10_000)
        }
        return predicate(received)
    }

    /// Every PTY byte received, concatenated — the stream the client would have
    /// fed its emulator.
    var ptyStream: [UInt8] {
        received.filter { $0.kind == .pty }.flatMap(\.payload)
    }

    var controlFrames: [ControlFrame] {
        received.filter { $0.kind == .control }.compactMap { try? ControlFrame.decode($0.payload) }
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }
}

/// A server on a unique temp socket, torn down with the harness.
private func withServer(
    bufferCapacity: Int = RingBuffer.defaultCapacity,
    _ body: (String, SessionStore) async throws -> Void
) async throws {
    // sockaddr_un.sun_path is 104 bytes on Darwin, and NSTemporaryDirectory()
    // plus a UUID overflows it — so the path is short by construction rather
    // than by luck.
    let token = UUID().uuidString.prefix(8).lowercased()
    let directory = "/tmp/meshyy-t-\(token)"
    let path = directory + "/d.sock"
    defer { try? FileManager.default.removeItem(atPath: directory) }

    var config = DaemonConfig()
    // `sh -c`-free but non-login: a login shell would source rc files and make
    // output unpredictable across machines.
    config.shell = "/bin/sh"
    config.shellArguments = []
    config.bufferCapacity = bufferCapacity
    config.environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "TERM": "xterm-256color",
        "HOME": NSHomeDirectory(),
    ]

    let store = SessionStore(config: config)
    let server = LocalSocketServer(path: path, store: store)
    try server.start()
    defer { server.stop() }

    try await body(path, store)
    await store.closeAll()
}

/// Splits a marker across printf arguments so the command's own echo cannot
/// satisfy an assertion about the command's output. Same reasoning as PTYTests.
private func markerCommand(_ marker: String) -> [UInt8] {
    let midpoint = marker.index(marker.startIndex, offsetBy: marker.count / 2)
    let command = "printf '%s%s\\n' '\(marker[marker.startIndex..<midpoint])' "
        + "'\(marker[midpoint...])'\n"
    return Array(command.utf8)
}

@Suite("Local socket transport", .serialized)
struct LocalSocketTests {

    @Test("The socket and its directory are private (design doc §8)")
    func socketPermissions() async throws {
        try await withServer { path, _ in
            let socket = try FileManager.default.attributesOfItem(atPath: path)
            let directory = try FileManager.default.attributesOfItem(
                atPath: (path as NSString).deletingLastPathComponent
            )
            #expect(socket[.posixPermissions] as? Int == 0o600,
                    "the socket's permissions are the whole authentication story")
            #expect(directory[.posixPermissions] as? Int == 0o700)
        }
    }

    /// Design doc M1 acceptance: attach gives a working shell.
    @Test("Hello is answered with Welcome and a live shell")
    func attachGivesAShell() async throws {
        try await withServer { path, _ in
            let client = try TestClient(socketPath: path)
            defer { client.close() }

            client.send(.control(.hello(.init(token: "", cols: 100, rows: 30, session: "m1"))))
            #expect(client.pump { frames in
                frames.contains { $0.kind == .control }
            }, "no Welcome arrived")

            guard case .welcome(let welcome)? = client.controlFrames.first(where: {
                if case .welcome = $0 { return true }
                return false
            }) else {
                Issue.record("first control frame was not a Welcome: \(client.controlFrames)")
                return
            }
            #expect(welcome.sessionID.count == 32, "session ids are 128-bit random (design doc §8)")
            #expect(welcome.protocolVersion == Meshyy.protocolVersion)

            client.send(.pty(0, markerCommand("M1_ATTACH_OK")))
            #expect(client.pump { _ in
                String(decoding: client.ptyStream, as: UTF8.self).contains("M1_ATTACH_OK")
            }, "shell never ran the command; got \(String(decoding: client.ptyStream, as: UTF8.self).debugDescription)")
        }
    }

    @Test("The requested window size reaches the shell, and a resize is forwarded")
    func sizeAndResize() async throws {
        try await withServer { path, _ in
            let client = try TestClient(socketPath: path)
            defer { client.close() }
            client.send(.control(.hello(.init(token: "", cols: 111, rows: 41, session: "size"))))
            #expect(client.pump { !$0.isEmpty })

            client.send(.pty(0, Array("stty size\n".utf8)))
            #expect(client.pump { _ in
                String(decoding: client.ptyStream, as: UTF8.self).contains("41 111")
            }, "initial size did not reach the shell")

            client.send(.control(.resize(cols: 90, rows: 28)))
            client.send(.pty(0, Array("stty size\n".utf8)))
            #expect(client.pump { _ in
                String(decoding: client.ptyStream, as: UTF8.self).contains("28 90")
            }, "resize did not reach the shell")
        }
    }

    /// The M3 payoff, over the M1 transport: a client that reconnects with the
    /// offset it last held gets a byte-exact continuation.
    @Test("Reattaching with a resume offset replays byte-exactly")
    func resumeReplaysExactly() async throws {
        try await withServer { path, store in
            // First attachment: run something, remember everything seen.
            let first = try TestClient(socketPath: path)
            first.send(.control(.hello(.init(token: "", cols: 80, rows: 24, session: "resume"))))
            #expect(first.pump { !$0.isEmpty })
            first.send(.pty(0, markerCommand("BEFORE_DROP")))
            #expect(first.pump { _ in
                String(decoding: first.ptyStream, as: UTF8.self).contains("BEFORE_DROP")
            })
            let seenBefore = first.ptyStream

            // The socket dies, standing in for an iOS suspension.
            first.close()

            // Output continues while nobody is attached.
            let session = await store.session(named: "resume")
            #expect(session != nil)
            try await session?.send(markerCommand("WHILE_AWAY"))
            try await Task.sleep(for: .milliseconds(600))

            // Reattach from exactly what the first client consumed.
            let second = try TestClient(socketPath: path)
            defer { second.close() }
            second.send(.control(.hello(.init(
                token: "", cols: 80, rows: 24,
                resumeFrom: UInt64(seenBefore.count),
                session: "resume"
            ))))
            #expect(second.pump { _ in
                String(decoding: second.ptyStream, as: UTF8.self).contains("WHILE_AWAY")
            }, "replay did not contain what happened while away")

            // §6.4: no gaps, no duplicates. The two clients' streams concatenated
            // must equal what the PTY produced, so the replay must begin exactly
            // where the first client stopped.
            let combined = seenBefore + second.ptyStream
            let text = String(decoding: combined, as: UTF8.self)
            #expect(text.contains("BEFORE_DROP"))
            #expect(text.contains("WHILE_AWAY"))
            // A duplicated replay would show the pre-drop marker twice.
            let occurrences = text.components(separatedBy: "BEFORE_DROP").count - 1
            #expect(occurrences == 1,
                    "resume duplicated bytes the client already had (\(occurrences) copies)")

            // And no ResumeTooOld, because the 4 MB default easily covers this.
            #expect(!second.controlFrames.contains { frame in
                if case .resumeTooOld = frame { return true }
                return false
            }, "resume should have been honoured outright")
        }
    }

    /// Design doc §3.5, fail visible: an overrun must be announced, not spliced.
    ///
    /// The first version of this test assumed a fixed amount of shell output would
    /// overflow a 512-byte buffer. It did locally and did not on CI, because the
    /// prompt string differs per machine and the prompt is part of the volume. So
    /// this waits for the precondition it actually needs — that eviction has
    /// happened — instead of assuming it.
    @Test("An overrun resume is announced with ResumeTooOld rather than spliced silently")
    func overrunIsAnnounced() async throws {
        try await withServer(bufferCapacity: 512) { path, store in
            let client = try TestClient(socketPath: path)
            defer { client.close() }
            client.send(.control(.hello(.init(token: "", cols: 80, rows: 24, session: "overrun"))))
            #expect(client.pump { !$0.isEmpty })

            guard let session = await store.session(named: "overrun") else {
                Issue.record("session was not created")
                return
            }

            // Far more than 512 bytes, deterministically.
            let filler = "0123456789012345678901234567890123456789012345678901234567890"
            let loop = "i=0; while [ $i -lt 200 ]; do printf '%s\\n' '\(filler)'; i=$((i+1)); done\n"
            try await session.send(Array(loop.utf8))

            // Wait for eviction rather than for a duration: the buffer's own window
            // moving off zero is the precondition, and nothing else will do.
            var evicted = false
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if await session.info.bufferedFrom > 0 { evicted = true; break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(evicted, "the ring buffer never overran, so there is nothing to announce")
            guard evicted else { return }

            let late = try TestClient(socketPath: path)
            defer { late.close() }
            late.send(.control(.hello(.init(
                token: "", cols: 80, rows: 24, resumeFrom: 0, session: "overrun"
            ))))
            #expect(late.pump { frames in
                frames.compactMap { try? ControlFrame.decode($0.payload) }.contains { frame in
                    if case .resumeTooOld = frame { return true }
                    return false
                }
            }, "an evicted offset must produce ResumeTooOld; got \(late.controlFrames)")
        }
    }

    @Test("A resume offset ahead of the session is refused, not clamped")
    func impossibleOffsetIsRefused() async throws {
        try await withServer { path, _ in
            let client = try TestClient(socketPath: path)
            defer { client.close() }
            client.send(.control(.hello(.init(
                token: "", cols: 80, rows: 24, resumeFrom: 999_999, session: "ahead"
            ))))
            #expect(client.pump { frames in
                frames.compactMap { try? ControlFrame.decode($0.payload) }.contains { frame in
                    if case .error = frame { return true }
                    return false
                }
            }, "an impossible offset must be reported; got \(client.controlFrames)")
        }
    }

    @Test("Two clients on the same session both see live output")
    func twoClientsShareASession() async throws {
        try await withServer { path, _ in
            let first = try TestClient(socketPath: path)
            defer { first.close() }
            let second = try TestClient(socketPath: path)
            defer { second.close() }

            for client in [first, second] {
                client.send(.control(.hello(.init(
                    token: "", cols: 80, rows: 24, session: "shared"
                ))))
                #expect(client.pump { !$0.isEmpty })
            }

            first.send(.pty(0, markerCommand("SHARED_OUTPUT")))
            for (index, client) in [first, second].enumerated() {
                #expect(client.pump { _ in
                    String(decoding: client.ptyStream, as: UTF8.self).contains("SHARED_OUTPUT")
                }, "client \(index) did not see the shared output")
            }
        }
    }

    @Test("An unknown control frame is ignored, not fatal (design doc §5.3)")
    func unknownFrameIsIgnored() async throws {
        try await withServer { path, _ in
            let client = try TestClient(socketPath: path)
            defer { client.close() }
            client.send(.control(.hello(.init(token: "", cols: 80, rows: 24, session: "skew"))))
            #expect(client.pump { !$0.isEmpty })

            // A frame from a hypothetical newer client.
            let future = CBOR.map([
                (.text("t"), .text("teleport")),
                (.text("destination"), .text("mars")),
            ])
            client.send(FrameEnvelope(kind: .control, payload: future.encode()))

            // The session must still work afterwards.
            client.send(.pty(0, markerCommand("STILL_ALIVE")))
            #expect(client.pump { _ in
                String(decoding: client.ptyStream, as: UTF8.self).contains("STILL_ALIVE")
            }, "an unknown control frame killed the session")
        }
    }

    @Test("A malformed frame header closes the connection with an error")
    func malformedFrameIsTerminal() async throws {
        try await withServer { path, _ in
            let client = try TestClient(socketPath: path)
            defer { client.close() }
            // Channel kind 99 does not exist. A length-prefixed stream cannot
            // resynchronise, so this must be terminal rather than skipped.
            client.send(FrameEnvelope(kind: .control, payload: []))
            var raw = FrameEnvelope(kind: .pty, payload: [1, 2, 3]).encoded
            raw[0] = 99
            client.sendRaw(raw)

            #expect(client.pump(timeout: 3) { frames in
                frames.compactMap { try? ControlFrame.decode($0.payload) }.contains { frame in
                    if case .error = frame { return true }
                    return false
                }
            }, "a malformed frame must be reported; got \(client.controlFrames)")
        }
    }

    /// Pins the ordering guarantee. `SessionAttachment` used to spawn a separate
    /// Task per pty write and per resize, and tasks enqueued on an actor run in an
    /// UNSPECIFIED order — so two keystroke chunks could reach the PTY reversed, and
    /// a resize could apply after the command that depended on it. CI caught the
    /// resize case; scrambled input is the one that would have been blamed on the
    /// network.
    @Test("Consecutive writes reach the PTY in the order they were sent")
    func writesAreOrdered() async throws {
        try await withServer { path, _ in
            let client = try TestClient(socketPath: path)
            defer { client.close() }
            client.send(.control(.hello(.init(token: "", cols: 80, rows: 24, session: "order"))))
            #expect(client.pump { !$0.isEmpty })

            // One command split across many frames, one byte at a time. If the daemon
            // reorders any of them the shell sees garbage and the marker never
            // appears — which is a far stronger check than comparing timestamps.
            let command = Array("printf '%s%s\\n' ORDER ED_OK\n".utf8)
            for byte in command {
                client.send(.pty(0, [byte]))
            }
            #expect(client.pump { _ in
                String(decoding: client.ptyStream, as: UTF8.self).contains("ORDERED_OK")
            }, "input was reordered; got \(String(decoding: client.ptyStream, as: UTF8.self).debugDescription)")
        }
    }

    /// The case CI actually caught: a resize immediately followed by a command must
    /// apply before the command runs.
    @Test("A resize applies before a command sent immediately after it")
    func resizeOrderedBeforeCommand() async throws {
        try await withServer { path, _ in
            let client = try TestClient(socketPath: path)
            defer { client.close() }
            client.send(.control(.hello(.init(token: "", cols: 80, rows: 24, session: "rz"))))
            #expect(client.pump { !$0.isEmpty })

            // No wait between them, on purpose.
            client.send(.control(.resize(cols: 133, rows: 47)))
            client.send(.pty(0, Array("stty size\n".utf8)))
            #expect(client.pump { _ in
                String(decoding: client.ptyStream, as: UTF8.self).contains("47 133")
            }, "the resize did not apply before the command; got \(String(decoding: client.ptyStream, as: UTF8.self).debugDescription)")
        }
    }
}

extension TestClient {
    /// Writes bytes that are deliberately not a valid envelope.
    func sendRaw(_ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress, $0.count)
            }
            if written > 0 { offset += written; continue }
            if errno == EAGAIN || errno == EINTR { usleep(1_000); continue }
            return
        }
    }

}
