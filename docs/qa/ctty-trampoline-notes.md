# The controlling terminal, and how to re-verify it

## The property

A session's child must own its pty as a **controlling terminal**, or `/dev/tty`
fails inside every meshyy session — which breaks `sudo`, ssh password prompts,
`read -s`, and vim's shell escapes. Over plain SSH none of this appears, because
sshd does the ctty dance itself, so it reads as "meshyy is broken".

## Why the obvious test is not enough

`posix_spawn_file_actions_addopen(&fileActions, 0, slavePath, …)` on a
`POSIX_SPAWN_SETSID` child DOES confer a ctty — **in an ordinary process**. An
in-process `PTY` therefore passes `ControllingTerminalTests` whether or not the
trampoline is present, so those tests are an ordinary regression guard, not the
proof.

The property broke only under **launchd**, where the daemon's own process has no
session (`ps -o sess` reports `0`). That is the environment meshyyd actually runs
in, and it is the one no unit test reproduces.

## How to re-verify (do this before ever removing the trampoline)

    # Same binary, thrown-away LaunchAgent, real launchd context.
    mkdir -p /tmp/mshy-ld && chmod 700 /tmp/mshy-ld
    cat > /tmp/mshy-ld/probe.plist <<'PLIST'
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
      <key>Label</key><string>com.aaroncx.meshyyd-probe</string>
      <key>ProgramArguments</key><array>
        <string>REPO/.build/debug/meshyyd</string><string>serve</string>
        <string>--socket</string><string>/tmp/mshy-ld/d.sock</string>
      </array>
      <key>RunAtLoad</key><true/>
    </dict></plist>
    PLIST
    launchctl bootstrap gui/$(id -u) /tmp/mshy-ld/probe.plist
    # then, in a session on that daemon:
    #   echo TTY-$( (echo p > /dev/tty) 2>&1 && echo OK || echo FAIL)-END
    launchctl bootout gui/$(id -u)/com.aaroncx.meshyyd-probe

Measured 2026-08-01, identical binary both ways:

| context | trampoline | `/dev/tty` |
|---|---|---|
| in-process test | absent | OK |
| shell-launched daemon | absent | OK |
| **launchd daemon** | **absent** | **FAIL — device not configured** |
| **launchd daemon** | **present** | **OK** |

## The trampoline, and the one thing it costs

`/bin/sh -c 'exec <"$0" >"$0" 2>"$0" || exit 125; prog="$1"; shift; exec "$prog" "$@"'`
with the slave path and the real program as positional argv — a fixed script, no
interpolation, so design doc §8 still holds. The child re-opens its own slave
AFTER exec, when it is unambiguously a session leader.

**The cost, and it is not obvious.** A child that holds a ctty cannot finish
exiting while the daemon keeps the slave open — it parks midway (`ps` shows `E`
and a parenthesised name) with `p_stat` still `SRUN`, so `waitpid` answers 0
forever and every dead session would report itself alive. Two consequences, both
handled:

- `PTY.reap()` releases the slave before waiting. Order matters: callers reach it
  after the final drain, so a short-lived child's last output is still preserved
  (the reason the slave is held at all — see `slaveFD`).
- `PTY.isChildAlive` checks `P_WEXIT` as well as `SZOMB`, because neither
  `waitpid` nor `p_stat` distinguishes this state from a running child. It is a
  read with no side effects: it must never release the slave itself, since the
  output that slave protects may not have been read yet.

A missing executable is also checked with `access(X_OK)` before spawning, because
the trampoline means `posix_spawn` now succeeds against `/bin/sh` regardless.
