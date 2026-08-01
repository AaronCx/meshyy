#!/usr/bin/env python3
# meshyy — manual verification that a resize reaches a zellij pane.
# Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
"""Does a resize reach zellij's PANE, under meshyy?

zellij ignores input from a scripted pty (verified: it does so with meshyy out
of the picture too), so this asks nothing of the pane. It watches the pane's own
pty size from OUTSIDE instead — when zellij hears a WINCH it re-sizes its panes,
which is a TIOCSWINSZ the process table can be asked about. That is the same
"count on the far side" discipline the rest of this project runs on.
"""
import os, pty, select, signal, struct, fcntl, termios, time, uuid, subprocess, sys

MESHYYD = os.environ.get("MESHYYD", os.path.expanduser("~/bin/meshyyd"))
SOCKET = os.environ.get("MESHYY_SOCKET", os.path.expanduser("~/.meshyy/meshyyd.sock"))
IDENT = "zjp-" + uuid.uuid4().hex[:8]


def sh(command):
    return subprocess.run(command, capture_output=True, text=True).stdout


def session_pty_size():
    """The daemon's own pty for this session, straight from the kernel — plus what
    the daemon says it recorded. If these disagree with the client, the resize
    never landed; if they agree and the pane still lags, the multiplexer did."""
    child = None
    for line in sh(["/bin/ps", "-eo", "pid,ppid,tty,command"]).splitlines():
        parts = line.split()
        if len(parts) > 3 and "zsh" in line and parts[2] not in ("??", "TTY"):
            # the session's shell: parent is meshyyd serve
            if any(f" {parts[1]} " in l and "meshyyd serve" in l
                   for l in sh(["/bin/ps", "-eo", "pid,command"]).splitlines()):
                child = parts[2]
    if child is None:
        return None
    size = sh(["/bin/stty", "-f", f"/dev/{child}", "size"]).split()
    return (int(size[0]), int(size[1])) if len(size) == 2 else None


def pane_tty_size():
    """The pty size of the shell zellij is running inside its pane."""
    server = None
    for line in sh(["/bin/ps", "-eo", "pid,command"]).splitlines():
        if "zellij --server" in line and IDENT in line:
            server = line.split()[0]
            break
    if server is None:
        return None, "no zellij server for this session"
    for line in sh(["/bin/ps", "-eo", "pid,ppid,tty,command"]).splitlines():
        parts = line.split()
        if len(parts) > 3 and parts[1] == server and parts[2] not in ("??", "TTY"):
            size = sh(["/bin/stty", "-f", f"/dev/{parts[2]}", "size"]).split()
            if len(size) == 2:
                return (int(size[0]), int(size[1])), f"pane pid {parts[0]} on {parts[2]}"
    return None, f"zellij server {server} has no pane with a tty yet"


pid, fd = pty.fork()
if pid == 0:
    os.execv(MESHYYD, [MESHYYD, "attach", "--session", f"zjprobe-{IDENT}", "--socket", SOCKET])
    os._exit(127)


def resize(cols, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    os.kill(pid, signal.SIGWINCH)


def drain(seconds):
    end = time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                if not os.read(fd, 65536):
                    break
            except OSError:
                break


try:
    resize(74, 64)
    drain(1.5)
    os.write(fd, f"/opt/homebrew/bin/zellij attach --create {IDENT}\n".encode())
    drain(5.0)

    start, note = pane_tty_size()
    print(f"start (terminal 74x64): pane pty = {start}   session pty = {session_pty_size()}   [{note}]")
    if start is None:
        sys.exit(1)

    resize(74, 39)
    time.sleep(2.5)
    short, _ = pane_tty_size()
    print(f"after shrink to 74x39:  pane pty = {short}   session pty = {session_pty_size()}")

    resize(74, 64)
    time.sleep(2.5)
    grown, _ = pane_tty_size()
    print(f"after grow back to 64:  pane pty = {grown}   session pty = {session_pty_size()}")

    if grown is not None and grown[0] != start[0]:
        # The grow did not land. Is the daemon failing to DELIVER, or is zellij
        # refusing to grow? Signal every group in the session's tree by hand and
        # look again: a repair here means delivery, not zellij.
        shell = sh(["/bin/ps", "-eo", "pid,ppid,command"])
        groups = set()
        for line in sh(["/bin/ps", "-eo", "pid,pgid,command"]).splitlines():
            if IDENT in line and "ps -eo" not in line:
                parts = line.split()
                groups.add(parts[1])
        print("manual WINCH to groups:", sorted(groups))
        for group in groups:
            subprocess.run(["/bin/kill", "-WINCH", f"-{group}"], capture_output=True)
        time.sleep(2.0)
        after, _ = pane_tty_size()
        print(f"after manual WINCH:     pane pty = {after}")

    ok = (short is not None and grown is not None
          and short[0] == start[0] - 25 and grown[0] == start[0])
    print("zellij:", "PASS — the pane tracked both directions" if ok else "FAIL")
    sys.exit(0 if ok else 1)
finally:
    try:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    except OSError:
        pass
    subprocess.run(["/opt/homebrew/bin/zellij", "kill-session", IDENT], capture_output=True)
    subprocess.run(["/opt/homebrew/bin/zellij", "delete-session", "--force", IDENT],
                   capture_output=True)
