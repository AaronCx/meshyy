# M0 spike (unplanned): what the kernel line discipline actually looks like

**Date:** 2026-07-27
**Question:** none — this was not on the M0 list. It came out of a PTY test that
failed for the wrong reason, and it invalidates half of design doc §7.3.

**Finding: every interactive shell holds the tty in RAW mode. Under the §7.2
gate, predictive echo would never engage — not in an agent TUI, and not at a bare
shell prompt either.**

---

## What §7 assumes

Design doc §7.1 is built on a real insight: the daemon owns the PTY, so it can
call `tcgetattr` and *know* whether the kernel will echo a keystroke, instead of
inferring it from the output stream the way a drop-in SSH replacement must.

§7.2 turns that into a gate. Predict only when all of:

- `echo == true`
- `icanon == true`
- `alt == false`
- smoothed RTT above the threshold

§7.3 then sets the expectation:

> Agent TUIs run in raw mode with alt-screen. Under the rules above, prediction
> will be **off** during a Claude Code session and **on** at a bare shell prompt.

The first half is right. The second half is wrong.

## Measurement

Spawned each program on a fresh PTY, let it initialise, then read `c_lflag` on
the master fd. `docs/spikes` has the harness; it is eight lines of `posix_spawn`
plus a `tcgetattr`.

| Program | ECHO | ICANON | §7.2 gate |
|---|---|---|---|
| `/bin/sh` (bash 3.2, readline) | false | false | **NO** |
| `bash -i` | false | false | **NO** |
| `zsh -i` | false | false | **NO** |
| `zsh -f -i` (no rc files) | false | false | **NO** |
| `tmux attach` | false | false | **NO** |
| `cat` | true | true | YES |
| `sed -u` | true | true | YES |

## Why

Readline and zle are line editors. They implement their own cursor movement,
history, completion, and syntax highlighting, which means they must see every
keystroke as it arrives and control exactly what appears on screen. So the first
thing either does is take the terminal out of cooked mode and echo characters
itself.

The echo a user sees at a shell prompt is **not** kernel echo. It is the shell
drawing characters. `ECHO` in `c_lflag` has been off the entire time.

This is not a macOS quirk, a bash-3.2 quirk, or an rc-file quirk — `zsh -f`
skips every rc file and behaves identically. It is what a line editor is.

## Consequences

1. **§7.3's expectation is wrong in a way that matters.** Prediction is off in an
   agent TUI *and* off at a shell prompt. The only programs that leave cooked
   mode on are ones that do no input handling, and nobody types interactively
   into `cat`.

2. **M6, exactly as specified, would ship dead code.** The doc already says
   "build it anyway if you want it, but build it last, and know what you are
   buying." The honest correction: under the §7.2 gate you are buying nothing at
   all, in any configuration a+Terminal will ever be used in. Not a small win —
   zero.

3. **§7.1's mechanism still works. What it reports is just always "no".** The
   daemon does read the line discipline correctly, and
   `PTYTests.termiosOnMasterReflectsChildChanges` proves a child's `tcsetattr` is
   visible on the master within one poll interval. The information is accurate
   and useless, which is worth separating: the *capability* is real, the
   *inference from it* was wrong.

4. **The "better than mosh" claim in §7 does not survive this.** §7.1 argues
   meshyy improves on mosh by not having to guess. But the thing that has to be
   predicted is the *shell's* echo, not the kernel's, and the shell does not
   publish its intentions. Predicting readline's behaviour means inferring from
   the output stream — which is what mosh does, and where its complexity lives.
   Owning both ends does not help, because the line editor is on neither end.

## What to do instead

**Decided: replace §7 with quick actions.** Aaron's call on being shown the table
above — "if the goal was reducing felt latency in the agent workflow, the answer
was never per-keystroke prediction."

The options I put up were: drop M6; re-scope prediction against the line editor
via bracketed-paste mode; or ship the raw-mode fact as a UI indicator. All three
missed the better answer, which is that **the latency was mis-targeted, not just
unreachable**.

Prediction hides one round trip of echo while typing a command. The interaction
that actually recurs on a phone is *answering an agent* — approve this tool call,
deny it, pick option 2 of 3 — and there the cost is the keyboard interaction:
finding the key on a software keyboard, hitting it accurately, checking it landed.
That dwarfs the 60–120 ms prediction was trying to hide, and it happens dozens of
times a day.

So §7 is now **quick actions**: one-tap approve / deny / numeric buttons, driven
off `AgentProfile`, offered and withdrawn by the daemon on the control stream.
Zero typing, zero prediction.

It is strictly better than what it replaces on every axis that motivated §7:

- It works in raw mode with the alternate screen up — the exact case the §7.2
  gate rules out, and the case the product exists for.
- It removes a keyboard interaction rather than one RTT of echo.
- It needs no overlay, so it also retires the SwiftTerm render-layer work below.
- Agent identity stays data: a new agent is a profile entry, not code.

Two constraints came out of designing it, both security properties rather than
preferences, and both are in §7.3: the label and the bytes-to-send come from the
**local** profile and never from remote output (else a remote drawing a convincing
fake prompt gets a one-tap confused deputy), and the daemon never sends an
action's bytes without a tap.

The §7.3 evening with real mosh is no longer on the critical path. It would only
answer whether prediction is noticeable at Aaron's RTT, and prediction is no
longer the plan.

## Effect on M0's other conclusion

The SwiftTerm overlay spike concluded that a predicted-cell overlay is feasible
without a fork, with one piece of replicated font geometry as debt. That
conclusion stands, and is now **moot**: quick actions render in the key accessory
bar, which is ordinary UIKit, so there is no overlay, no shadow cell model, and no
replicated font metrics.

That retires the item design doc §7.4 called "the biggest unknown in the project"
by making it unnecessary rather than by solving it — and it means the replicated-
metrics debt and the proposed upstream SwiftTerm PR are both cancelled rather than
deferred.
