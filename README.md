# meshyy

A resumable, roaming-tolerant terminal transport for
[a+Terminal](https://github.com/AaronCx/a-plus-terminal).

Clean-room. MIT. Not mosh-compatible, deliberately.

**Status: in development.** M0 spikes done, `MeshyyCore` landing. Nothing is
shippable yet. See `docs/DESIGN.md` for the full design and `docs/benchmarks.md`
for the measurements it rests on.

---

## What it does

iOS suspends a backgrounded app after about 30 seconds. The socket dies. On
foreground, a terminal app pays a full SSH handshake before the user can type.

**meshyy does not stop the drop. Nothing on iOS can.** What it changes is the
cost of coming back: the daemon keeps a per-session ring buffer of raw PTY
output, the client remembers the byte offset it last consumed, and a reconnect
replays from there over a QUIC connection that resumes in roughly one round trip
instead of eight.

Be clear about the limits, because users will notice otherwise:

- The connection **does not** survive backgrounding. meshyy reconnects every
  time the app returns; it just does it much faster.
- QUIC connection migration handles a WiFi-to-cellular switch **only while the
  app is in the foreground**.
- If the ring buffer has overrun, the screen is rebuilt rather than continued,
  and meshyy says so instead of pretending otherwise.

## Why it is worth building

Measured, not assumed (`docs/benchmarks.md`):

| RTT | cold SSH + tmux attach | meshyy target |
|---|---|---|
| 2 ms (LAN / Tailscale) | ~204 ms | 52 ms |
| 60 ms (typical LTE) | 686 ms | 110 ms |
| 120 ms (congested cell) | 1185 ms | 170 ms |

A cold attach costs **8.3 network round trips**. That count is a property of the
SSH handshake, so it is the part that generalises to any host and any client.

Two honest caveats from the same measurements:

- The multiplexer attach and the screen repaint are **free** — 4 ms and 0.05
  round trips. The cost is essentially all SSH handshake. meshyy is not a
  cure for reattach flicker; it is a cure for the handshake.
- **On a fast local network meshyy is not worth it.** At LAN latency the whole
  cold attach is about 200 ms. The win is specifically cellular.

## Why not just use mosh

mosh solves this problem well and is GPL-3.0. a+Terminal is MIT, and relicensing
it to GPL-3.0 would put it in a contested App Store position. That is the entire
reason meshyy exists.

meshyy is **not** a mosh clone, port, or reimplementation, and is not wire
compatible with it. It is an independent implementation of a similar idea, built
from the published design and never from mosh's source. See `docs/provenance.md`
for the full record and `CLAUDE.md` for the policy that keeps it that way.

The secondary reason is that mosh was designed for a harder problem: working
against any host with no cooperating software on either end. meshyy controls both
ends, which removes most of that complexity and enables one thing mosh cannot do
— it reads the PTY's line discipline with `tcgetattr` and *knows* whether a
keystroke will be echoed, instead of inferring it.

## Layout

```
Sources/MeshyyCore     wire format, framing, ring buffer, resume decision  (macOS + iOS)
Sources/MeshyyKit      client library; this is what a+Terminal links        (macOS + iOS)
Sources/MeshyyDaemon   PTY ownership, sessions, QUIC listener              (macOS)
Sources/meshyyd        the daemon executable                               (macOS)
Sources/meshyy         client CLI, for testing without the app             (macOS)
Sources/MeshyyChaos    latency/loss/hard-drop injection for tests          (macOS)
```

Zero third-party dependencies, enforced by CI. See `NOTICE`.

## Building

```bash
make check      # lint + build + test; everything CI runs
make build
make test
make bench      # the §1 benchmark; see docs/benchmarks.md for setup
```

Requires Xcode 26.5+ and macOS 26+. Always go through `make` — it sets
`DEVELOPER_DIR`, without which `swift test` cannot find swift-testing.

## Privacy

Inherited from a+Terminal and non-negotiable: no analytics, no crash reporters,
no telemetry, no update pings, no third-party endpoints, in the library or the
daemon. The daemon writes no session content to disk; ring buffers are
memory-only and die with the process. Logs are opt-in, local, and redact PTY
content by default.

`scripts/check-privacy.py` fails the build on any of that appearing outside a
comment.

## Licence

MIT. See `LICENSE` and `NOTICE`.
