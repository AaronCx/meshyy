# Open: closing a session with a foreground job leaks a zombie

**Status: REAL, REPRODUCIBLE, NOT FIXED.** Found by the 2026-08-04 stress sweep
(54/54 leaks there), reproduced independently at 12/12, and still 12/12 after
four separate attempts at a fix. Written down rather than left as a half-claim.

## Reproduce

    # scratch daemon, never the user's
    .build/debug/meshyyd serve --socket /tmp/z/d.sock &
    # attach a client on a real pty, run a FOREGROUND job, then kill the session
    #   (scratchpad/zombie2.py in the 2026-08-04 session does exactly this)
    meshyyd attach --session zj0 --socket /tmp/z/d.sock   # then type: sleep 900
    meshyyd kill zj0 --socket /tmp/z/d.sock
    ps -eo ppid,stat,command | grep <daemon-pid>          # -> Z <defunct>

Idle sessions close cleanly; only a session with a foreground job leaks. The
zombie is the session's own shell, and it is never reaped afterwards — one per
closed session for the daemon's lifetime.

## What is known

- `PTYSession.close()` cancels the exit watcher BEFORE `pty.terminate()`, so
  `terminate` is the only thing that can reap. When its bounded loops give up,
  nothing ever waits again.
- Inside `terminate`, `waitpid(childPID, …, WNOHANG)` returns **0** for a full
  two seconds after SIGKILL — the child has not become a zombie yet. It does
  become one a few seconds later, i.e. after `terminate` has returned.
- That is the signature of a child parked mid-exit (`P_WEXIT`) because its
  controlling terminal is still open somewhere. The daemon's own slave is
  released before the signals, so the holder is something else.
- Job control is a strong suspect and was addressed without effect: with a ctty,
  a job-control shell puts each foreground job in its OWN process group, so
  `kill(-childPID, …)` misses the job entirely. `terminate` now signals every
  process group in the session tree — correct in its own right, but the leak
  persists, so the job's group was not the whole story.

## Attempts that did NOT fix it (all kept, all defensible on their own)

1. Blocking `waitpid` after SIGKILL — replaced with a bounded loop, because a
   blocking wait on the store's actor would wedge every session.
2. Widening the post-SIGKILL reap budget to 2s.
3. Making the SIGKILL escalation unconditional. The old guard
   `kill(-childPID, 0) == 0` is provably wrong — a group whose leader is exiting
   answers EPERM, so the guard read "already gone" and the SIGKILL never fired.
4. Signalling every process group in the session tree rather than only the
   shell's.

## Where to look next

- Find who still holds the slave when the shell is mid-exit: `lsof /dev/ttysNNN`
  at the moment `terminate` is spinning, from outside the daemon.
- Check whether the CLIENT's `SessionAttachment` teardown, or another session's
  child, inherited this pty's slave (`POSIX_SPAWN_CLOEXEC_DEFAULT` should
  prevent that — verify it actually does under the trampoline, which re-opens
  fds after exec and therefore after the CLOEXEC decision).
- That last point is the most promising: the trampoline opens the slave *after*
  exec, so those descriptors are NOT covered by `POSIX_SPAWN_CLOEXEC_DEFAULT`
  and may be inherited by every subsequent grandchild.
