# The controlling-terminal gap (unfinished — do not ship as-is)

## What is wrong today

A session's child has **no controlling terminal**. Measured on a live daemon:

    $ echo probe > /dev/tty
    zsh: device not configured: /dev/tty
    $ ps -o pid,pgid,tpgid,stat,tty -p <child>
      PID  PGID TPGID STAT TTY
    66034 66034     0 Ss   ??        <- no tty, TPGID 0

The file action `posix_spawn_file_actions_addopen(&fileActions, 0, slavePath, …)`
does NOT confer a controlling terminal on Darwin, despite the header comment in
`PTY.init` claiming it does. Anything that opens `/dev/tty` therefore fails
inside every meshyy session: `sudo`, an ssh password prompt, `read -s`, vim's
shell escapes, and zellij's input thread. It also means the pty's foreground-group
bookkeeping names nobody, which is the second reason the resize saga was so hard
to see (fixed independently by tree-wide signal delivery).

Over plain SSH none of this appears — sshd does the ctty dance itself.

## The approach on this branch, and why it is not merged

`/bin/sh -c 'exec <"$0" >"$0" 2>"$0" || exit 125; prog="$1"; shift; exec "$prog" "$@"'`
with the slave path and the real program as positional argv (no interpolation, so
§8 still holds). The child re-opens its own slave AFTER exec, when it is
unambiguously a session leader, which is when Darwin grants the ctty. Verified:
`/dev/tty` works, `ps` shows `ttysNNN` and `Ss+`, TPGID names the foreground job.

**Two regressions it introduces, both real and both unfixed here:**

1. `PTYTests.spawningNonexistentExecutableThrows` — `posix_spawn` now always
   succeeds because it spawns `/bin/sh`; a missing program becomes a runtime
   `exit 125` instead of a thrown error, so the daemon would create a session
   around a dead child rather than reporting the failure. Needs an explicit
   `access(executable, X_OK)` check before spawning.
2. `PTYTests.childExitIsObservable` — a short-lived child (`/bin/echo done`) is no
   longer seen to exit within 5s. Cause not yet established; suspect the extra
   `exec` layer changes what `waitpid`/the process source observe. **Diagnose
   before trusting anything else on this branch.**

Both suites pass with the trampoline removed, which is how `main` ships today.

## Next steps

- Add the executable-existence check, then re-run `PTYTests` in full.
- Instrument the child-exit path (does the process source fire? does `reap()`
  return?) rather than guessing.
- Add a regression test asserting `/dev/tty` is usable inside a session — that is
  the property this whole branch exists for, and nothing tests it today.
