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
