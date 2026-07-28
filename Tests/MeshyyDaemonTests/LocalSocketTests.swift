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
    private var consumed = 0

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

    /// Generous on purpose.
///
/// These helpers return as soon as the predicate holds, so a large ceiling costs
/// nothing when things work — it only changes how long a genuine failure takes to
/// report. A tight ceiling, by contrast, turns a slow CI runner into a red build:
/// every one of these waits is on a real shell echoing through a real PTY, and a
/// loaded two-core runner is several times slower than this Mac. Two different
/// tests failed on two consecutive CI runs for exactly this reason.
    @discardableResult
    func pump(timeout: TimeInterval = 30, until predicate: ([FrameEnvelope]) -> Bool) -> Bool {
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

    /// Every PTY byte received since the last `consumeStream()`, concatenated —
    /// the stream the client would have fed its emulator.
    var ptyStream: [UInt8] {
        Array(received.filter { $0.kind == .pty }.flatMap(\.payload).dropFirst(consumed))
    }

    /// Total PTY bytes ever received, including anything already consumed.
    ///
    /// This — not `ptyStream.count` — is the absolute offset to resume from. The
    /// two differ after `consumeStream()`, and conflating them made a resume ask
    /// for an offset 17 bytes behind reality and get 17 duplicated bytes back. The
    /// real client keeps the same distinction: `consumedOffset` is absolute.
    var absolutePTYCount: Int {
        received.filter { $0.kind == .pty }.flatMap(\.payload).count
    }

    /// Marks everything received so far as consumed, so a byte-exact assertion can
    /// start from a clean slate after a handshake.
    func consumeStream() {
        consumed = absolutePTYCount
    }

    var controlFrames: [ControlFrame] {
        received.filter { $0.kind == .control }.compactMap { try? ControlFrame.decode($0.payload) }
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }
}

/// What the session's child process is.
private enum SessionChild {
    /// A child that produces output forever without being asked — `yes`. For
    /// backpressure: the question is whether the daemon keeps draining a PTY when
    /// nobody is listening.
    case firehose
    /// A pure byte pipe: what goes in comes back, exactly. The right instrument
    /// when the subject is the transport. See `DaemonConfig.deterministicEcho`.
    case bytePipe
    /// A real interactive shell. Only for tests whose subject IS the shell —
    /// `stty size` reaching the kernel, or M1's "attach gives a working shell".
    case shell
}

/// A server on a unique temp socket, torn down with the harness.
private func withServer(
    bufferCapacity: Int = RingBuffer.defaultCapacity,
    child: SessionChild = .bytePipe,
    _ body: (String, SessionStore) async throws -> Void
) async throws {
    // sockaddr_un.sun_path is 104 bytes on Darwin, and NSTemporaryDirectory()
    // plus a UUID overflows it — so the path is short by construction rather
    // than by luck.
    let token = UUID().uuidString.prefix(8).lowercased()
    let directory = "/tmp/meshyy-t-\(token)"
    let path = directory + "/d.sock"
    defer { try? FileManager.default.removeItem(atPath: directory) }

    var config: DaemonConfig
    switch child {
    case .firehose:
        config = DaemonConfig.deterministicEcho(bufferCapacity: bufferCapacity)
        config.shell = "/usr/bin/yes"
        config.shellArguments = ["meshyy-backpressure"]
    case .bytePipe:
        config = DaemonConfig.deterministicEcho(bufferCapacity: bufferCapacity)
    case .shell:
        // Non-login: a login shell sources rc files and makes output vary by machine.
        config = DaemonConfig()
        config.shell = "/bin/sh"
        config.shellArguments = []
        config.bufferCapacity = bufferCapacity
        config.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color",
            "HOME": NSHomeDirectory(),
        ]
    }

    let store = SessionStore(config: config)
    let server = LocalSocketServer(path: path, store: store)
    try server.start()
    defer { server.stop() }

    try await body(path, store)
    await store.closeAll()
}

/// Splits a marker across printf arguments so a *shell's* echo of the command
/// cannot satisfy an assertion about the command's output. Only needed for the
/// `.shell` tests; a byte pipe needs no such trick, because there is nothing to
/// distinguish echo from output.
private func markerCommand(_ marker: String) -> [UInt8] {
    let midpoint = marker.index(marker.startIndex, offsetBy: marker.count / 2)
    let command = "printf '%s%s\\n' '\(marker[marker.startIndex..<midpoint])' "
        + "'\(marker[midpoint...])'\n"
    return Array(command.utf8)
}

/// Deterministic payload of `count` bytes, distinct enough that a reordering or a
/// duplication changes the array rather than merely the timing.
///
/// **Printable ASCII only.** Even under `stty raw` a PTY is not transparent to
/// arbitrary bytes: flow-control and signal characters are eaten by the line
/// discipline. A first version generating 0…250 returned 312 of 700 bytes. See
/// `DaemonConfig.deterministicEcho`.
private func payload(_ count: Int, seed: UInt8 = 0) -> [UInt8] {
    let printable = Array(0x20...0x7E)   // space through tilde, 95 values
    return (0..<count).map { UInt8(printable[($0 * 7 + Int(seed) * 31) % printable.count]) }
}


