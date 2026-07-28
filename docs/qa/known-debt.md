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

## ~~CI coverage of the QUIC suites~~ — RESOLVED, confirmed in a CI log

The integration suites were skipped on GitHub runners because a file keychain
could not be created there. With the keychain gone (above) the capability probe
succeeds and **CI now runs everything**: 127 tests in 15 suites, no skips,
confirmed on run 30318113414.

The gate is deliberately **kept** rather than deleted: it is a bounded capability
probe, and an environment that cannot support these suites should skip with a
reason rather than hang for the job timeout. But its failure mode is silence — a
gate that quietly keeps skipping looks identical to a gate that is not needed. If
you ever doubt what CI covered, grep the log for `skipped`.

## Tests are not parallel-safe

Everything in `MeshyyKitTests` binds a real QUIC listener, a unix socket and a
file keychain, so the suites are nested under one `.serialized` parent. swift-testing
runs distinct top-level suites in parallel, and without that nesting the
refused-attach tests passed alone and failed in the suite — which reads exactly
like a product bug and is not one. If a new suite in this package touches a real
socket, nest it too.
