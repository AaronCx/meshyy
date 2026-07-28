# Test inventory

Audit for hardening PR 1a. **Audit only — nothing was changed.**

Counted from `swift test list` and by reading each test, not from names.
`make test` (all suites): 127 test functions, 128 reported cases, ~330 runtime
cases once parameterised tests expand. 12.8 s.

---

## The four questions, answered

### 1. How many tests exercise resume at all?

**23 functions / ~222 runtime cases.** Resume is the single most-tested thing in
the project, by some distance.

| Layer | Functions | Runtime cases | What it drives |
|---|---|---|---|
| Model (`SessionBuffer` directly) | 9 | 208 | `MeshyyCore` resume logic, no transport |
| Transport (unix socket) | 3 | 3 | real socket, real PTY, real framing |
| Transport (QUIC) | 1 | 1 | real QUIC, real PTY |
| Client bookkeeping (`MeshyySession`) | 5 | 5 | real QUIC + client offset arithmetic |
| Redraw-anchor semantics | 4 | 4 | `ScreenScanner` offsets |
| Protocol field | 1 | 1 | `resumeFrom` present/absent on the wire |

### 2. How many exercise resume across a real disconnect rather than a clean teardown?

**Nine cross a connection close. Zero cross an abrupt loss.** This is the gap.

Every transport-level resume test disconnects by calling `close()` or `detach()`,
which cancels the QUIC group or closes the socket — an *orderly* teardown that
emits `CONNECTION_CLOSE` or a FIN, with nothing in flight.

**The production case is not that.** iOS suspension means packets simply stop:
no close frame, no FIN, the daemon's peer just goes quiet, and whatever was in
flight is lost mid-frame. Nothing in the suite reproduces that.

So the honest split is:

| Kind of disconnect | Tests | Notes |
|---|---|---|
| Graceful close, then reconnect | 9 | orderly; no bytes in flight |
| Abrupt loss (no close frame) | **0** | **the actual production case** |
| Loss mid-control-frame | **0** | framing resync untested under loss |
| Half-open (one direction dies) | **0** | |

### 3. Does anything inject loss, reorder, duplication, or latency?

**No. Nothing.** Not one test.

Worse than absent — it looks present:

- `MeshyyChaos` exists as a target and **is declared as a dependency of
  `MeshyyCoreTests` in `Package.swift`**. No test file imports it. It is dead
  weight in the test graph that reads, from the manifest, like coverage.
- `ChaosTCPProxy` is real and works, but is `NWParameters.tcp` — it **cannot
  impair QUIC at all**. Its only consumer is the §1 benchmark script via the
  `meshyy-chaos` CLI.
- `ChaosProfile` has `loss`, `reorder`, `jitter` and `severAfter` fields.
  `ChaosTCPProxy` ignores `loss` and `reorder` by design (dropping bytes from a
  TCP stream corrupts it rather than emulating anything). So those knobs exist and
  do nothing anywhere.

A `ChaosUDPProxy` prototype was written during the M4 research and produced the
2.06-round-trip figure in `docs/benchmarks.md`. **It is not in the tree.**

### 4. Is the §6.4 stream-equality property actually asserted, or is it prose?

**Asserted.** `StreamEqualityTests.streamEqualityUnderChaos(seed:)`, 200 seeded
scenarios, each a random interleaving of writes, clears, disconnects and
reconnects. It fails with a reproducible seed. It has caught real bugs.

**But it asserts at the model layer, and that is a narrower claim than §6.4
makes.** Three limits, in order of how much they matter:

1. **It drives `SessionBuffer` directly.** No framing, no transport, no bytes in
   flight. Its "disconnect" is `connected = false`. So it proves the *resume
   decision* is correct, not that the *stack* preserves the byte stream.
2. **It asserts against a model of the client, not the client.** `ClientModel` in
   the test file is a second implementation of what `MeshyySession` does. The two
   can drift, and if they do the property test stays green while the product
   breaks. That risk did not exist when the test was written — `MeshyySession`
   came later — and nothing currently pins them together.
3. **Chunk boundaries are the test's own.** Real PTY reads split where the kernel
   decides and real QUIC streams deliver where the network decides; neither is
   modelled.

