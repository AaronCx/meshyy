# Provenance log

Every non-obvious design decision, with the sources consulted to reach it.
This log is the artifact that makes the clean-room claim defensible.

**Standing declaration.** No mosh source, no mosh fork, no GPL/AGPL
reimplementation, and no third-party summary of mosh's internals has been read
by any contributor to this tree. mosh has never been cloned, fetched, or
installed on the development machine. The design derives from the USENIX ATC
2012 paper (which describes the design, not the expression), public prose, RFCs,
and Apple platform documentation.

---

## 2026-07-27 Zero third-party dependencies

Decision: `Package.swift` declares no dependencies, and CI fails if that ever
changes.

Rationale: the entire premise of the project is a defensible licence position.
Every dependency is a licence to audit and a transitive tree to re-audit on
every bump. A CBOR codec, a DER/X.509 builder, and a ring buffer are each a few
hundred lines of well-specified work; carrying them in-tree is cheaper than
carrying the audit burden.

Source: original decision. Design doc §0.3 (licensing hygiene) requires a
licence allowlist; zero dependencies is the strongest form of compliance.

Consulted: none beyond the design doc.

---

## 2026-07-27 Latency injection via a userspace TCP proxy, not dummynet

Decision: the benchmark and chaos harnesses inject latency, loss, and hard
drops with an in-tree userspace TCP proxy (`MeshyyChaos`) rather than macOS
`dnctl`/`pfctl` dummynet.

Rationale: dummynet needs root. The development machine has no passwordless
sudo, which would make the benchmark un-runnable in CI and un-repeatable
headlessly. A userspace proxy is slower in absolute terms but the added
per-hop cost is measured and subtracted, and the same harness is needed for the
design doc §11 chaos tests regardless.

Trade-off accepted: the proxy adds a small fixed overhead (measured at the 0ms
setting and reported as the floor in `docs/benchmarks.md`), and it cannot
emulate bufferbloat or radio-layer behaviour. For a round-trip-count
measurement, which is what §1 actually asks for, this does not matter.

Source: original decision.

Consulted: design doc §1 (measure before building), §11 (chaos harness).

---

## 2026-07-27 Hand-rolled CBOR subset for control frames

Decision: `MeshyyCore/CBOR.swift` implements the RFC 8949 subset the control
protocol needs (unsigned/negative ints, byte strings, text strings, arrays,
maps, bool, null) rather than taking a CBOR package.

Rationale: follows from the zero-dependency decision above. The subset is small,
the spec is unambiguous, and golden fixtures pin the encoding so drift is
visible in diffs.

Deliberate omissions: tags, floats, indefinite-length items, and bignums are
rejected on decode rather than silently accepted. Nothing in the protocol needs
them, and a decoder that accepts less is a smaller attack surface on a daemon
that holds PTYs.

Source: RFC 8949 §3 (specification of the CBOR encoding).

Consulted: RFC 8949; design doc §5.2 (length-prefixed CBOR control frames).

---

## 2026-07-27 Resume by byte offset into a per-session ring buffer

Decision: resume replays raw PTY bytes from a monotonic byte offset into a
per-session ring buffer. The daemon runs no terminal emulator.

Rationale: the paper describes synchronising *screen state*, which is the right
answer when the client cannot be assumed to cooperate. meshyy owns both ends, so
it can ship the raw byte stream instead: simpler, no server-side emulator, and
scrollback is preserved exactly because the client's emulator sees the identical
byte sequence it would have seen live.

Source: original design. The paper's §3 state-synchronisation protocol was read
and deliberately **not** followed.

Consulted: Winstein & Balakrishnan, USENIX ATC 2012, §3; design doc §3.2, §6.2.

---

## 2026-07-27 Prediction gated on observed termios, not inferred echo

