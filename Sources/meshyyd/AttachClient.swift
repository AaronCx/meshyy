// meshyy — the local attach client (design doc M1 acceptance).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Puts the controlling terminal in raw mode, connects to the daemon's unix
// socket, and relays bytes. Deliberately dumb: no emulation, no prediction, no
// state. Everything interesting is on the far side, which is the point — if this
// gives a usable shell, the daemon and the protocol are correct.

import Darwin
import Foundation
import MeshyyCore
import MeshyyDaemon

final class AttachClient: @unchecked Sendable {
    private let socketPath: String
    private let session: String
    private var fd: Int32 = -1
    private var decoder = FrameDecoder()
    private var savedTermios: termios?

    init(socketPath: String, session: String) {
        self.socketPath = socketPath
        self.session = session
    }

    // MARK: - Attach

    func run() async {
        guard connect() else { return }
        defer { restoreTerminal() }

        let size = currentTerminalSize()
        // No token: the unix socket's 0600 permissions already proved the caller
        // is this user. See LocalSocketServer's header.
        send(.control(.hello(.init(
            token: "",
            cols: size.cols,
            rows: size.rows,
            session: session
        ))))

        makeTerminalRaw()
        installWindowChangeHandler()
        pumpStdin()
        await pumpSocket()
    }

    /// `meshyyd list` — attaches nothing, just asks and prints.
    func list() async {
        guard connect() else { return }
        // The daemon has no list frame yet; that is M2 work alongside the QUIC
        // control stream. Report the gap rather than printing an empty table that
        // reads as "no sessions".
        FileHandle.standardError.write(Data("""
            meshyyd: `list` is not implemented yet — the control protocol has no \
            session-enumeration frame until M2.
            The daemon is reachable at \(socketPath).

            """.utf8))
        Darwin.close(fd)
        exit(3)
    }

    // MARK: - Socket

    private func connect() -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            fail("socket() failed: \(String(cString: strerror(errno)))")
            return false
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else {
            fail("socket path is too long: \(socketPath)")
            return false
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
                Darwin.connect(descriptor, $0, size) == 0
            }
        }
        guard connected else {
            fail("""
                cannot reach meshyyd at \(socketPath): \(String(cString: strerror(errno)))
                Is it running? Start it with: meshyyd serve
                """)
            Darwin.close(descriptor)
            return false
        }
        // A daemon that goes away mid-write must not kill this process with
        // SIGPIPE; the write loops handle EPIPE instead.
        silenceSIGPIPE(on: descriptor)
        fd = descriptor
        return true
    }

    private func send(_ envelope: FrameEnvelope) {
        let bytes = envelope.encoded
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress, $0.count)
            }
            if written > 0 { offset += written; continue }
            if errno == EINTR || errno == EAGAIN { continue }
            return
        }
    }

    /// stdin -> socket, on its own thread. A blocking read is right here: this
    /// process has nothing else to do while waiting for a keystroke.
    private func pumpStdin() {
        let descriptor = fd
        Thread.detachNewThread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(0, $0.baseAddress, 4096)
                }
                guard count > 0 else {
                    if count < 0 && errno == EINTR { continue }
                    break
                }
                self?.send(.pty(0, Array(buffer[0..<count])))
                _ = descriptor
            }
        }
    }

    /// socket -> stdout.
    private func pumpSocket() async {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress, 65536)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            let frames: [FrameEnvelope]
            do {
                frames = try decoder.push(Array(buffer[0..<count]))
            } catch {
                fail("protocol error: \(error)")
                break
            }
            for frame in frames where !handle(frame) { return }
        }
    }

    /// Returns false when the session is over.
    private func handle(_ frame: FrameEnvelope) -> Bool {
        switch frame.kind {
        case .pty:
            var offset = 0
            let bytes = frame.payload
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes {
                    Darwin.write(1, $0.baseAddress, $0.count)
                }
                if written > 0 { offset += written; continue }
                if errno == EINTR || errno == EAGAIN { continue }
                break
            }
        case .control:
            guard let control = try? ControlFrame.decode(frame.payload) else { return true }
            switch control {
            case .bye(let reason):
                restoreTerminal()
                FileHandle.standardError.write(Data("\r\n[meshyy] \(reason)\r\n".utf8))
                return false
            case .error(let code, let message):
                restoreTerminal()
                FileHandle.standardError.write(Data("\r\n[meshyy] error \(code): \(message)\r\n".utf8))
                return false
            case .resumeTooOld(_, let earliest):
                // Design doc §3.5: fail visible. The screen was rebuilt, not
                // continued, and the user should know.
                FileHandle.standardError.write(
                    Data("\r\n[meshyy] scrollback gap; replayed from \(earliest)\r\n".utf8)
                )
            default:
                break
            }
        case .blob:
            break
        }
        return true
    }

    // MARK: - Terminal

    private func currentTerminalSize() -> TerminalSize {
        var window = winsize()
        guard ioctl(0, TIOCGWINSZ, &window) == 0, window.ws_col > 0 else {
            return .default
        }
        return TerminalSize(cols: Int(window.ws_col), rows: Int(window.ws_row))
    }

    /// Raw mode, so keystrokes reach the remote PTY unmangled and the local
    /// kernel does not echo them a second time.
    private func makeTerminalRaw() {
        var settings = termios()
        guard tcgetattr(0, &settings) == 0 else { return }
        savedTermios = settings
        cfmakeraw(&settings)
        // VMIN 1 / VTIME 0: return as soon as one byte is available, which is
        // what an interactive relay wants.
        settings.c_cc.16 = 1
        settings.c_cc.17 = 0
        tcsetattr(0, TCSANOW, &settings)
    }

    private func restoreTerminal() {
        guard var saved = savedTermios else { return }
        tcsetattr(0, TCSANOW, &saved)
        savedTermios = nil
    }

    /// A local window change has to be forwarded, or full-screen programs on the
    /// far side keep drawing at the old size.
    private func installWindowChangeHandler() {
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let size = self.currentTerminalSize()
            self.send(.control(.resize(cols: size.cols, rows: size.rows)))
        }
        source.resume()
        signal(SIGWINCH, SIG_IGN)
        // Retained by the closure for the process's lifetime, which is exactly as
        // long as it is needed.
        Self.windowChangeSource = source
    }

    private static nonisolated(unsafe) var windowChangeSource: DispatchSourceSignal?

    private func fail(_ message: String) {
        restoreTerminal()
        FileHandle.standardError.write(Data("meshyyd: \(message)\n".utf8))
        exit(1)
    }
}
