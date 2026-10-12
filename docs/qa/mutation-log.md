# Mutation log

Deliberate defects introduced to prove a test can fail. Per the hardening brief:
"A correctness test nobody has ever seen fail is not evidence."

Each entry records the mutation, what each CI mode saw, and what that proves.

---

## 2026-07-27 — 1a-bis: does CI see a client-side offset bug?

**Result: no. Both directions of an off-by-one merge green.**

Mutation site: `MeshyySession.deliver`, the one line that advances the client's
own view of how many bytes it has handed to the renderer.

```swift
consumedOffset += UInt64(bytes.count)        // correct
consumedOffset += UInt64(bytes.count) + 1    // mutant A — offset runs ahead
consumedOffset += UInt64(bytes.count) - 1    // mutant B — offset lags
```

Mutant A is the dangerous direction. A client whose offset runs ahead resumes
past bytes it never delivered, so those bytes are **silently lost** — the exact
failure the brief says gets blamed on the shell.

| | `make test-ci` (what CI runs) | `make test` (everything) |
|---|---|---|
| baseline | 127 pass, 0.67 s | 127 pass, 12.8 s |
| mutant A (+1, loses bytes) | **127 pass** | 1 failed |
| mutant B (−1, duplicates bytes) | **127 pass** | 1 failed |

**What this proves.** A byte-losing defect in the shipping client merges green
today. The §6.4 property test cannot see it: it asserts against `ClientModel`, a
separate reference implementation, so mutating the real client changes nothing it
looks at. The tests that do catch it are gated out of CI.

**A second finding, not asked for.** Only **one** test caught either mutant:
`offsetTracksDeliveredBytes`, which compares the client's offset against the
daemon's directly. In particular `reattachResumesExactly` — whose stated job is
"no duplicates" — **did not** catch mutant B, which duplicates bytes.

It counts occurrences of a marker string, so it only detects duplication that
happens to overlap that marker. It is positionally lucky, not robust. The
model-level property test compares whole byte arrays; the transport-level tests
compare substrings. That gap belongs in 1c-bis.

Reverted; `git diff` clean; full suite green again.

---

## 2026-07-27 — 1a-bis re-check, after ungating (1b-zero)

Same mutation, same command, after the transport suites were ungated and their
assertions made byte-exact.

| | before 1b-zero | after |
|---|---|---|
| mutant A (+1, loses bytes) | **CI green** | **7 failures** |

The byte-exact resume test reports it precisely: `delivered.count → 699` against
`before.count + away.count → 700`. **One lost byte, named.** Previously the same
defect produced no signal at all in CI, and the substring-based version of that
test could not see it even when run.

The gap 1a-bis was written to prove is closed.

---

## 2026-07-28 — 1b-bis acceptance: the pin holds

The acceptance criterion for hardening PR 1: after pinning `ClientModel` to
`MeshyySession`, a mutation in the shipping client's offset arithmetic must turn the
suite red.

Same mutant A (`consumedOffset += bytes.count + 1`), run against
`ConformanceTests` alone:

| | scenarios catching mutant A |
|---|---|
| before the pin | **0 of 200** |
| after the pin | **137 of 200** |

And the report is a reproduction rather than an alarm:

```
seed 1, step 21 (reconnect):
  reference delivered 4891 bytes
  shipping  delivered 4877 bytes
  first difference at byte 4679
  reference[4679...] = [48, 103, 101, 107, 32, 47, 76, 38, 113, 108, 97, 93, 87, 70, 35, 104]…
  shipping [4679...] = [35, 104, 54, 71, 114, 102, 99, 85, 86, 27, 91, 50, 74, 27, 91, 50]…
```

Seed, step index, step kind, both byte counts, the first differing offset, and a
window of each stream. The shipping client is 14 bytes short and the divergence
begins at byte 4679 — enough to go straight to the defect.

**Why 137 and not 200.** A scenario only catches this if it reconnects *after* the
drift has accumulated past a boundary that changes what the daemon replays. 63
scenarios either reconnect too early or resume inside a window where a one-byte
drift still lands on the same replay. That is the honest number, and it is worth
knowing: a single scenario would have been a coin flip, which is the argument for
keeping all 200 rather than sampling.

---

## 2026-07-28 — 1h: re-scored against abrupt disconnects

The milestone amendment asks for this directly: the 137-of-200 above was earned
entirely on graceful closes, so it says nothing about the disconnect users
actually get. The same corpus now runs a second way, with every reconnect
preceded by a truncation at a seed-derived byte offset — a link that stopped
mid-frame rather than one that said goodbye.