@Suite("Local socket transport", .serialized,
       .enabled(if: RealProcessTests.isEnabled, RealProcessTests.reason))
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
        try await withServer(child: .shell) { path, _ in
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
        try await withServer(child: .shell) { path, _ in
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
    ///
    /// Asserts on whole byte arrays, not marker substrings. `docs/qa/mutation-log.md`
    /// records a duplicating mutant that slipped past a substring-based "no
    /// duplicates" assertion because the duplication missed the marker.
    @Test("Reattaching with a resume offset replays byte-exactly")
    func resumeReplaysExactly() async throws {
        try await withServer { path, store in
            let first = try TestClient(socketPath: path)
            first.send(.control(.hello(.init(token: "", cols: 80, rows: 24, session: "resume"))))
            #expect(first.pump { !$0.isEmpty }, "no Welcome")

            let before = payload(400, seed: 1)
            first.send(.pty(0, before))
            #expect(first.pump { _ in first.ptyStream.count >= before.count },
                    "byte pipe did not return the first payload")
            let seenBefore = first.ptyStream
            // Absolute, including the handshake marker — see `absolutePTYCount`.
            let absoluteOffset = first.absolutePTYCount

            // The socket dies, standing in for an iOS suspension.
            first.close()

            // Output continues while nobody is attached.
            let session = await store.session(named: "resume")
            #expect(session != nil)
            let away = payload(300, seed: 2)
            try await session?.send(away)
            try await Task.sleep(for: .milliseconds(400))

            // Reattach from exactly what the first client consumed.
            let second = try TestClient(socketPath: path)
            defer { second.close() }
            second.send(.control(.hello(.init(
                token: "", cols: 80, rows: 24,
                resumeFrom: UInt64(absoluteOffset),
                session: "resume"
            ))))
            #expect(second.pump { _ in second.ptyStream.count >= away.count },
                    "replay did not contain what happened while away")

            // §6.4, asserted exactly: the two clients' streams concatenated must
            // equal what the PTY produced, with no gap and no overlap.
            let combined = seenBefore + second.ptyStream
            let expected = before + away
            #expect(combined.count == expected.count,
                    "expected \(expected.count) bytes across the seam, got \(combined.count)")
            #expect(combined == expected, "the byte stream across the seam is not exact")

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
            // Written straight to the PTY rather than looped in a shell: 12 KiB
            // against a 512-byte buffer, with no dependence on shell timing.
            try await session.send(payload(12_288, seed: 6))

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
        try await withServer { path, store in
            let first = try TestClient(socketPath: path)
            defer { first.close() }
            let second = try TestClient(socketPath: path)
            defer { second.close() }

            for client in [first, second] {
                client.send(.control(.hello(.init(
                    token: "", cols: 80, rows: 24, session: "shared"
                ))))
                #expect(client.pump { !$0.isEmpty }, "no Welcome")
            }

            // Driven from the daemon side so neither client is the writer, which
            // makes "both saw it" a claim about fan-out rather than about echo.
            let bytes = payload(256, seed: 3)
            try await (await store.session(named: "shared"))?.send(bytes)

            for (index, client) in [first, second].enumerated() {
                #expect(client.pump { _ in client.ptyStream.count >= bytes.count },
                        "client \(index) did not see the shared output")
                #expect(client.ptyStream.suffix(bytes.count) == bytes,
                        "client \(index) saw different bytes")
            }
        }
    }

    @Test("An unknown control frame is ignored, not fatal (design doc §5.3)")
    func unknownFrameIsIgnored() async throws {
        try await withServer { path, _ in
            let client = try TestClient(socketPath: path)
            defer { client.close() }
            client.send(.control(.hello(.init(token: "", cols: 80, rows: 24, session: "skew"))))
            #expect(client.pump { !$0.isEmpty }, "no Welcome")

            // A frame from a hypothetical newer client.
            let future = CBOR.map([
                (.text("t"), .text("teleport")),
                (.text("destination"), .text("mars")),
            ])
            client.send(FrameEnvelope(kind: .control, payload: future.encode()))

            // The session must still work afterwards.
            let bytes = payload(64, seed: 4)
            client.send(.pty(0, bytes))
            #expect(client.pump { _ in client.ptyStream.count >= bytes.count },
                    "an unknown control frame killed the session")
            #expect(client.ptyStream.suffix(bytes.count) == bytes)
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
            #expect(client.pump { !$0.isEmpty }, "no Welcome")

            // 512 bytes, ONE FRAME PER BYTE, through a byte pipe. Any reordering,
            // duplication or loss changes the returned array — which the earlier
            // shell-based version could not detect, because it only checked that a
            // marker substring appeared somewhere.
            let bytes = payload(512, seed: 5)
            for byte in bytes {
                client.send(.pty(0, [byte]))
            }
            #expect(client.pump { _ in client.ptyStream.count >= bytes.count },
                    "only \(client.ptyStream.count) of \(bytes.count) bytes came back")
            #expect(client.ptyStream == bytes,
                    "input was reordered, duplicated or dropped across 512 single-byte frames")
        }
    }

    /// The case CI actually caught: a resize immediately followed by a command must
    /// apply before the command runs.
    @Test("A resize applies before a command sent immediately after it")
    func resizeOrderedBeforeCommand() async throws {
        try await withServer(child: .shell) { path, _ in
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

    // MARK: - Backpressure (hardening 1d)

    /// The daemon must keep draining the PTY when no client is attached.
    ///
    /// If the read loop ever waits on anything a client controls, the child blocks
    /// on its own stdout and the session hangs for real — and it hangs for the user
    /// who walked away, which is the user least able to explain what happened.
    ///
    /// This found a live deadlock in the mirror direction. `PTYSession.send` used to
    /// loop until the PTY accepted every byte, on the same actor that runs the read
    /// loop, so any write larger than the PTY's few-KiB input buffer wedged the
    /// session permanently at 100% CPU. See `PTY.writeSome`.
    @Test("A firehose child never blocks while no client is attached")
    func firehoseKeepsDrainingWithNoClient() async throws {
        // 64 KiB buffer against an unbounded producer: it must wrap many times.
        try await withServer(bufferCapacity: 64 * 1024, child: .firehose) { _, store in
            let session = try await store.attachOrCreate(name: "firehose", size: .default)

            // Wait for the ring to have cycled well past its capacity, which can only
            // happen if the daemon kept reading with nobody attached.
            let target: UInt64 = 8 * 64 * 1024
            var produced: UInt64 = 0
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                produced = await session.info.bufferedTo
                if produced >= target { break }
                try await Task.sleep(for: .milliseconds(50))
            }

            #expect(produced >= target,
                    "only \(produced) bytes drained in 30s; the read loop is not keeping up")
            #expect(await session.isAlive, "the child died or blocked instead of producing")

            // Oldest-first eviction: the window has moved off zero and is capped.
            let window = await session.info
            #expect(window.bufferedFrom > 0, "the ring buffer never evicted anything")
            #expect(window.bufferedTo - window.bufferedFrom <= 64 * 1024,
                    "the buffer grew past its capacity")

            // And nothing is stuck waiting to be written to the PTY.
            #expect(await session.pendingWriteCount == 0)
        }
    }

    /// The other half of 1d: after all that eviction, a client resuming from an
    /// offset that is long gone gets a clean answer rather than a stall.
    @Test("A resume from an evicted offset yields ResumeTooOld, not a stall")
    func evictedOffsetYieldsResumeTooOld() async throws {
        try await withServer(bufferCapacity: 64 * 1024, child: .firehose) { path, store in
            let session = try await store.attachOrCreate(name: "firehose", size: .default)
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if await session.info.bufferedFrom > 0 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(await session.info.bufferedFrom > 0, "nothing was evicted in 30s")

            let client = try TestClient(socketPath: path)
            defer { client.close() }
            client.send(.control(.hello(.init(
                token: "", cols: 80, rows: 24, resumeFrom: 0, session: "firehose"
            ))))
            #expect(client.pump(timeout: 10) { frames in
                frames.compactMap { try? ControlFrame.decode($0.payload) }.contains { frame in
                    if case .resumeTooOld = frame { return true }
                    return false
                }
            }, "an evicted offset must be answered, not stalled; got \(client.controlFrames)")
        }
    }

    /// A write larger than the PTY's input buffer must be accepted and drained
    /// rather than blocking the session. This is the exact shape of a paste.
    @Test("A write far larger than the PTY input buffer drains without wedging")
    func largeWriteDoesNotWedge() async throws {
        try await withServer { path, store in
            let client = try TestClient(socketPath: path)
            defer { client.close() }
            client.send(.control(.hello(.init(token: "", cols: 80, rows: 24, session: "paste"))))
            #expect(client.pump { !$0.isEmpty }, "no Welcome")

            // 128 KiB in one go — far past any PTY input buffer.
            let big = payload(128 * 1024, seed: 9)
            client.send(.pty(0, big))

            #expect(client.pump(timeout: 30) { _ in client.ptyStream.count >= big.count },
                    "only \(client.ptyStream.count) of \(big.count) bytes came back")
            #expect(client.ptyStream == big, "a large write was not echoed byte-exactly")

            let session = await store.session(named: "paste")
            #expect(await session?.pendingWriteCount == 0, "the write queue did not drain")
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
