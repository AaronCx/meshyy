// meshyy — pseudo-terminal ownership (design doc §4, §7.1).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// The daemon owns the PTY master. That single fact is what lets §7.1 read the
// line discipline with tcgetattr instead of inferring echo behaviour from the
// output stream, which is the one thing meshyy can do that a drop-in SSH
// replacement cannot.
//
// Spawning uses posix_spawn rather than fork+exec. Between fork and exec only
// async-signal-safe calls are legal, and this process is multithreaded (Network
// framework, Dispatch), so a fork-based spawn is a latent crash. posix_spawn
// with POSIX_SPAWN_SETSID plus a file action that opens the slave gets the same
// result — a session leader with the PTY as its controlling terminal — without
// the hazard.

import Darwin
import Foundation
import MeshyyCore

/// A PTY master with a child process on the other end.
public final class PTY {
    public enum PTYError: Error, CustomStringConvertible {
        case openFailed(errno: Int32)
        case grantFailed(errno: Int32)
        case unlockFailed(errno: Int32)
        case noSlavePath
        case spawnFailed(errno: Int32)
        case resizeFailed(errno: Int32)

        public var description: String {
            switch self {
            case .openFailed(let code): "pty: posix_openpt failed: \(Self.text(code))"
            case .grantFailed(let code): "pty: grantpt failed: \(Self.text(code))"
            case .unlockFailed(let code): "pty: unlockpt failed: \(Self.text(code))"
            case .noSlavePath: "pty: ptsname returned no path"
            case .spawnFailed(let code): "pty: posix_spawn failed: \(Self.text(code))"
            case .resizeFailed(let code): "pty: TIOCSWINSZ failed: \(Self.text(code))"
            }
        }

        private static func text(_ code: Int32) -> String {
            String(cString: strerror(code)) + " (errno \(code))"
        }
    }

    /// The master file descriptor. Read PTY output from it, write keystrokes to it.
    public let masterFD: Int32
    public let childPID: pid_t
    public let slavePath: String

    private var closed = false