Four mutants, each scored as the number of the 200 seeds that turn red:

| mutant | graceful corpus | abrupt corpus |
|---|---|---|
| A `consumedOffset += count + 1` (offset runs ahead, loses bytes) | 137 | **189** |
| B `consumedOffset += count - 1` (offset lags, duplicates bytes) | 165 | **189** |
| C queued bytes dropped when the base arrives | **0** | **0** |
| D queue survives a reattach instead of being cleared | **0** | 2 |

**A moved 137 → 189, and that is the headline.** Truncation puts the resume
offset on a boundary that is not a frame boundary, so a one-byte drift changes
what the daemon replays far more often than it does on a clean seam. The 11
seeds that still survive reconnect too early for any drift to have accumulated.

**C survived both, and that is the finding worth more than the score.** PTY bytes
that arrive before the replay base are queued and flushed when it lands. Emptying
that queue at flush time — losing the first burst of the reconnect — was invisible
to 400 scenario-runs across both modes. `pty` and `control` ride separate QUIC
streams and QUIC orders bytes only *within* a stream, so the out-of-order arrival
is a real race, not a hypothetical: rare, load-dependent, and presenting as the
shell having said nothing. D, the mirror defect, was caught by 2 seeds, which is
close enough to luck to count as uncovered.

Neither is a defect in the shipping code. Both are defects the shipping tests
could not have seen. `ptyBeforeBaseIsQueuedNotLost` and
`staleQueueDoesNotSurviveReattach` in `AbruptLossTests` close them, and each was
confirmed to name its mutant before being kept:

```
C: RED -> "PTY bytes arriving before the replay base are queued, then delivered"
D: RED -> "A queue orphaned by an abrupt disconnect does not survive the reattach"
```

**On the harness's own first draft.** The amendment states the property
directionally — never resume past what was delivered — and this file asserted
exactly that to begin with. It failed 113 times against correct code, because
there *is* a licensed skip: on eviction the daemon states a higher replay base and
the client emits `screenRebuilt` carrying the range. The bytes are gone, but the
user is told. The invariant that holds is an equality over a balanced account:

```
consumedOffset == bytes delivered to the renderer + bytes reported as skipped
```

Stronger in both directions than the inequality, which would have waved through
every defect that makes the offset read *low* — mutant B among them.

Reverted after each run; `git diff` clean; full suite green at 142 tests.

---

## 2026-08-07 — daemon restart (audit PR 3)

**Mutant: accept an unknown QUIC token as a fresh session.** In
`SessionAttachment`'s `.bootstrapToken` authority, the redeem-failure path was
replaced with `attachOrCreate(name: hello.session ?? "mutant")` — the daemon
silently handing a fresh shell to a client whose token it has never seen,
which is exactly what a client reconnecting across a daemon restart would
receive as fake continuity.

```
RED -> "A restarted daemon refuses a stale QUIC token as unknown, not as an
        empty session" — both expectations fire: no refusal observed, and
        session bytes reached a client that should have received none.
```

The companion test pins the other half: re-bootstrapping a dead session's
NAME after a restart may mint a new session, but its `sessionID` must differ —
the id is the continuity claim a client can compare to turn "resuming" into
"your session is gone; this is a new one."

Reverted after the run; `git diff` clean; suite green.

---

## 2026-08-07 — heartbeat tick counter (audit PR 4)

**Mutant: bug #2 restored.** `startHeartbeat` was given back its original
early return — no redial provider, no probes — the exact defect that once
surfaced as "Reconnecting" flashes every few seconds and three unrelated-
looking symptoms.

```
RED in 2.06s -> "The heartbeat keeps ticking, counted in milliseconds not
                 symptoms" — "minted 0 probes in 2s at a 20ms interval —
                 it is not running, which is bug #2 by another name"
```

`QuietSessionSurvivalTests` stays exactly as it is: it asserts the session
SURVIVES, this asserts probes are GENERATED, and neither replaces the other —
the survival test can only notice this defect by waiting out the full idle
timeout; the counter names it in milliseconds.

Reverted after the run; `git diff` clean; suite green.

---

## 2026-10-11 — mode trace and inbound clock (scroll trace, PR A)

**Mutant 1: the pulse goes unrecorded.** `PTYSession.ingest` never sets
`transientMouseOff` (the disarm check short-circuited with `if false, …`).

```
RED in 10.06s -> "Arming, the alt screen, a redraw pulse and an attach are all
                 recorded" — "a disarm/re-arm pulse must be recorded as
                 transient, ending armed"
```

