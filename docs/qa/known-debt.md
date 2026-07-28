# Known debt

Things that work, are deliberate, and would be wrong to forget.

## Deprecated keychain API in `meshyyd`

`DaemonIdentity` uses `SecKeychainCreate`, `SecKeychainOpen`, `SecKeychainUnlock`
and `SecKeychainSetSettings`, all deprecated since macOS 10.10. They work on
26.4.1 and emit deprecation warnings, which are left in place on purpose: they are
a standing reminder rather than noise to suppress.

**Why there is no alternative today.** Measured in
`docs/spikes/2026-07-27-quic-network-framework.md`:

- Data-protection keychain: `-34018` errSecMissingEntitlement. It needs a
  team-prefixed `keychain-access-groups` entitlement, which an unsigned or
  ad-hoc-signed binary cannot carry.
- Login keychain: `-25308` errSecInteractionNotAllowed. Locked in an SSH session
  with no way to prompt — and headless is precisely meshyyd's case.

Both are structural, not transient.

**Migration when Apple removes it.** Sign `meshyyd` with Aaron's Developer ID plus
a `keychain-access-groups` entitlement and switch to the data-protection keychain,
which already fails *only* for want of that entitlement. A launchd agent should be
signed anyway, so this is scheduling rather than research.

## QUIC 0-RTT is not available

Not debt so much as a corrected assumption, recorded here because it looks like a
missing feature. Design doc §6.1 has the measurement and the honest replacement
claim. Do not reach for
`sec_protocol_options_set_tls_early_data_enabled` — it is SPI, and it buys ~13 ms.

## Connection migration is unverifiable from public API

`nw_quic_migration_info_*` is entirely SPI. Whatever migration Network framework
performs is automatic and unobservable, so the device tests in `device-matrix.md`
can assert only that a session survived an interface change, never that migration
is the mechanism that saved it.

## Two undocumented Network framework requirements

Encoded at their call sites in `QUICServer.swift` and `MeshyyConnection.swift`,
repeated here because they cost an afternoon each and will again:

1. `setReceiveHandler` must be called before `start` on an `NWConnectionGroup`, or
   the group never leaves its initial state and its state handler never fires —
   with no error to diagnose.
2. `NWConnection(from: group)` returns `nil` until the group is `.ready`.

And one more: a listener's `newConnectionHandler` and `newConnectionGroupHandler`
are mutually exclusive. Setting both fails it with `EINVAL`.

## Tests are not parallel-safe

Everything in `MeshyyKitTests` binds a real QUIC listener, a unix socket and a
file keychain, so the suites are nested under one `.serialized` parent. swift-testing
runs distinct top-level suites in parallel, and without that nesting the
refused-attach tests passed alone and failed in the suite — which reads exactly
like a product bug and is not one. If a new suite in this package touches a real
socket, nest it too.
