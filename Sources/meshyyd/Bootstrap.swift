// meshyy — `meshyyd attach --session X --json` (design doc §5.1 step 2/3).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// This runs on an SSH exec channel. The already-running daemon holds the QUIC
// listener and the sessions, so this process asks it over the unix socket for a
// session and a single-use token, prints the handshake as JSON, and exits.
//
// It prints exactly one JSON object on stdout and nothing else. Diagnostics go to
// stderr, because the client parses stdout and a stray line there is a bug in the
// handshake rather than a cosmetic problem. (The client's parser tolerates
// surrounding noise anyway — a MOTD is not our fault — but we should not add to it.)

import Darwin
import Foundation
import MeshyyCore
import MeshyyDaemon

enum Bootstrap {
    /// Who names the session: the caller (`--session`), or the daemon
    /// (`--new-in-group`, which allocates the lowest free numbered name).
    enum Target {
        case named(String)
        case newInGroup(String)
    }

    static func run(socketPath: String, session: String) async {
        await run(socketPath: socketPath, target: .named(session))
    }

    static func run(socketPath: String, target: Target) async {
        switch target {
        case .named(let session):
            guard SessionStore.isValidName(session) else {
                fail("session name \(session.debugDescription) is not allowed")
            }
        case .newInGroup(let prefix):
            // The daemon appends a slot number, so validity is judged on a name the
            // group can actually produce rather than on the bare prefix.
            guard SessionStore.isValidName(prefix + "0") else {
                fail("group prefix \(prefix.debugDescription) is not allowed")
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { fail("socket(): \(String(cString: strerror(errno)))") }
        defer { Darwin.close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else {
            fail("socket path is too long: \(socketPath)")
        }
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
            fail("""
                cannot reach meshyyd at \(socketPath): \(String(cString: strerror(errno)))
                Is it running? Start it with: meshyyd serve
                """)
        }
        silenceSIGPIPE(on: fd)

        // A dedicated control frame rather than a real attach: this process wants
        // the handshake, not the session's byte stream.
        switch target {
        case .named(let session):
            write(fd, .control(.bootstrapRequest(session: session)))
        case .newInGroup(let prefix):
            write(fd, .control(.bootstrapNewInGroup(prefix: prefix)))
        }

        var decoder = FrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 65536) }
            if count == 0 { fail("meshyyd closed the connection without answering") }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                fail("read(): \(String(cString: strerror(errno)))")
            }
            let frames: [FrameEnvelope]
            do {
                frames = try decoder.push(Array(buffer[0..<count]))
            } catch {
                fail("protocol error: \(error)")
            }
            for frame in frames where frame.kind == .control {
                guard let control = try? ControlFrame.decode(frame.payload) else { continue }
                switch control {
                case .bootstrapResponse(let json):
                    // Straight through, already encoded by the daemon — so the
                    // bytes the client parses are the bytes the daemon produced,
                    // with no chance of a re-encode changing them.
                    print(json)
                    fflush(stdout)
                    exit(0)
                case .error(let code, let message):
                    fail("meshyyd refused the bootstrap (\(code)): \(message)")
                default:
                    continue
                }
            }
        }
        fail("meshyyd did not answer within 10s")
    }

    private static func write(_ fd: Int32, _ envelope: FrameEnvelope) {
        let bytes = envelope.encoded
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress, $0.count)
            }
            if written > 0 { offset += written; continue }
            if errno == EINTR || errno == EAGAIN { continue }
            fail("write(): \(String(cString: strerror(errno)))")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("meshyyd: \(message)\n".utf8))
        exit(1)
    }
}
