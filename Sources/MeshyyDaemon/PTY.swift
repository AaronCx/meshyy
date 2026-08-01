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

    /// The daemon's own slave descriptor, held for the session's lifetime.
    ///
    /// Not an oversight. If the daemon releases it, then when the child exits the
    /// last slave closes, and on Darwin a read on the master returns EIO and
    /// **discards whatever was still buffered**. A command that prints and exits
    /// immediately loses its output — a shell's parting "logout", a script's last
    /// line, the error message from something that died on startup.
    ///
    /// Found by CI: the test for a short-lived child passed locally on timing and
    /// failed on a slower runner with an empty read.
    ///
    /// The cost is that end of file never arrives on the master, so child exit is
    /// detected with waitpid instead (see `hasChildExited`, and the process source
    /// in `PTYSession`). That is the right signal anyway: it carries the exit
    /// status, which EOF does not.
    private let slaveFD: Int32

    private var closed = false
    /// True once `waitpid` has reaped the child.
    ///
    /// **Load-bearing.** Once a child is reaped its pid is free for the OS to
    /// reuse, so signalling it afterwards can hit an unrelated process — and
    /// because `terminate()` signals the process *group* (`kill(-pid, …)`), the
    /// blast radius is a whole group that has nothing to do with meshyy.
    ///
    /// Found by a test run that exited non-zero with every assertion passing: the
    /// test process was killing itself. It only appeared once sessions used a
    /// `sh -c 'stty …; exec cat'` child, because that forks an extra process per
    /// session and churns pids fast enough for reuse to happen inside one run.
    private var reaped = false

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
        size: TerminalSize = .default,
        rawMode: Bool = false
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
        // documented. This is what makes design doc §7.1 work at all: `tcgetattr`
        // on the master is only meaningful while some slave fd exists.
        //
        // The descriptor is kept for the session's lifetime; see `slaveFD`.
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

        // Raw mode, applied before the child exists so there is no window in which
        // it runs in cooked mode.
        //
        // Exists so a session can be a transparent byte pipe — `cat` with no line
        // discipline in the way. The alternative, `sh -c 'stty raw; exec cat'`, forks
        // an extra process per session; churning pids that fast turned an unrelated
        // pid-reuse hazard in `terminate()` into an intermittent crash. One process
        // per session is worth a few lines here.
        if rawMode {
            var settings = Darwin.termios()
            if tcgetattr(master, &settings) == 0 {
                cfmakeraw(&settings)
                tcsetattr(master, TCSANOW, &settings)
            }
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

        // CLOEXEC_DEFAULT: the child gets ONLY what the file actions grant — the
        // slave as stdin/out/err — and nothing else from this process's table.
        // Without it, every descriptor the daemon holds is inherited by every
        // shell it spawns: the listeners, the other sessions' PTYs, and — the part
        // that bit — every live client socket. A client that vanished could then
        // never be detected, because its socket stayed open inside a shell child
        // and EOF never arrived; the attachment count read 1 forever, and the
        // session could never be offered back as detached. A child holding other
        // clients' connection fds is also exactly the leak §8's "most
        // security-sensitive thing in either project" must not have.
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )

        var pid: pid_t = 0
        // A TRAMPOLINE, because the file-action open does not make the pty the
        // child's CONTROLLING terminal on Darwin — measured: children ran with no
        // ctty at all, so `/dev/tty` answered "device not configured" inside every
        // session, which kills anything that opens it (zellij's input thread, sudo,
        // `read -s`, ssh password prompts), and the tty's job-control bookkeeping
        // was never trustworthy (the black-space saga). Controlling-terminal
        // acquisition happens in open(2), for a session leader, from ordinary
        // process context — so the child re-opens its own slave AFTER exec, when it
        // is unambiguously a session leader, and then execs the real program over
        // itself. No extra process at steady state.
        //
        // §8 compliance: the script is a FIXED string; the slave path, program and
        // its arguments all travel as positional argv, never interpolated.
        let trampoline = #"exec <"$0" >"$0" 2>"$0" || exit 125; prog="$1"; shift; exec "$prog" "$@""#
        let argv = ["/bin/sh", "-c", trampoline, slavePath, executable] + arguments
        let status = withCStringArray(argv) { argvPointers in
            withCStringArray(environment.map { "\($0.key)=\($0.value)" }) { envPointers in
                posix_spawn(&pid, "/bin/sh", &fileActions, &attributes, argvPointers, envPointers)
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

        self.masterFD = master
        self.slaveFD = slave
        self.childPID = pid
        self.slavePath = slavePath
    }

    deinit {
        if !closed {
            close(slaveFD)
            close(masterFD)
        }
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
        // EIO means every slave descriptor is gone. While this object holds one
        // that cannot happen, so reaching here means `terminate()` ran — treat it
        // as end of file rather than a fault.
        if errno == EIO { return nil }
        if errno == EAGAIN || errno == EINTR { return [] }
        throw PTYError.openFailed(errno: errno)
    }

    /// Writes what the PTY will accept right now and returns how much that was.
    /// **Never blocks and never loops.**
    ///
    /// The previous version looped until the whole buffer was accepted, sleeping on
    /// EAGAIN. That deadlocks, and not subtly: a PTY's input buffer is a few KiB, so
    /// any larger write — a paste, a here-doc, a `ResumeTooOld` probe — fills it and
    /// waits for the child to drain. But the caller is the session actor, and the
    /// same actor runs the read loop that drains the child's *output*. So the child
    /// blocks writing stdout, therefore stops reading stdin, therefore the write
    /// never completes. The session hangs permanently at 100% CPU.
    ///
    /// Measured: a 12 KiB write against a 512-byte ring buffer span 52 s at 159% CPU
    /// and never finished. No test wrote more than a few hundred bytes at a time
    /// before, which is why it stayed hidden.
    ///
    /// Callers must therefore handle a partial write — `PTYSession` queues the
    /// remainder and flushes it from a write source.
    @discardableResult
    public func writeSome(_ bytes: [UInt8]) throws -> Int {
        guard !bytes.isEmpty else { return 0 }
        let written = bytes.withUnsafeBytes { pointer in
            Darwin.write(masterFD, pointer.baseAddress, pointer.count)
        }
        if written >= 0 { return written }
        if errno == EAGAIN || errno == EINTR { return 0 }
        throw PTYError.openFailed(errno: errno)
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

    /// Applies the size and makes the foreground program re-read it, whether or not
    /// the size changed.
    ///
    /// **Why this is not the same as `resize`, and why the warning above does not
    /// apply here.** The kernel sends SIGWINCH on TIOCSWINSZ only when the size
    /// actually CHANGES. That is right for a live resize and wrong for an attach,
    /// because a full-screen program can be out of sync with a PTY that is already the
    /// correct size — and then the correct size is, by construction, a no-op. Nothing
    /// can ever fix it: the client sends the right number, the daemon applies the right
    /// number, the kernel correctly does nothing, and the program stays wrong forever.
    ///
    /// Measured on a real session: the PTY was 74x64 and tmux was still drawing 74x39,
    /// hours later, with the phone re-sending 74x64 on every attach. Re-applying an
    /// unchanged size was verified to produce no signal at all.
    ///
    /// So an attach signals explicitly. A duplicate SIGWINCH costs a redraw; a missing
    /// one costs a terminal that never fills the screen again.
    public func resyncSize(to size: TerminalSize) throws {
        var current = winsize()
        let changed = !(ioctl(masterFD, TIOCGWINSZ, &current) == 0
            && current.ws_row == UInt16(size.rows)
            && current.ws_col == UInt16(size.cols))

        try Self.applySize(size, to: masterFD)

        // The kernel's own WINCH-on-change is necessary but NOT sufficient: it goes
        // to the tty's foreground group, and under a job-control shell the program
        // that draws is often not in it. Measured on a live session: zsh put the
        // tmux client in its own process group, the tty's foreground group named
        // nobody useful, and every resize the phone sent was applied to the kernel
        // and heard by no one — a terminal that keeps drawing at the old height,
        // black below, unrecoverable for as long as the session lives. Signalling
        // the group `tcgetpgrp` names had the same blind spot (that is where it was
        // read from). A WINCH aimed at the tmux client's own group repaired the
        // screen instantly.
        //
        // So the daemon delivers the event to EVERY process group in the session's
        // tree — the one thing it can enumerate that the tty cannot lie about. The
        // set is tiny (the shell and its foreground job; a multiplexer SERVER
        // daemonizes out of the tree and resizes its own panes). The tty's
        // foreground group is included when it names anyone, minus the change case
        // the kernel already covered; a duplicate delivery coalesces, a missing one
        // is this whole bug.
        var groups = sessionProcessGroups()
        // From the MASTER. `tcgetpgrp` on the slave fails with ENOTTY on Darwin —
        // measured, same family of master/slave asymmetry as the note in `init`.
        let foreground = tcgetpgrp(masterFD)
        if foreground > 0 {
            if changed { groups.remove(foreground) } else { groups.insert(foreground) }
        }
        for group in groups {
            _ = killpg(group, SIGWINCH)
        }
    }

    /// Every distinct process group among the child and its live descendants, read
    /// from the kernel's process table. `sysctl(KERN_PROC_ALL)` rather than libproc
    /// so it stays on documented syscalls; one call per resize, and resizes happen
    /// at keyboard-toggle cadence.
    private func sessionProcessGroups() -> Set<pid_t> {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&name, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        size += size / 4   // headroom: the table can grow between the two calls
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 1
        var table = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        guard sysctl(&name, 4, &table, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride

        var childrenOf: [pid_t: [Int]] = [:]
        for index in 0..<count {
            childrenOf[table[index].kp_eproc.e_ppid, default: []].append(index)
        }

        var groups: Set<pid_t> = [childPID]   // the child leads its own group (SETSID)
        var queue: [pid_t] = [childPID]
        var visited: Set<pid_t> = []
        while let pid = queue.popLast() {
            guard visited.insert(pid).inserted else { continue }
            for index in childrenOf[pid] ?? [] {
                let entry = table[index]
                if entry.kp_eproc.e_pgid > 0 { groups.insert(entry.kp_eproc.e_pgid) }
                queue.append(entry.kp_proc.p_pid)
            }
        }
        return groups
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
    ///
    /// This, not end of file on the master, is how session exit is detected —
    /// see the note on `slaveFD`.
    public var isChildAlive: Bool {
        var status: Int32 = 0
        return waitpid(childPID, &status, WNOHANG) == 0
    }

    /// The child's exit status once it has exited, else nil.
    public var hasChildExited: Bool { !isChildAlive }

    /// Reaps the child if it has exited, returning its exit status.
    ///
    /// Records the reap, because from this point the pid must never be signalled
    /// again — see `reaped`.
    public func reap() -> Int32? {
        guard !reaped else { return nil }
        var status: Int32 = 0
        guard waitpid(childPID, &status, WNOHANG) == childPID else { return nil }
        reaped = true
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

        // Signal ONLY while the pid is still ours. Once reaped, the kernel may have
        // handed that pid to someone else, and `kill(-pid, …)` would take out an
        // unrelated process group. Skipping the signal is safe: a reaped child is
        // already gone, and anything it spawned was orphaned when it died.
        if !reaped {
            kill(-childPID, SIGHUP)

            // SIGHUP is a request. A process is entitled to ignore it, and some do —
            // so escalate rather than assume, or `close(session)` becomes a polite
            // suggestion that leaks processes.
            let deadline = Date().addingTimeInterval(gracePeriod.timeInterval)
            while Date() < deadline {
                if kill(-childPID, 0) != 0 && errno == ESRCH { break }
                usleep(10_000)
            }
            // Re-check `reaped`: the process source may have reaped concurrently
            // while this loop was sleeping.
            if !reaped, kill(-childPID, 0) == 0 {
                kill(-childPID, SIGKILL)
            }

            // Reap so the child does not sit as a zombie for the daemon's lifetime.
            var status: Int32 = 0
            if waitpid(childPID, &status, WNOHANG) == childPID { reaped = true }
        }

        close(slaveFD)
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