**Mutant 2: pongs stop counting.** `MeshyySession.attach` no longer stamps
`inboundStamp` in the frame callback.

```
RED in 1.16s -> "lastInboundFrameAt keeps moving on an idle session, carried by
                 pongs alone" — lastInboundFrameAt → nil
```

Both reverted after the run; `git diff` clean; suites green.

---

## 2026-10-11 — #63 one ordered lane, against the SSH oracle (scroll trace, PR B)

The brief: revert #63 and confirm the oracle suite goes red before trusting it.
Each mutant ran `swift test --filter 'ScrollOracle|WireLane'` three times on the
dev Mac, against tmux 3.6a.

**Mutant 1: #63's routing reverted.** `git show 71c0880 -- QUICServer.swift
MeshyyConnection.swift | git apply -R`. The client opens a stream per kind, so
the first keystroke opens a separate pty stream. The daemon binds its reply
stream per kind. `ChannelKind.wireLane` itself is left alone.

**Mutant 2: the one-line version.** `wireLane` returns `self`. Client and daemon
both route on it, so this is the same split, reached through the helper.

| test | mutant 1, runs 1/2/3 | mutant 2, runs 1/2/3 |
|---|---|---|
| `dismissAndSwipeStayOrdered` (row checker) | **red / red / red** | **red / red / red** |
| red seeds of 20 | 4, 6, 5 (**15/60**) | 4, 5, 4 (**13/60**) |
| `WireLaneTests.laneAssignment` | green / green / green | **red / red / red** |
| `swipeOutcomeMatchesTheOracle` (tmux, mouse on and off) | green / green / green | green / red* / green |
| `reorderedClientsMatchTheOracle` (tmux, mouse on and off) | green / green / green | green / green / green |

Red seeds, for replay:

- Mutant 1: {2, 12, 13, 16}, {4, 12, 13, 14, 17, 20}, {12, 13, 16, 18, 20}.
- Mutant 2: {2, 11, 13, 16}, {7, 8, 13, 16, 20}, {4, 8, 13, 14}.

Seed 13 was red in all six runs.

Every misordered seed failed the same way:

```
seed 13: ["20/18", "20/18", "20/18"]
the swipe overtook the keyboard-dismiss resize — the far side read a row-20
wheel event while the PTY was still 18 rows
```

The resize went on the control stream and the wheel bytes went on the pty
stream. The relay reordered datagrams, and the PTY received the swipe first.
The unmutated code scored 0/20 on this loop in each of its three acceptance
runs. Over ssh, every swipe read `20/24`.

Mutant 2's failure:

```
WireLaneTests.swift:24: (ChannelKind.pty.wireLane → .pty) == .control
```

**What this proves, and what it does not.**

- **The suite catches the revert.** It went red in 6 of 6 runs. One test does
  the catching: the row checker, a far-side program that applies a resize
  synchronously. The per-seed hit rate is about 23% (28/120). With 20 seeds
  per run, a mutant should rarely pass a whole run. The seeds are not
  independent, though; seed 13 hit every time, so the true miss rate is not
  simply 0.77^20.
- **The tmux differential alone does not catch #63.** Both tmux suites stayed
  green under mutant 1 in all three runs. Their dismiss-then-swipe loop
  records tmux's outcome and does not assert it, for the reason in the
  suite's header: tmux applies a resize late, on every transport. That late
  resize hides transport reordering. With mouse on, meshyy took the swipe
  whole at the new size:
  - unmutated: 10/10 in each acceptance run;
  - mutant 1: 6, 7, 7 of 10;
  - mutant 2: 9, 4, 8 of 10.

  Over ssh in the same runs: 2, 6, 6 and 4, 2, 3 of 10. The shift is real,
  but it stays inside ssh's own spread, so it cannot be asserted.
- **WireLaneTests misses mutant 1.** It pins the helper, not the routing.
  The row checker is the only witness to the routing itself.

No structural witness was added, such as a test seam that lists the open
stream kinds. The outcome test caught the revert in every run.

\* **Mutant 2, run 2: a red that is not yet explained.**

- After `path-drop-heal`, tmux session `p` was gone (`no sessions`). Every
  later mouse-on step then failed on `history → -1` and `mode=-1`, giving 22
  issues on top of the known ones.
- This did not happen in mutant 2's other two runs, in any mutant 1 run, or
  in any unmutated run.
- Cause not established. This red is not counted as a catch.

Both mutants reverted (`git checkout --`); `git diff` clean. Logs are in
`~/Developer/cc-sessions/meshyy-mutant-63/`.
