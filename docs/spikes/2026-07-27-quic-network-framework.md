# M0 spike: QUIC over Network framework, with a runtime self-signed identity

**Date:** 2026-07-27
**Question (design doc §10 M0, §12.1):** does Network framework's QUIC work for
meshyy's shape — a self-signed identity generated at runtime, pinned by
fingerprint, carrying several concurrent bidirectional streams?
**Answer: yes. All five sub-questions resolved. No design change needed.**

Environment: macOS 26.4.1, Swift 6.3.2, Xcode 26.5, unsigned SwiftPM binary run
over SSH with no GUI session in the foreground.

Prototype: throwaway, `quic-spike` outside the tree. Reusable parts
(`DER.swift`, `X509Template.swift`) were written as real `MeshyyCore` code and
consumed by the spike, so nothing correct got thrown away.

---

## 1. Can an unsigned daemon get a `sec_identity_t`? Yes — and this section's
## original answer was WRONG.

> **Superseded 2026-07-27, later the same day.** This section concluded that a
> dedicated file keychain was the only working route, on the assumption that
> `SecIdentityCreate` was private SPI. **It is not.** It is public,
> `API_AVAILABLE(macos(10.12))`, not deprecated, and it pairs a certificate with a
> key touching no keychain at all.
>
> The mistake was not free. Besides carrying deprecated API for no reason, a file
> keychain binds its keys by ACL to the binary that created them — so the daemon
> would have loaded its own key happily until the next time `meshyyd` was rebuilt,
> and then **hung** on a Security prompt no headless process can answer. A bug that
> appears only after an update is the worst kind to ship. It also needed a Security
> session, which a CI runner lacks, which is why the QUIC suites could not run in CI.
>
> `DaemonIdentity` now uses `SecIdentityCreate` with a transient key and persists the
> raw P-256 key and certificate DER as two 0600 files. Verified: the fingerprint is
> stable across separate processes. See docs/provenance.md.
>
> The measurements below are still accurate about the *keychain* routes. They were
> just answering a question that did not need to be asked.



`sec_protocol_options_set_local_identity` needs a `SecIdentity`, which needs a
private key and a certificate that the keychain can pair. Three routes tried:

| Route | Result |
|---|---|
| Data-protection keychain (`kSecUseDataProtectionKeychain`) | **FAIL** `-34018` errSecMissingEntitlement |
| Default (login) keychain | **FAIL** `-25308` errSecInteractionNotAllowed |
| Dedicated file keychain (`SecKeychainCreate` + `SecKeychainUnlock`) | **PASS** |

The two failures are both structural, not fixable by retry:

- The data-protection keychain requires the binary to be signed with a
  team-prefixed `keychain-access-groups` entitlement. An unsigned or ad-hoc
  binary cannot have one.
- The login keychain is locked in an SSH session and has no way to prompt, so
  key *generation* fails before storage is even attempted. This is exactly the
  headless case meshyyd must work in.

**Decision: dedicated file keychain**, created by the daemon at first run, with a
32-byte random password in a `0600` file beside it.

**Known debt.** `SecKeychainCreate` and `SecKeychainUnlock` have been deprecated
since macOS 10.10. They still work on macOS 26.4.1. If Apple removes them, the
migration is: sign `meshyyd` with Aaron's Developer ID plus a
`keychain-access-groups` entitlement and switch to the data-protection keychain,
which is the route that already fails *only* for want of that entitlement. A
launchd daemon should be signed anyway, so this is a scheduling question, not a
research one. Tracked in `docs/qa/known-debt.md`.

## 2. Is the hand-built certificate real? Yes, and independently verified.

`MeshyyCore.X509Template` builds the DER; `SecKeyCreateSignature` with
`.ecdsaSignatureMessageX962SHA256` signs it. Verified two ways rather than
trusting our own pinning:

- `openssl x509 -inform DER -text` parses every field correctly: v3, ECDSA
  with SHA-256, `CN=meshyyd, O=meshyy`, P-256 public key, basicConstraints
  critical CA:FALSE, keyUsage critical digitalSignature, extKeyUsage serverAuth,
  subjectAltName with two dNSNames, subjectKeyIdentifier.
- `SecTrustEvaluateWithError`, with the certificate set as its own anchor,
  returns true. This is the check that matters: a client that only compares
  fingerprints would accept a certificate whose self-signature was garbage, so
  the signature had to be validated by something that actually checks it.