The nine transport-level resume tests do cover the stack, but each is a single
hand-written scenario, not a property over a randomised space.

---

## Full inventory by suite

| Suite | Functions | Cases | Needs a real process/socket | What it covers |
|---|---|---|---|---|
| `CBORTests` | 17 | 44 | no | RFC 8949 subset, hostile-input rejection |
| `AgentActivityTests` | 17 | 22 | no | burst/quiet heuristic, markers, quick-action matching |
| `PTYTests` | 16 | 17 | **yes** | PTY ownership, termios, signals, controlling tty |
| `ControlFrameTests` | 14 | 60 | no | frame round trips, golden wire fixtures, version skew |
| `ScreenScannerTests` | 13 | 18 | no | clear/alt-screen detection, split sequences, anchors |
| `MeshyyKitSuite` (QUIC + session) | 13 | 13 | **yes** | QUIC transport, bootstrap, tokens, client resume |
| `LocalSocketTests` | 11 | 11 | **yes** | socket transport, resume, ordering, permissions |
| `AgentNotifierTests` | 11 | 11 | no | notification gating, rate limit, templates |
| `StreamEqualityTests` | 9 | 208 | no | **§6.4 property test** + named resume cases |
| `QuickActionResolutionTests` | 2 | 2 | no | local-only action resolution |
| `VersionTests` | 2 | 2 | no | protocol identity |
| surface smoke | 2 | 2 | no | version accessors |

40 of 127 functions need a real process or socket and are gated on
`MESHYY_INTEGRATION_TESTS=1` — so **CI does not run them**
(`docs/qa/known-debt.md`). That interacts badly with this brief: the transport-level
resume tests are exactly the ones CI skips.

## Backpressure (PR 1d)

Checked separately because the brief calls it out. **Nothing tests it.**

There is reason to think the design is right — `PTYSession.drain()` reads to EAGAIN
into the ring buffer and never awaits a network write, and the subscriber streams
are `.unbounded` — but "reads plausibly" is not "was measured with 50 MB and a
disconnected client". No test disconnects a client and keeps producing.

## Has any of this ever failed?

Relevant to PR 1e. The §6.4 property test **has** gone red on real defects during
development, and the transport tests found seven bugs including two ordering faults
that could scramble input. So these are not tests nobody has seen fail.

But that is history, not a demonstration. There is no *recorded* mutation showing
the property test catching a deliberately introduced off-by-one, which is what 1e
asks for.

---

## What this means for the plan

The brief's stated assumption — "mostly happy-path unit tests", §6.4 "currently
prose in a design doc" — is **wrong in one direction and right in another**, and
the difference changes PR 1.

**Wrong:** §6.4 is asserted, over 200 seeded scenarios, and resume is the
best-covered area in the project. PR 1c as written would rebuild something that
exists.

**Right, and it is the part that matters:** the assertion stops at the model layer.
Nothing injects impairment, nothing survives an abrupt loss, and `MeshyyChaos` is
shaped like coverage without being it.

So the useful version of PR 1 is narrower and deeper than the brief assumes:

1. **Lift the existing property test up a layer** rather than writing a new one.
   Keep `streamEqualityUnderChaos` as the fast model-level check, and add a
   transport-level variant that drives the same randomised scenarios through a real
   socket or QUIC connection with impairment.
2. **Delete `ClientModel` or pin it to `MeshyySession`.** Two implementations of
   the client's offset arithmetic, with the tested one not being the shipped one,
   is the sharpest hazard this audit found and it is not on the brief's list.
3. **Land `ChaosUDPProxy`** — 1b is genuinely missing and is the blocker for
   everything else. Also either wire `MeshyyChaos` into a test or drop the unused
   dependency, because a manifest that implies coverage is worse than none.
4. **1d and 1e as written.** Both are real gaps; neither exists in any form.

The one thing I would add that the brief does not mention: **the abrupt-loss case
matters more than loss injection.** Every existing disconnect is graceful, and
production is never graceful. A hard kill with bytes in flight mid-control-frame is
a single scenario that tests the framing resync path, and it is closer to what
users actually hit than a 5% loss rate is.

---

