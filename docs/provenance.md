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