> **SUPERSEDED** the same day by "§7 rewritten: quick actions instead of
> predictive echo" below. Kept because a provenance log is a record of what was
> decided and why, not a snapshot of what currently holds — and because the
> reasoning here was sound while the conclusion drawn from it was not, which is
> the more useful thing to be able to look back at.
>
> What survived: the daemon does read `tcgetattr` on the master and does push
> `Termios` frames, and `PTYTests` proves a child's own `tcsetattr` is visible.
> What did not: the belief that this would ever permit prediction.

Decision: the daemon calls `tcgetattr` on the PTY master and pushes a `Termios`
frame on change. The client predicts only when the daemon has reported
`ECHO && ICANON && !alt-screen`.

Rationale: this is the one capability that follows directly from owning both
ends. Blind prediction has to infer the line discipline from the output stream
and hedge; reading `c_lflag` is a fact, not an inference, and it removes the
entire class of heuristics that inference requires.

Source: original design, enabled by the both-ends architecture.

Consulted: POSIX `termios.h` (`ECHO`, `ICANON`); `tcgetattr(3)`; design doc §7.1.

---

## 2026-07-27 Runtime-generated self-signed P-256 identity, pinned via SSH

Decision: `meshyyd` generates a P-256 keypair and a self-signed X.509
certificate at first run, stores the key in the macOS data-protection keychain,
and reports the certificate's SHA-256 fingerprint over the already-authenticated
SSH channel. The client pins that fingerprint.

Rationale: Network.framework's QUIC requires a `sec_identity_t`, which requires
a certificate. A CA would add a trust decision the user should not have to make.
Pinning the fingerprint over SSH means the SSH host key — which a+Terminal
already pins — transitively secures the QUIC certificate, so the trust chain
terminates in a decision the user has already made.

The X.509 DER is constructed in-tree (`MeshyyCore/DER.swift`,
`MeshyyDaemon/SelfSignedCertificate.swift`) rather than by shelling out to
`openssl`, per the zero-dependency and no-shell-invocation rules.

Source: original design.

Consulted: RFC 5280 §4 (certificate structure); RFC 5480 (ECC SubjectPublicKeyInfo);
RFC 3279 §2.2.3 (ECDSA signature encoding); Apple Security framework and
Network framework documentation; design doc §5.1, §8.

---

## 2026-07-27 Agent-detection logic lifted from a+Terminal, not rewritten

Decision: `MeshyyCore/AgentActivity.swift` carries a direct port of
a+Terminal's `AgentActivityMonitor`, `stripANSI`, and `endsAtShellPrompt`.

Rationale: design doc §4 calls for exactly this — one implementation compiled
for both sides. The source is Aaron Character's own MIT-licensed code from
`AaronCx/a-plus-terminal`, so there is no licence question; it is recorded here
only because provenance of *any* copied code should be traceable.

Changes from the original: the port is actor-isolation-neutral (the original is
`@MainActor`, which is wrong for a daemon) and the burst/quiet timing is
injected rather than using `Task.sleep`, so the property tests can drive it
deterministically.

Source: `AaronCx/a-plus-terminal`, MIT, same copyright holder.

Consulted: design doc §4.

---

## 2026-07-27 §7 rewritten: quick actions instead of predictive echo

Decision: design doc §7 no longer specifies predictive local echo. It specifies
one-tap quick actions — approve, deny, and numeric choices — offered by the
daemon on the control stream and driven off `AgentProfile`.

Rationale, in two steps.

**The original mechanism was unreachable.** §7's premise was that owning the PTY
lets the daemon read the line discipline with `tcgetattr` and *know* whether a
keystroke will be echoed, instead of inferring it. That premise is correct. The
conclusion — that prediction would therefore be safe at a shell prompt — is not.
Measured on a real PTY, `bash -i`, `zsh -i`, `zsh -f -i` and `tmux` all hold the
tty in raw mode, because readline and zle are line editors and echo characters
themselves. Only programs that do no input handling (`cat`, `sed`) leave cooked
mode on. The gate never opens, so prediction would have been dead code in every
configuration a+Terminal is used in.