# Addendum, 2026-07-28 — after 1a-bis, 1b-zero, 1b-bis, 1d/1f, 1e-bis

The audit above is unchanged; this records what it led to.

## Wire format coverage, stated explicitly (1c-bis asks for this)

**It has golden fixtures, and they are real.** `ControlFrameTests.goldens` is a table
of 14 frames paired with the exact hex they must produce:

- `goldenWireFormat` asserts encoding produces those bytes, so a wire change shows up
  as a fixture diff rather than as a silent protocol break.
- `goldenDecodes` asserts each fixture decodes back to the frame it came from, so the
  table cannot drift into being self-consistent nonsense.
- Every frame case additionally round-trips (`roundTrip`, 17 cases), and §5.3's
  version-skew rules are asserted rather than assumed: an unknown frame type decodes
  to `.unknown` and round-trips its payload, extra fields on a known frame are
  ignored, an unrecognised `AgentEvent` kind is treated as a newer peer, and a peer
  that predates the protocol-version field is read as version 1.
- CBOR beneath it has 44 cases including RFC 8949 Appendix A vectors and rejection of
  tags, floats, indefinite lengths, reserved additional-info, truncation, trailing
  bytes, invalid UTF-8, over-deep nesting, and collection lengths the input cannot
  back.

What the wire format does **not** have: any test of framing behaviour under a
*damaged* stream beyond `malformedFrameIsTerminal` (one unknown channel kind). A
control frame truncated mid-header by an abrupt disconnect is untested — that is 1h.

## Current numbers

| | audit | now |
|---|---|---|
| test functions | 127 | **133** |
| running on merge | 87 | **133** |
| gated out of CI | 40 | **0** |
| inject impairment | 0 | 0 — still nothing, until 1d-bis |
| resume across abrupt loss | 0 | 0 — still nothing, until 1h |
| shipping client pinned to the oracle | no | **yes**, 200 scenarios, per step |

## What the four findings turned into

1. **`ClientModel` unpinned** → `ConformanceTests` replays all 200 shared scenarios
   against both implementations, comparing after every step. A mutation that
   previously merged green now fails 137 of them.
2. **Assertion stopped at the model layer** → the corpus moved to
   `MeshyyTestSupport.ResumeScenario` and is now executed at two levels. Transport
   tests also became byte-exact rather than substring-based.
3. **`MeshyyChaos` declared and unimported** → dependency dropped, and
   `scripts/check-test-coverage.sh` fails the build on a recurrence, on a job that
   narrows the test run, or on a suite gated behind an environment variable.
4. **Every disconnect graceful** → still true. 1h.

---

# Addendum, 2026-07-28: after 1h

The row that read "resume across abrupt loss | 0 | 0 — still nothing, until 1h"
is closed.

| | before 1h | after |
|---|---|---|
| test functions | 133 | **142** |
| running on merge | 133 | **142** |
| gated out of CI | 0 | 0 |
| resume across abrupt loss | **0** | 9 tests, ~1,600 truncation points |
| inject impairment | 0 | 0 — still nothing, until 1d-bis |

`Tests/MeshyyKitTests/AbruptLossTests.swift` covers, against the shipping
`MeshyySession` rather than the reference model:

| case | how |
|---|---|
| kill at any byte of a live burst | exhaustive sweep, every offset 0…n |
| kill at any byte of a replay | exhaustive sweep, every offset 0…n |
| kill before any replay base exists | sweep across the whole handshake prefix |
| kill mid-control-frame | every truncation of a `resize`, 1…n-1 |
| the 200-scenario corpus, abruptly | truncation at a seed-derived offset before **every** reconnect |
| ack lost in flight | named case |
| resize lost in flight | named case |
| pty arriving before its replay base | named case — found by mutation, see below |
| a queue orphaned by the disconnect | named case — found by mutation, see below |

**Sweeps, not samples.** Off-by-ones live at frame headers, ring-buffer wrap, and
replay chunk edges; sampling walks past them. Each sweep kills at every byte
offset in its window rather than at a chosen few.