    /// Opens a PTY and spawns `executable` on the slave side as a session leader
    /// with the PTY as its controlling terminal.
    ///
    /// `environment` is passed verbatim as the child's entire environment.
    /// Design doc §8 requires explicit argv everywhere and no shell
    /// interpolation, so there is deliberately no variant of this that takes a
    /// command string.
    public init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String? = nil,
        size: TerminalSize = .default
    ) throws {
        // O_NOCTTY: the *daemon* must not acquire this as its controlling
        // terminal. Only the child should.
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw PTYError.openFailed(errno: errno) }

        guard grantpt(master) == 0 else {
            close(master)
            throw PTYError.grantFailed(errno: errno)
        }
        guard unlockpt(master) == 0 else {
            close(master)
            throw PTYError.unlockFailed(errno: errno)
        }
        guard let slaveCString = ptsname(master) else {
            close(master)
            throw PTYError.noSlavePath
        }
        let slavePath = String(cString: slaveCString)

        // On Darwin the master fd rejects every termios and winsize ioctl with
        // ENOTTY until the slave has been opened at least once — measured, not
        // documented. So the slave is opened here, before the size is set, and
        // released after the spawn once the child holds its own descriptor.
        //
        // This is what makes design doc §7.1 work at all: `tcgetattr` on the
        // master is only meaningful while some slave fd exists.
        let slave = open(slavePath, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            close(master)
            throw PTYError.openFailed(errno: errno)
        }

        // Size must be set before the child starts, or a full-screen program can
        // read 0x0 and draw nothing.
        do {
            try Self.applySize(size, to: master)
        } catch {
            close(slave)
            close(master)
            throw error
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // Opening a tty as a session leader with no controlling terminal, without
        // O_NOCTTY, makes it the controlling terminal. That is the whole trick:
        // it gives the child job control without a fork.
        posix_spawn_file_actions_addopen(&fileActions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 1)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 2)
        if let workingDirectory {
            posix_spawn_file_actions_addchdir(&fileActions, workingDirectory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // Reset every signal to its default disposition, and unblock everything,
        // before exec.
        //
        // This is not defensive tidiness. A disposition of SIG_IGN is inherited
        // across fork and exec, so if anything in the daemon's process — launchd,
        // Dispatch, a test harness — has ignored SIGHUP, every shell meshyyd
        // spawns inherits that, and `terminate()` below silently fails to kill
        // anything. The symptom is leaked `sleep`/`ssh`/build processes
        // accumulating for as long as the daemon runs, with nothing in the logs.
        //
        // Found by `PTYTests.terminateKillsGroup`, which passed as a standalone
        // binary and failed under the test harness for exactly this reason.
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)

        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)

        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )

        var pid: pid_t = 0
        let argv = [executable] + arguments
        let status = withCStringArray(argv) { argvPointers in
            withCStringArray(environment.map { "\($0.key)=\($0.value)" }) { envPointers in
                posix_spawn(&pid, executable, &fileActions, &attributes, argvPointers, envPointers)
            }
        }
        guard status == 0 else {
            close(slave)
            close(master)
            throw PTYError.spawnFailed(errno: status)
        }

        // Non-blocking, so `read` returns EAGAIN instead of parking a thread when
        // the child is quiet. The daemon drives reads from a DispatchSource and
        // must never block; the error handling in `read` already assumes this,
        // and without it a quiet shell hangs the caller forever.
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK)

        // posix_spawn on Darwin reports exec failures, so by the time it returns
        // successfully the child has run its file actions and exec'd — it holds
        // its own slave descriptor. Releasing ours now is what makes a read on
        // the master report end of file when the child later exits; holding it
        // would keep the tty alive forever and the read would simply block.
        close(slave)

        self.masterFD = master
        self.childPID = pid
        self.slavePath = slavePath
    }

    deinit {
        if !closed { close(masterFD) }
    }

    // MARK: - I/O

    /// Reads whatever is available. Returns nil at end of file, which for a PTY
    /// means the child has exited and closed the last slave fd.
    public func read(maximum: Int = 65536) throws -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: maximum)
        let count = buffer.withUnsafeMutableBytes { pointer in
            Darwin.read(masterFD, pointer.baseAddress, maximum)
        }
        if count > 0 { return Array(buffer[0..<count]) }
        if count == 0 { return nil }
        // On macOS, reading a master whose child has exited gives EIO rather
        // than 0. That is end of file, not a fault worth reporting.
        if errno == EIO { return nil }
        if errno == EAGAIN || errno == EINTR { return [] }
        throw PTYError.openFailed(errno: errno)
    }

    /// Writes keystrokes to the child. Loops until the whole buffer is accepted.
    public func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { pointer in
                Darwin.write(masterFD, pointer.baseAddress, pointer.count)
            }
            if written > 0 {
                offset += written
                continue
            }
            if errno == EINTR { continue }
            if errno == EAGAIN {
                // The master is non-blocking, so a full input buffer means the
                // child has not read yet. Retrying immediately would spin a core
                // until it does; a short yield costs nothing on a path that only
                // ever carries keystrokes and pasted text.
                usleep(1_000)
                continue
            }
            throw PTYError.openFailed(errno: errno)
        }
    }

    // MARK: - Size and line discipline

    public func resize(to size: TerminalSize) throws {
        try Self.applySize(size, to: masterFD)
        // SIGWINCH is what makes a running full-screen program redraw. The
        // kernel sends it to the foreground process group on TIOCSWINSZ, so
        // there is nothing to do here beyond the ioctl — but a bare ioctl with
        // no signal is a classic silent-resize bug, so this comment exists to
        // stop someone "fixing" it by adding a manual kill().
    }

    private static func applySize(_ size: TerminalSize, to fd: Int32) throws {
        var window = winsize(
            ws_row: UInt16(size.rows),
            ws_col: UInt16(size.cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard ioctl(fd, TIOCSWINSZ, &window) == 0 else {
            throw PTYError.resizeFailed(errno: errno)
        }
    }

    /// Reads the line discipline (design doc §7.1).
    ///
    /// Queried on the master fd. On Darwin the master and slave share one termios
    /// structure, so this reflects what the child's `tcsetattr` did — verified in
    /// `PTYTests.termiosOnMasterReflectsChildChanges`, because the design doc
    /// asserts it and an assertion is not a test.
    public func termios() -> TermiosState? {
        var settings = Darwin.termios()
        guard tcgetattr(masterFD, &settings) == 0 else { return nil }
        let echo = settings.c_lflag & UInt(ECHO) != 0
        let icanon = settings.c_lflag & UInt(ICANON) != 0
        return TermiosState(echo: echo, icanon: icanon, raw: !echo && !icanon)
    }

    // MARK: - Lifetime

    /// True while the child is still running.
    public var isChildAlive: Bool {
        var status: Int32 = 0
        return waitpid(childPID, &status, WNOHANG) == 0
    }

    /// Reaps the child if it has exited, returning its exit status.
    public func reap() -> Int32? {
        var status: Int32 = 0
        guard waitpid(childPID, &status, WNOHANG) == childPID else { return nil }
        return status
    }

    /// Ends the session: hangs up the child's process group, escalating to
    /// SIGKILL for anything that outlives the grace period, then closes the
    /// master.
    ///
    /// A negative pid signals the whole group, so a shell's own children die with
    /// it rather than being reparented to launchd and leaking. `POSIX_SPAWN_SETSID`
    /// makes the child a group leader, which is what makes the negative pid mean
    /// "this session and nothing else".
    public func terminate(gracePeriod: Duration = .milliseconds(250)) {
        guard !closed else { return }
        closed = true

        kill(-childPID, SIGHUP)

        // SIGHUP is a request. A process is entitled to ignore it, and some do —
        // so escalate rather than assume, or `close(session)` becomes a polite
        // suggestion that leaks processes.
        let deadline = Date().addingTimeInterval(gracePeriod.timeInterval)
        while Date() < deadline {
            if kill(-childPID, 0) != 0 && errno == ESRCH { break }
            usleep(10_000)
        }
        if kill(-childPID, 0) == 0 {
            kill(-childPID, SIGKILL)
        }

        // Reap so the child does not sit as a zombie for the daemon's lifetime.
        var status: Int32 = 0
        waitpid(childPID, &status, WNOHANG)

        close(masterFD)
    }
}

/// Builds a NULL-terminated `char *[]` for the duration of `body`.
///
/// Written out rather than using a convenience because posix_spawn needs the
/// pointers to stay valid across the call, and the obvious
/// `map { strdup($0) }` spelling leaks one allocation per element on every spawn.
private func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers where pointer != nil { free(pointer) } }
    return pointers.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress!)
    }
}