**The latency was mis-targeted anyway.** Prediction hides one round trip of echo
while typing. The interaction that actually recurs on a phone is answering an
agent — approve a tool call, deny one, pick option 2 — where the cost is the
keyboard interaction, not the RTT. Quick actions remove that entirely, work in
raw mode with the alternate screen up (exactly where prediction cannot), and need
no overlay, so they also retire the SwiftTerm render-layer risk §7.4 called the
biggest unknown in the project.

Two constraints recorded because they are security properties, not preferences:
the action's label and payload come from the local profile and never from remote
output (otherwise a remote that draws a convincing fake prompt gets a one-tap
confused deputy), and the daemon never sends an action's bytes without a tap.

Source: original design, prompted by the measurement. The measurement harness and
the full table are in `docs/spikes/2026-07-27-line-discipline.md`; the table is
also inline in §7.1 so a reader of the design doc does not have to go looking for
the evidence that changed it.

Consulted: POSIX `termios.h`; `tcgetattr(3)`; readline and zle behaviour observed
as a black box; design doc §5.3, §6.3, §7, §10, §11, §13.

Decided by: Aaron, on being shown the measurement — "the answer was never
per-keystroke prediction."

---

## 2026-07-27 QUIC 0-RTT is unreachable; §6.1 and M4 corrected

Decision: meshyy does not use QUIC 0-RTT, and the design doc no longer claims it.
§6.1's "first byte in roughly one round trip instead of five or six" is replaced
by the measured "about 2 round trips to the server, 2.7 to output back, with no
process spawn". M4's acceptance criterion is rewritten accordingly and split into
a transport measurement and a device-only roaming test.

Rationale: measured, not assumed. Network framework exposes no path — public or
private — that puts application bytes in QUIC's first flight.
`sec_protocol_options_set_tls_resumption_enabled` is inert for QUIC.
`NWParameters.allowFastOpen` with an `.idempotent` send is accepted and then never
sends early. The only symbol that engages resumption at all,
`sec_protocol_options_set_tls_early_data_enabled`, is SPI and worth ~13 ms of CPU
— a fraction of a round trip. Using SPI in a launchd daemon on a
privacy-branded product is not a trade worth making for that.

The win survives the correction: 2 round trips against SSH's measured 8.3
(docs/benchmarks.md) plus a shell and multiplexer start. It comes from QUIC
combining the transport and crypto handshakes and from resuming an already-running
session, not from 0-RTT.

A second correction fell out of the same review, and it is the more useful one:
§6.1 implied the *screen* costs a round trip to restore. It does not. iOS suspends
rather than kills, so the emulator still holds the frame and first paint on
foreground is free. What costs round trips is the session going live again. That
distinction matters because it is the difference between a latency the user sees
and one they do not — and it means the perceived-latency work is already done.

Deliberately NOT taken: persisting session content on the client so a jetsammed
app could repaint without the network. That is the only case where first paint
genuinely costs a round trip, and fixing it means writing terminal scrollback to
disk. §9 is emphatic about session content, and while it constrains the daemon
rather than the app, extending it is Aaron's call rather than an implementation
detail. Recorded as an open question instead.

Source: empirical probe of the macOS 26.4.1 SDK and runtime; SDK header inspection
for the sec_protocol_options and NWProtocolQUIC surfaces.

Consulted: RFC 9001 §4.6 (0-RTT), Apple Network framework and Security framework
headers, design doc §6.1, §10 M4, §12.1.

---

## 2026-07-27 Network framework QUIC does not migrate; §12.1 answered "no"

Decision: §6.1 no longer claims connection migration works in the foreground, and
§12.1 is answered "no" rather than "foreground only". M4's roaming acceptance is
respecified as reconnect-and-resume with a 300 ms budget instead of "no visible
interruption via migration".

Rationale: measured. A peer address change silently black-holes a Network
framework QUIC connection until the idle timeout fires, in either direction, and
`NWConnectionGroup` exposes no path, viability, or better-path signal to notice it
with. `nw_quic_migration_info_*` is entirely SPI, so even where migration does
happen it is unobservable from public API — which means a test could never assert
migration was the mechanism, only that the session survived.

