# Fixed: closing a session with a foreground job leaked a zombie

**Status: ROOT-CAUSED AND FIXED (2026-08-05).** Reproduced 12/12 before, 0/12
after, plus a regression test that fails on the old code. The four earlier
attempts all missed because they were aimed at the wrong object — see below,
which is the useful part of this document.

## The cause

Nothing was holding the pty *slave*. The daemon was holding the *master*, and
not reading it.

A session leader that exits while it owns a controlling terminal is held inside
the kernel's exit path until that terminal's **output queue** has drained. A
pty's output queue only drains when somebody reads the master. `PTYSession.close`
cancels its read source *before* calling `PTY.terminate`, so from that instant
nobody does.

So the sequence was:

1. `terminate` SIGHUPs every process group in the session.
2. zsh reaps the foreground job and writes its notice —
   `"zsh: hangup     sleep 900\r\n"`, exactly **27 bytes** — into the tty.
3. Nobody is reading the master, so those 27 bytes sit there.
4. zsh exits. It is the session leader, the queue is not empty, so it parks
   mid-exit: `ps` shows `?Es`, `p_flag & P_WEXIT` is set, `p_stat` is still
   `SRUN`, and `waitpid(WNOHANG)` answers **0** — indistinguishable from a
   running child.
5. Both reap loops spend their full budget (2.26 s) seeing nothing.
6. The **last line** of `terminate` closes the master. That hangs the tty up, the
   exit completes, and the child becomes a zombie **5 ms later** — measured, and
   uniform across runs. By then `terminate` has returned and `close` has already
   cancelled the exit watcher. Nothing ever waits again.

An idle session closed cleanly for exactly one reason: with no job to report
there was nothing in the queue, so there was nothing to wait for.

## The fix

`PTY.discardPendingOutput()` — read and throw away whatever the tty has queued,
called from inside both reap loops in `terminate`. Teardown has no output left to
protect (the slave is already released and `PTYSession.close` finishes every
subscriber stream immediately after), so discarding is correct *there and only
there*. The short-lived-child guarantee lives on the other path — `reap()` via
`childExited`, which drains into the buffer first — and is untouched.

A short last-chance reap loop after `close(masterFD)` covers the residue: closing
the master is the one thing that can free a child the drain could not, and
previously nothing waited after it.

Side benefit: `terminate` no longer burns its full budget. A session close went
from **2.27 s to 0.02 s** end to end, measured over 12 sessions.

### The second half: the drain created an orphan leak, and it had to be closed too

Fixing the park exposed a bug that had been unreachable behind it. `terminate`'s
grace loop used to `waitpid` the child, and its SIGKILL escalation was guarded on
`if !reaped`. That guard looked like caution and was in fact dead code: the child
could never be reaped inside the grace period, because it was parked on the
unread master. **The drain made it reachable.** The shell now reaps in ~10 ms,
`reaped` turns true, the escalation is skipped entirely — and anything that
IGNORES SIGHUP outlives its session and is reparented onto launchd.

Measured against the drain-only fix: 12 of 12 sessions running
`sh -c 'trap "" HUP; sleep 900'` left **24 live processes** behind (the `sh` and
its `sleep`), where the code *before* the drain had killed them. Zero zombies,
every zombie assertion green, one leak traded for another.

The fix is that the grace loop now **observes** the exit instead of reaping it —
`isChildGone` (`SZOMB || P_WEXIT`, no side effects) rather than `waitpid`. A
child that has exited and not been waited for keeps its pid, so the escalation
below can still safely signal its process group, and the reap happens in the
loop after the SIGKILL. The `if !reaped` guard is left exactly as it was; what
changed is that nothing sets `reaped` before the escalation any more.

Re-reading the process tree at escalation time is **not** an alternative: the
kernel revokes the controlling terminal when a session leader dies, so the
survivors report `ps -o tty` as `??` and a fresh scan finds nobody. Measured.

## Numbers

Every row is 12 sessions on a scratch daemon, each attached on a real pty with a
confirmed foreground job (a trial where the job failed to start is discarded —
without that check the harness silently measures idle sessions and reports a
clean bill).

| | zombies | orphaned processes | close time |
|---|---|---|---|
| **before**, foreground job | **12 / 12** | 0 | 2.27 s |
| **after**, foreground job | **0 / 12** | 0 | 0.02 s |
| drain only, SIGHUP-ignoring job | 0 / 12 | **24** | 0.02 s |
| **after**, SIGHUP-ignoring job | **0 / 12** | **0** | 0.02 s |
| after, idle sessions | 0 / 6 | 0 | 0.02 s |
| after, `yes` firehose job | 0 / 6 | 0 | 0.51 s |
| after, `vim` (alt screen) | 0 / 6 | 0 | 0.03 s |

## Regression test

`PTYTests.terminateReapsChildParkedOnUnreadTTY`. It uses a `trap ... HUP` child
that writes and exits rather than a real shell with a foreground job, because the
reproducer needs three things at once and silently drops to zero if any is
missing:

- the child must **write** during teardown,
- nothing must **read** the master while it does,
- the child must be the **session leader** holding the ctty.

Verified to fail 3/3 on the pre-fix `PTY.swift` and pass after. Note that a
hermetic `zsh -l` with no dotfiles reaps cleanly and does **not** reproduce — the
wild case depends on the rc files talking on the way out, which is why the test
does not use a shell.

`PTYTests.terminateKillsSighupProofChildAfterCleanExit` pins the second half: a
shell that exits immediately (so the grace loop takes the early exit that used to
reap) leaving a backgrounded child that ignores SIGHUP (`SIG_IGN` survives fork
and exec, so only the escalation can end it). Verified to fail against the
drain-only fix and pass after. Both tests are needed — the zombie test stays
green while the orphan leak is wide open, which is exactly how that leak got
introduced.

## What was ruled out, with evidence

- **A grandchild inheriting the slave** (the trampoline re-opens it after exec,
  so those fds escape `POSIX_SPAWN_CLOEXEC_DEFAULT`). This was the leading
  hypothesis. `lsof` on the slave path *while `terminate` was spinning* showed
  **nothing** holding it. It is a real property of the trampoline; it is not this
  bug.
- **The foreground job's own process group being missed by `kill(-childPID, …)`.**
  True, and worth fixing on its own — a job-control shell does put each job in
  its own group — but the leak reproduced 12/12 with the whole tree signalled.
- Blocking `waitpid`, a wider reap budget, and unconditional SIGKILL: all kept,
  all defensible, none of them the cause. A budget cannot help when the thing it
  is waiting for cannot happen until after the budget expires.

## Reproduce (if it ever comes back)

    # scratch daemon, never the user's
    .build/debug/meshyyd serve --socket /tmp/z/d.sock &
    # attach on a real pty, run a FOREGROUND job, then kill the session
    meshyyd attach --session zj0 --socket /tmp/z/d.sock   # then type: sleep 900
    meshyyd kill zj0 --socket /tmp/z/d.sock
    ps -eo ppid,stat,command | grep <daemon-pid>          # -> Z <defunct>

The diagnostic that actually settles it is not `lsof` but timing: log around
`close(masterFD)` at the end of `terminate`. If the child becomes reapable a few
milliseconds after that call, the tty queue is the thing holding it.