Certificate size: 463–464 bytes. It fits in a single QUIC Initial packet, which
is why the handshake below costs what it costs.

## 3. Which connection model? Both work. Use the multiplex group.

Two models exist and the listener side is **mutually exclusive** — setting both
`newConnectionHandler` and `newConnectionGroupHandler` on one `NWListener` makes
it fail with `POSIXErrorCode 22 (EINVAL)`. That is not documented anywhere and
cost the first two attempts at this spike.

| Model | Client | Server | Result |
|---|---|---|---|
| single | `NWConnection(to:)` | `newConnectionHandler` | PASS, one stream |
| mux | `NWConnectionGroup(NWMultiplexGroup(to:))` | `newConnectionGroupHandler` | PASS, many streams |

**Decision: mux.** Design doc §5.2 needs a control stream, one `pty:N` per
session, and `blob:N` uploads on one connection. The mux model delivers exactly
that: four concurrent bidirectional streams (`control`, `pty:0`, `pty:1`,
`blob:0`) each round-tripped correctly and independently.

### Two non-obvious requirements

1. **`setReceiveHandler` must be called before `start`.** Without it the group
   never leaves its initial state, `stateUpdateHandler` never fires even once,
   and there is no error to diagnose — it simply sits there. A multiplex group
   has no group-level messages, so the handler body is empty, but it must exist.
2. **Streams can only be created after the group is `.ready`.**
   `NWConnection(from: group)` returns `nil` before that, silently.

Both are worth a comment at the call site in production code; neither is in the
docs.

### Transient state noise

The group briefly reports `waiting(POSIXErrorCode 50: Network is down)` on
loopback before going `.ready`, and cancelled streams report the same. This is
normal churn, not a fault. Design doc §3.5 says "fail visible" — so the
production state machine must **not** surface `waiting` as a user-facing error,
only a `failed` that persists past a grace period. Noted for M2.

## 4. Does fingerprint pinning work, and does a wrong pin get rejected?

Yes to both.

- Correct pin: verify block ran, matched, handshake completed.
- Wrong pin (32 zero bytes): verify block ran, reported the mismatch, and the
  group **never reached `.ready`**. It sat in `waiting`/`failed` until the
  8-second test timeout. Rejection is by omission rather than by a clean error,
  so the production client needs its own connect deadline and must report a pin
  mismatch from its own verify-block result, not from the connection state.

No CA is involved, and `sec_protocol_options_set_verify_block` fully replaces
chain validation, so the trust chain terminates exactly where design doc §5.1
says it should: in the SSH host key the user already pinned.

## 5. Handshake cost

Loopback, same process, so these are CPU floors and not network numbers:

| | cold handshake |
|---|---|
| single model | 25.8 ms |
| mux model | 12.7 ms |

Useful only as a sanity check that nothing pathological is happening. The number
that matters — how many round trips a cold and a resumed QUIC handshake cost
versus SSH's measured 8.3 — needs a UDP impairment proxy, which the TCP-only
`ChaosTCPProxy` cannot provide. **Deferred to M4**, where `ChaosUDPProxy` is
required for the chaos harness regardless. `docs/benchmarks.md` gets its second
section then.

## 6. Connection migration — NOT answered here

Design doc §12.1 asks whether Network framework's QUIC does connection migration
on iOS across a WiFi-to-LTE switch. **This spike cannot answer that**: it needs
two real interfaces on a real device, and loopback has one.

This is deliberately not a blocker. Design doc §6.1 already establishes that
migration does not survive iOS suspension, so migration only helps a
foreground-to-foreground network change. The resume path — which is the actual
product win and does not depend on migration — is fully exercisable here. If
migration turns out not to work, §12.1's own fallback applies and costs little.

Carried to M4 as a device test, listed in `docs/qa/device-matrix.md`.

---

## Consequences for the design

Nothing in the design doc needs to change. Four things get pinned down:

1. Identity lives in a dedicated file keychain. Deprecated API, documented debt,
   known migration.
2. Transport is the multiplex-group model, with the two undocumented ordering
   requirements above.
3. The client owns its connect deadline and its own pin verdict; connection
   state alone is not a usable signal for either.
4. `waiting` is not an error. Only sustained `failed` is.