Two code changes follow directly, and both are the kind of thing that only shows
up when someone measures rather than reads:

- The client's idle timeout drops from the 30 s default to 5 s. Since migration
  does not happen, the idle timeout is the *only* thing that tells a client its
  session has gone deaf — and at 30 s the group keeps reporting `.ready` while the
  user stares at a dead terminal.
- QUIC keepalive is enabled at 2 s via `NWProtocolQUIC.Metadata.keepAlive`, which
  is only reachable per-connection and only once a connection is up. This is what
  makes a 5 s idle timeout safe rather than trigger-happy: without it a quiet but
  healthy session would be reaped. Note the getter always reports `.off` whatever
  was set, so there is no assertion to write — the effect was verified on the wire
  by the probe, and the code says so rather than pretending a unit test covers it.

Deliberately NOT taken: §12.1's own stated fallback of moving to TCP+TLS. QUIC
still earns its place on §5.2 multiplexing and a combined transport+crypto
handshake, and TCP+TLS does not migrate either — so the fallback would cost the
benefits and fix nothing.

Contradiction noted: the migration probe referred in passing to "0-RTT resume" as
though it were available. It is not — see the 0-RTT entry above, which comes from
a probe that tested it directly. The specific measurement wins over the passing
mention.

Source: empirical probe on macOS 26.4.1 with a userspace UDP relay rotating the
server-facing 4-tuple; SDK interface inspection of NWProtocolQUIC.Metadata.

Consulted: RFC 9000 §9 (connection migration); Apple Network framework interfaces;
design doc §6.1, §10 M4, §12.1.

---

## 2026-07-27 SecIdentityCreate: no keychain, and a latent hang avoided

Decision: `DaemonIdentity` obtains its `SecIdentity` from
`SecIdentityCreate(nil, certificate, privateKey)` and touches no keychain. The key
is generated transient (`kSecAttrIsPermanent: false`) and persisted as a raw P-256
representation in a 0600 file beside the certificate DER.

This **supersedes** the M0 spike's conclusion that a dedicated file keychain was
the only working route. That conclusion rested on an assumption I did not check —
that `SecIdentityCreate` was private SPI. It is not: it is in
`Security.framework/Headers/SecIdentity.h`, `API_AVAILABLE(macos(10.12))`, and not
deprecated.

Three things the mistake would have cost, and only the first was known at the time:

1. Deprecated API (`SecKeychainCreate` et al, deprecated since 10.10) carried for
   no reason.
2. **A latent hang after every update.** Keys in a file keychain are ACL-bound to
   the binary that created them. meshyyd would have loaded its own key happily
   until the next time it was rebuilt, and then blocked on a Security prompt no
   headless process can answer. A failure that appears only after an update, in a
   launchd agent, is close to the worst shape a bug can have.
3. **No CI coverage.** A file keychain needs a Security session, which a GitHub
   runner lacks, so the QUIC integration suites skipped there. Removing the
   keychain removes the gate.

Verified rather than assumed: two separate `meshyyd` processes over the same
directory report an identical certificate fingerprint, and the stored files are
0600 in a 0700 directory.

The lesson worth keeping is not about Security framework. It is that "this API is
private" was an assumption that felt like knowledge, and it went unchecked through
a whole spike and into shipping code. The header was one grep away.

Source: `Security.framework/Headers/SecIdentity.h`; empirical verification on
macOS 26.4.1.

Consulted: design doc §5.1, §8; docs/spikes/2026-07-27-quic-network-framework.md
(now annotated as superseded).

---

## 2026-07-28 Integration gate: a+Terminal does NOT speak meshyy yet

Question posed by the revised-milestones amendment, to be answered before M4
starts: does the shipping a+Terminal target actually speak meshyy today, or was
M2 accepted against a test harness?

