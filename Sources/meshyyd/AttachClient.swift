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
    ///
    /// The point of this command is to make a persistence claim checkable. "Your
    /// session stays alive on the server" is unfalsifiable without it, and an
    /// unfalsifiable claim is indistinguishable from a false one — which is precisely
    /// how it was first reported.
    func list(json: Bool = false) async {
        guard connect() else { return }
        defer { Darwin.close(fd) }

        send(.control(.sessionListRequest))
        awaitList(timeoutSeconds: 5, json: json)
    }

    /// Waits for a session list and renders it — or, with `json`, prints the
    /// daemon's JSON verbatim, so the bytes a program parses are the bytes the
    /// daemon produced (the same pass-through rule as the bootstrap handshake).
    private func awaitList(timeoutSeconds: Double, json: Bool = false) {
        // The deadline below only gets re-checked between reads, and this fd is
        // blocking — against a daemon that never answers, `read` never returns and
        // the 5s failure was unreachable (same trap as Bootstrap.run; set here and
        // not in `connect()` because the interactive relay WANTS blocking reads).
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var decoder = FrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 65536) }
            if count <= 0 {
                if count < 0, errno == EINTR || errno == EAGAIN { usleep(5_000); continue }
                break
            }
            guard let frames = try? decoder.push(Array(buffer[0..<count])) else { break }
            for frame in frames where frame.kind == .control {
                guard let control = try? ControlFrame.decode(frame.payload) else { continue }
                if case .sessionListResponse(let payload) = control {
                    if json {
                        print(payload)
                        fflush(stdout)
                    } else {
                        render(payload)
                    }
                    exit(0)
                }
                if case .error(let code, let message) = control {
                    FileHandle.standardError.write(Data("meshyyd: \(code): \(message)\n".utf8))
                    exit(3)
                }
            }
        }
        FileHandle.standardError.write(Data("meshyyd: the daemon did not answer within 5s\n".utf8))
        exit(3)
    }

    /// `meshyyd kill NAME` — ends a session, then prints what is left.
    ///
    /// Shows the remaining list rather than reporting success, because "it worked" is
    /// exactly the kind of claim that let a pile of orphaned sessions go unnoticed.
    func kill() async {
        guard connect() else { return }
        defer { Darwin.close(fd) }
        send(.control(.sessionKillRequest(name: session)))
        awaitList(timeoutSeconds: 5)
    }

    /// Prints one line per session. `alive` is the column that matters: a session
    /// whose shell has died still exists, and saying "1 session" about it would be
    /// the same kind of unchecked claim this command exists to remove.
    private func render(_ json: String) {
        // schema 2 wraps the rows in an envelope; a pre-envelope serve sends the
        // bare array. This renderer reads both, because the CLI binary and the
        // running serve are upgraded at different moments on a real host.
        let parsed = json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let rows: [[String: Any]]
        if let envelope = parsed as? [String: Any],
           let sessions = envelope["sessions"] as? [[String: Any]] {
            rows = sessions
        } else if let bare = parsed as? [[String: Any]] {
            rows = bare
        } else {
            FileHandle.standardError.write(Data("meshyyd: unreadable session list\n".utf8))
            exit(3)
        }
        if rows.isEmpty {
            print("no sessions")
            return
        }
        // Padded in Swift rather than with `String(format:"%s")`: passing a Swift
        // String to a C `%s` conversion needs a manually-bridged C pointer and
        // segfaulted on the first real session, which is a poor way to learn that a
        // diagnostic command is itself broken.
        // Always at least one trailing space. Padding to a width a value already
        // exceeds returned it unchanged, which glued the next column onto it —
        // `aplus-<uuid>45683` — and made the output unparseable by anything, including
        // the person trying to clean up. A diagnostic command that cannot be read is
        // not one.
        func pad(_ value: String, _ width: Int) -> String {
            value.count >= width ? value + " " : value + String(repeating: " ", count: width - value.count)
        }

        print(
            pad("NAME", 30) + pad("PID", 9) + pad("BUFFERED", 11) + pad("SIZE", 9)
                + pad("CLIENTS", 9) + "STATE"
        )
        for row in rows {
            let name = row["name"] as? String ?? "?"
            let pid = row["child_pid"] as? Int ?? 0
            let from = (row["buffered_from"] as? NSNumber)?.uint64Value ?? 0
            let to = (row["buffered_to"] as? NSNumber)?.uint64Value ?? 0
            let cols = row["cols"] as? Int ?? 0
            let rowsN = row["rows"] as? Int ?? 0
            let alive = row["alive"] as? Bool ?? false
            // "?" rather than 0 against an older daemon: absent is not detached.
            let clients = (row["attached_clients"] as? Int).map(String.init) ?? "?"
            print(
                pad(name, 30)
                    + pad("\(pid)", 9)
                    + pad("\(to - from)B", 11)
                    + pad("\(cols)x\(rowsN)", 9)
                    + pad(clients, 9)
                    + (alive ? "alive" : "DEAD SHELL")
            )
        }
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
