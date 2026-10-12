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

## ~~CI does not gate the QUIC or client-session suites~~ — RESOLVED (1b-zero)

**Everything runs on merge.** 130 tests, no gate, no env var, ~13 s.

The gate existed because those suites were flaky on a shared runner. The cause was
never the runner: it was **asserting on a real interactive shell**, whose prompt,
readline and job control made "did the bytes arrive" depend on machine load. Three
earlier attempts treated the symptom — raising ceilings to 30 s, reordering the event
consumer (which made CI *hang*), serialising the suites — and each moved the failure
rather than removing it.

The fix was to change the instrument. Any test whose subject is the **transport**
now runs against `DaemonConfig.deterministicEcho`: `cat` on a PTY put in raw mode
before the child starts, so the session is a transparent byte pipe. A real shell is
kept only where the subject *is* the shell (`stty size` reaching the kernel, M1's
"attach gives a working shell").

That made the assertions **stronger**, not weaker. They compare whole byte arrays
instead of searching for a marker substring — which matters, because
`docs/qa/mutation-log.md` records a duplicating defect that slipped past a
substring-based "no duplicates" check.

`scripts/check-test-coverage.sh` now fails the build if a job narrows the test run,
if a suite is gated on an environment variable, or if a test target declares a
dependency nothing imports. All three are ways of looking covered without being
covered, and meshyy had shipped two of them.

## Tests are not parallel-safe

Everything in `MeshyyKitTests` binds a real QUIC listener, a unix socket and a
file keychain, so the suites are nested under one `.serialized` parent. swift-testing
runs distinct top-level suites in parallel, and without that nesting the
refused-attach tests passed alone and failed in the suite — which reads exactly
like a product bug and is not one. If a new suite in this package touches a real
socket, nest it too.

## Two resize-signal tests are flaky on the CI runner (open, 2026-10-12)

`MultiplexerResizeTests` "A pane inside the multiplexer tracks shrink and growth"
(screen) and, less often, `AttachResyncTests` "A mid-session resize repairs a
program that missed its signal" fail on the 3-core `macos-26` runner and never
locally, including under 12 busy loops of CPU load. Measured with probe branches
dispatched against fixed commits:

| commit | screen test on CI |
|---|---|
| `bc33d14` (before the mode trace, #66) | 6 of 6 green |
| `af36e63` (main after #66/#67) | 0 of 5 green |
| `af36e63` minus `ModeTraceTests` | 2 of 2 green |
| `af36e63`, only the `list --json` trace test enabled | 0 of 1 green |
| ...that test with tracing off | 3 of 4 green |
| ...trace lines captured, not written to stderr | 0 of 3 green |
| ...polling without blocking the cooperative pool | 0 of 3 green |

Adding the trace suite shifted what runs concurrently and raised the flake rate.
No single mechanism in it explains the failure: blocking, stderr and lingering
sessions were each ruled out. The tests themselves are the fragile part.
- The attach-resync test fired its signal after a fixed 700 ms. It now waits for
  the shell to report its trap is installed.
- The screen test asked once and read a redraw-mangled stream. It now re-asks
  with fresh markers for 20 s.

Even so, screen intermittently never answers after the regrow on the runner.
That failure now records the pane's last output and the process tree, so the
next red run says what the pane showed. Until then a red run here is not
evidence about a product change. Re-run it once. If it fails twice, read the
recorded tail before deciding anything.
