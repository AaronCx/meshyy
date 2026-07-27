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

Three options, in the order I would take them.

**A. Drop M6.** Cheapest and, on this evidence, correct. It removes the
project's largest speculative surface, the SwiftTerm overlay work, and a whole
class of "why did the wrong character appear" bugs. §13 already lists
"prediction may never engage in the target workflow" as a known risk; this
promotes it from risk to fact. Design doc §10 already says M1–M5 is a coherent
shippable product.

**B. Re-scope prediction against the line editor, not the kernel.** Keep the
termios gate as a *necessary* condition (raw mode from a full-screen app is still
a hard no) and add shell-specific knowledge on top: bracketed-paste mode
(`ESC[?2004h`), which readline and zle both set, is a reliable signal that a line
editor is at a prompt and expects printable input to echo at the cursor. That is
inference, with the failure modes inference brings — but it is bounded inference
against two known programs rather than open-ended heuristics.

**C. Ship the fact, not the prediction.** The daemon knows the line discipline;
surface it. a+Terminal can show a subtle indicator when the remote is in raw mode
so a user who types into a wedged session understands why nothing echoes. Tiny,
honest, and it uses the §7.1 capability for something that actually pays off.

**Recommendation: A now, C as a cheap follow-up, B only if Aaron actually wants
prediction after the §7.3 evening with real mosh.** That evening is still worth
having — it answers whether prediction is *noticeable* at his RTT, which decides
whether B is worth its complexity. But it is no longer a question about meshyy's
design; it is a question about whether to take on mosh's.

## Effect on M0's other conclusion

The SwiftTerm overlay spike concluded that a predicted-cell overlay is feasible
without a fork, with one piece of replicated font geometry as debt. That
conclusion stands and is unaffected. It is also now **moot for M1–M5**, and if
option A is taken it is moot entirely — which retires the item design doc §7.4
called "the biggest unknown in the project" by making it unnecessary rather than
by solving it.
