# Known debt

Things that work, are deliberate, and would be wrong to forget.

## ~~Deprecated keychain API in `meshyyd`~~ — RESOLVED

`DaemonIdentity` no longer touches a keychain. `SecIdentityCreate(nil, cert, key)`
is public, `API_AVAILABLE(macos(10.12))` and not deprecated; the key is generated
transient and persisted as a 0600 file alongside the certificate DER.

This removed three problems at once, only one of which was known at the time:

1. The deprecated `SecKeychain*` surface is gone.
2. **A latent hang.** File-keychain keys are ACL-bound to the binary that created
   them, so meshyyd would have worked until its next rebuild and then blocked on a
   Security prompt no headless process can answer. A bug that only appears after an
   update.
3. **CI coverage.** No keychain means no Security session requirement, so the
   integration suites can run on a runner.

## QUIC 0-RTT is not available

Not debt so much as a corrected assumption, recorded here because it looks like a
missing feature. Design doc §6.1 has the measurement and the honest replacement
claim. Do not reach for
`sec_protocol_options_set_tls_early_data_enabled` — it is SPI, and it buys ~13 ms.

## Connection migration does not happen at all

Measured, not inferred: a peer address change silently black-holes a Network
framework QUIC connection until the idle timeout fires, in either direction, and
`NWConnectionGroup` exposes no path or viability signal to notice it with.
`nw_quic_migration_info_*` is entirely SPI, so even where migration does occur it
is unobservable from public API.

Mitigated rather than worked around: the client sets a 5 s idle timeout instead of
the 30 s default (the idle timeout is now the *only* deafness signal) and enables
QUIC keepalive at 2 s, which is what makes a timeout that short safe. See §6.1.

The keepalive getter always reports `.off` whatever was set, so there is nothing to
assert in a unit test. `MeshyyConnection.enableKeepAlive` says so at the call site.

## Two undocumented Network framework requirements

Encoded at their call sites in `QUICServer.swift` and `MeshyyConnection.swift`,
repeated here because they cost an afternoon each and will again:

1. `setReceiveHandler` must be called before `start` on an `NWConnectionGroup`, or
   the group never leaves its initial state and its state handler never fires —
   with no error to diagnose.
2. `NWConnection(from: group)` returns `nil` until the group is `.ready`.

And one more: a listener's `newConnectionHandler` and `newConnectionGroupHandler`
are mutually exclusive. Setting both fails it with `EINVAL`.

## CI does not gate the QUIC or client-session suites — deliberate, and debt

Removing the keychain made these suites *able* to run on a GitHub runner, and they
did pass there twice. They also failed there three times, with a **different test
timing out each run**, while the same suite passed six consecutive times locally in
13 s. Three attempts to stabilise them on the runner each moved the failure instead
of removing it: raising the wait ceilings to 30 s, replacing the detached event
consumer with a caller-task pull (which made CI *hang* — `await iterator.next()`
has no deadline), and serialising the suites under one parent.

They assert on a real shell echoing through a real PTY over a real QUIC connection.
That is exactly what makes them worth having, and exactly what a shared two-core
runner cannot schedule predictably. Loosening the assertions until CI agreed would
have weakened the tests where their value is.

The same proved true of the **local-socket** suite once CI was actually exercising
everything: "Two clients on the same session both see live output" burned 90 s on a
runner and passes here in under a second. The boundary is not QUIC — it is
**anything that spawns a real process or binds a real socket**.

**So the split is explicit.** CI gates the deterministic suites: the §6.4 property
test (200 seeded scenarios), CBOR, control frames and golden fixtures, the screen
scanner, agent activity and quick-action matching, the notifier, DER/X.509, and the
protocol identity. Everything that needs a real shell, PTY or socket — the PTY
suite, the local-socket suite, the QUIC transport suite and the client-session suite
— is gated on `MESHYY_INTEGRATION_TESTS=1`, which `make test` sets.

**Read a green CI badge accordingly.** It covers the protocol and the resume logic.
It does not cover the PTY layer, the local socket, the QUIC handshake, the
bootstrap, the token rules, or the client's resume bookkeeping. Those are covered by
`make check` before a push — which is why CLAUDE.md says that is not optional.

Worth being clear about what is lost: those suites are where the real bugs were
found. ENOTTY before the slave is opened, inherited SIG_IGN leaking processes,
discarded output at child exit, SIGPIPE killing the daemon, unordered writes
scrambling input, a reset stream discarding its own error frame — none of it was
reachable without a real process. Losing them as a *gate* is a real cost, not a
tidy-up.

Ways to close it, best first:

1. **Self-hosted runner** on this Mac. The tests are stable here; the variable is
   the runner, so change the runner rather than the tests.
2. **Make the assertions independent of shell timing** — drive a program with
   deterministic output instead of a shell, and assert on transport-level facts
   rather than on `stty size` round trips. More work, and it would lose some of
   what these tests are for.
3. Accept a retry wrapper on the integration step. Cheapest, and the worst: it
   trains everyone to re-run red builds.

## Tests are not parallel-safe

Everything in `MeshyyKitTests` binds a real QUIC listener, a unix socket and a
file keychain, so the suites are nested under one `.serialized` parent. swift-testing
runs distinct top-level suites in parallel, and without that nesting the
refused-attach tests passed alone and failed in the suite — which reads exactly
like a product bug and is not one. If a new suite in this package touches a real
socket, nest it too.