**What 1h found that was not in its brief.** The mutation battery
(`docs/qa/mutation-log.md`) showed the pty-before-base queue was uncovered by all
400 scenario-runs across both execution modes — a real out-of-order race, since
`pty` and `control` ride separate QUIC streams. Two named tests close it. This is
the second time a coverage claim in this project was vacuous until a planted
defect was used to check it, after the privacy gate that silently ate the `//` in
`https://`.

**Still open.** Nothing here impairs a live connection; every byte is delivered
by the harness. Loss, reordering, and NAT rebind against a real QUIC session
remain 1d-bis.

---

# Addendum, 2026-07-28: after 1d-bis

The row that read "inject impairment | 0 | 0 — still nothing, until 1d-bis" is closed.

| | before 1d-bis | after |
|---|---|---|
| test functions | 142 | **149** |
| running on merge | 142 | **149** |
| inject impairment | **0** | 7 tests against a real QUIC session over a degraded relay |

`ChaosUDPProxy` relays datagrams between client and daemon without ever inspecting a
payload, so connection IDs, version negotiation and coalescing pass through opaquely.
The QUIC connection is real; only the network under it is fake.

| knob | shape | what it is for |
|---|---|---|
| loss, reorder, delay, jitter | profile, seeded | ordinary degradation |
| `blackHole(_:for:)` | runtime | deafness, then healing — M4 4a/4b |
| `kill(after:)` | runtime | the wire stops at a byte offset |
| `halfOpen(_:)` | runtime | one direction dies, the other lives |
| `rebind()` | runtime | NAT rebind via a source-port change — M4 |
| `severAll()` | runtime | the §6.1 iOS-suspension kill |

**The test that fails without the relay.** `theRelayIsActuallyInThePath` asserts both
that a pristine relay is transparent *and* that the relay's own counters show it
carried the traffic. Transparency alone would also be satisfied by a relay that was
never in the path — the failure mode a chaos harness is most likely to have and least
likely to notice.

**Two limitations, stated rather than implied.**

1. **A seed reproduces the relay's decisions, not a whole session.** A live replay
   would also need identical traffic, and QUIC picks its own retransmission timing.
   The first draft of the determinism test compared two live runs and was flaky for
   exactly that reason; it now asserts the decision stream directly.
2. **Ordinary loss is mostly invisible.** QUIC retransmits through it, so a drop rate
   surfaces as latency. `lossIsRetransmittedThrough` asserts that — and also asserts
   the relay really dropped something, so a green run cannot mean "nothing happened."

**Still open.** Every impairment here is synthesised on loopback. Real radio
transitions, jetsam and backgrounding remain device-only, which is why the rewritten
M4 requires a physical iPhone for its acceptance.

---

# Addendum, 2026-07-28: after M4

| | before M4 | after |
|---|---|---|
| test functions | 149 | **161** |
| running on merge | 149 | **161** |
| reconnect triggering | **0** | 11 unit + 1 end-to-end |

`ReconnectTests` is deterministic and needs no network, which is the point: M4's
acceptance says "exactly one reconnect in flight — **asserted, not observed**", and a
concurrency rule checked by reading log lines is a test of the logging.
`ReconnectCoordinator` therefore knows nothing about QUIC, tokens or sessions.

**Mutation-checked before being kept.** Four defects were planted in the coordinator
and each had to be named by a test:

| mutant | caught by |
|---|---|
| single-flight removed (concurrent redials) | the burst test, immediately |
| stray pong accepted as an answer | the straggler test |
| a queued trigger silently dropped | the new-information retry test |
| backoff wait removed entirely | **nothing** — hole found and closed |

The last one is why the battery was worth running. `successResetsBackoff` asserts a
*fast* path and so cannot tell "the failure count was reset" from "there is no backoff
at all". `failuresBackOff` asserts the slow path, and kills the mutant.

**The end-to-end acceptance** (`blackHoleRecoversWithoutUserAction`) black-holes a live
QUIC session in both directions and requires it to come back with no user action and
the stream intact across the seam. A black hole is the right instrument because it
announces nothing — no error, no close, no path callback — so only the heartbeat can
notice it. That test found a real hole in the confirmation gate; see
docs/provenance.md.

**Still open.** Radio transitions, jetsam and backgrounding are device-only. M4's
acceptance list is written against a physical iPhone and this does not discharge it.