**Answer: harness only.** `AaronCx/a-plus-terminal` contains no reference to
meshyy anywhere — no source, no manifest entry, no documentation. Its Swift
package dependencies are Citadel, SwiftTerm and RoyalVNCKit, and the shipping app
connects over Citadel SSH exactly as it did before meshyy existed.

M2's acceptance — "a session over meshyy is indistinguishable from a session over
SSH" — was demonstrated against `TestDaemonHarness` and `MeshyyConnection` inside
meshyy's own test suite: a real daemon, a real QUIC connection, a real PTY, a real
pinned certificate, but no a+Terminal. That was a fair reading of the milestone as
written, and it is not what the milestone's wording implies to a later reader.
`docs/DESIGN.md` §10 M2 should be corrected to say what was actually proven.

**Consequence, per the amendment: integration is now a gate rather than a later
step.** M4's acceptance criteria are phone-lifecycle criteria — background,
foreground, radio switch, jetsam — and none of them can be measured anywhere except
the real app on a real device. Tuning a heartbeat window against a simulator that
has no radio and no jetsam would produce numbers that mean nothing.

Two further consequences worth stating now rather than discovering in M4:

- The client half of M6 tier 1 also lands in a+Terminal, so the same integration
  work gates both remaining milestones.
- a+Terminal's dependency policy is explicit and short (`CLAUDE.md`: SwiftTerm,
  Citadel, swift-crypto, XcodeGen, RoyalVNCKit — "nothing else"). Adding MeshyyKit
  is a deliberate amendment to that policy, not a routine dependency bump, and
  meshyy is currently a **private** repo which SwiftPM must be able to resolve.

Source: direct inspection of `AaronCx/a-plus-terminal` at commit 40e9279.

## 2026-07-28 — NAT rebind breaks a Network framework QUIC connection, silently

**Decision.** M4 must treat a NAT rebind as a dead network and recover by redialling.
There is no migration path to fall back on, and no transport-level event to trigger on.

**Source.** Measured, not read. `ChaosUDPProxy.rebind()` replaces the relay's own back
socket, so the daemon sees the same QUIC connection arriving from a new source port —
a faithful NAT rebind. `ChaosTransportTests.natRebindOutcome` asserts the ports really
changed before drawing any conclusion, because a test that reports "survived a rebind"
having never performed one is worse than no test.

**Result, macOS 26.4.1, over four runs.** The byte flow stops every time. This
confirms M0's finding — Network framework QUIC exposes no migration API — at the level
that actually matters, which is whether the implementation tolerates it anyway. It
does not.

**The part that shapes M4.** What the *client* knows is worse than a clean failure.
Across runs `currentState` was sometimes `.connected` and sometimes
`.closed("the daemon closed the control stream")`, the difference being whether the
daemon happened to give up inside the observation window. The client's own transport
never reported a network problem in either case: it either believes it is fine, or it
is told second-hand by a peer it can no longer reach.

So the rewritten M4's premise is now measured rather than assumed —

> A NAT rebind looks identical to a dead network from the client side: packets leave,
> nothing returns.

— and 4b's heartbeat is not one option among several. It is the only mechanism that
can notice this. The test asserts the invariant behind both observed states (the
client never detects it itself) rather than either state individually, and records a
finding if a future OS changes that, since it would re-open the M4 design.

**Clean-room note.** The relay never inspects a payload. It knows nothing about QUIC
beyond "these are datagrams", which is what makes it both correct and safe to have
written.

---

## 2026-07-28 — the TCP chaos proxy stays, against the brief's letter

**Decision.** 1d-bis says to *replace* the TCP shim with a UDP relay. The UDP relay is
built and is the right instrument for QUIC, but `ChaosTCPProxy` is kept.

**Reasoning.** The §1 benchmark gate — the measurement the entire project is justified
by — drives `ssh` through the TCP proxy to synthesise RTT. SSH does not run over a UDP
relay. Deleting the TCP proxy would delete the reproduction of
`attach: total = 187.4 ms + 8.31 x RTT`, which is the number meshyy is measured
against. UDP for impairing QUIC, TCP for the SSH baseline it is compared to.
