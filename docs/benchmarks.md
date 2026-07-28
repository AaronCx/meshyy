# Benchmarks

## 2026-07-27 — Design doc §1 gate: what does a cold attach actually cost?

**Verdict: proceed, with one correction to the design doc's premise.**

### Method

`scripts/bench-attach.py` times the wall clock from `ssh` spawn to the moment a
known marker, repainted by `tmux attach -d`, reaches the client. Latency is
injected by `meshyy-chaos`, the in-tree userspace TCP proxy, because dummynet
needs root and this machine has no passwordless sudo (docs/provenance.md,
2026-07-27).

Two remote commands are swept so the multiplexer's share is separable:

- `exec` — `printf MARKER`. SSH connect, auth, channel, pty, exec, first byte.
- `attach` — `tmux attach -d -t meshyy-bench`. All of the above plus the
  multiplexer attach and a forced full repaint.

7 trials per cell after one discarded warm-up. OpenSSH 10.2p1 client, macOS
26.4.1 sshd on the same host, ed25519 key auth, tmux 3.6a.

**Proxy floor: none measurable.** `exec:direct` median 142.2 ms vs `exec:0`
median 143.0 ms — 0.8 ms, inside the noise. Nothing is subtracted from the
impaired runs.

### Raw results (median of 7, milliseconds)

| Injected RTT | `exec` | `attach` |
|---|---|---|
| direct (no proxy) | 142.2 | 136.8 |
| 0 ms | 143.0 | 136.5 |
| 40 ms | 538.7 | 556.1 |
| 80 ms | 865.4 | 874.5 |
| 150 ms | 1433.7 | 1446.6 |
| 250 ms | 2230.1 | 2244.1 |

Spread is tight — max/min within a cell never exceeds 6% — so the linear fit is
trustworthy.

### The number that matters

```
exec:   total = 183.3 ms + 8.26 x RTT
attach: total = 187.4 ms + 8.31 x RTT
```

**A cold attach pays about 8.3 network round trips.** That count is a property
of the SSH handshake, not of this machine or this client, so it is the part that
generalises.

### Correction to the design doc's premise

Design doc §1 attributes the cost to "SSH handshake plus tmux attach plus screen
redraw", and §6.1 says meshyy saves "the SSH handshake, the tmux attach, and the
redraw".

The data says the attach and the redraw are **free**: 4.1 ms and 0.05 round
trips over a bare `printf`. tmux is server-side, the attach happens inside a
channel that is already open, and the repaint of an 120x40 pane is one
buffer-full that rides the same window.

So the cost is ~100% SSH handshake and ~0% multiplexer. This does not weaken the
case — it sharpens it. It does mean two things:

1. Do not sell meshyy on "no reattach flicker". The flicker is real to look at
   but costs single-digit milliseconds. Sell it on the handshake.
2. §6.3's fallback of issuing tmux `refresh-client` when the ring buffer cannot
   cover the gap is cheaper than the design doc implies. That fallback is not a
   sad path worth engineering around; it costs about 4 ms.

### Gate decision

The doc's rule: 400 ms means close the project, two or three seconds means
proceed.

| RTT | measured/projected cold attach | meshyy target (1 RTT + 50 ms) | ratio |
|---|---|---|---|
| 2 ms (Tailscale LAN / WiFi) | ~204 ms | 52 ms | 3.9x |
| 40 ms | 520 ms | 90 ms | 5.8x |
| 60 ms (typical LTE) | 686 ms | 110 ms | 6.2x |
| 80 ms | 852 ms | 130 ms | 6.6x |
| 120 ms (congested cell) | 1185 ms | 170 ms | 7.0x |
| 150 ms | 1434 ms | 200 ms | 7.2x |

**Proceed**, but the honest reading is that the measured cost lands *between* the
doc's two thresholds rather than above the upper one. Three qualifications:

- **On a fast local network meshyy is not worth building.** At LAN RTT the whole
  cold attach is ~200 ms, which is under the doc's own 400 ms kill threshold.
  The win is specifically cellular, and specifically the tail: a congested cell
  at 120 ms RTT costs 1.2 s per foreground, dozens of times a day.
- **183 ms of fixed cost is a floor, not a forecast.** That is OpenSSH's C
  client against loopback sshd. a+Terminal uses Citadel/NIOSSH in Swift with a
  key unwrapped from the keychain, and the app has view setup and a SwiftTerm
  attach on top. The fixed term in the real app is higher; the round-trip count
  is the same.
- **A real radio adds cost this rig cannot emulate.** Injected delay is a
  constant. An LTE radio coming out of idle pays RRC connection setup on top,
  and it pays it on exactly the foreground-from-suspended transition meshyy
  targets. The 8.3 round trips is therefore also a floor.

### Still outstanding

- **The literal §1 measurement — a+Terminal, real LTE, real phone — has not been
  taken.** It needs the app on a device off WiFi and cannot be done headlessly.
  It is not a blocker: the RTT-scaling model above answers the gate question
  more generally than a single-point measurement would, and it predicts any RTT.
  Take the single point when convenient and check it against the table.
- ~~QUIC 0-RTT resume cost is asserted at 1 RTT + 50 ms, not measured.~~
  **Measured — see the second section below.** The answer is 2.06 round trips, and
  0-RTT turned out to be unreachable through Network framework entirely (design
  doc §6.1). The "1 RTT + 50 ms" target column in the gate table above was
  therefore optimistic; the honest comparison is in the second section.

### Reproducing

```bash
swift build
tmux new-session -d -s meshyy-bench -x 120 -y 40
ssh-keygen -t ed25519 -N '' -f ~/.ssh/meshyy_bench_ed25519 -C meshyy-bench
cat ~/.ssh/meshyy_bench_ed25519.pub >> ~/.ssh/authorized_keys
scripts/bench-attach.py --key ~/.ssh/meshyy_bench_ed25519 \
    --tmux "$(which tmux)" --trials 7 --rtts 0,40,80,150,250 \
    --json-out docs/bench/attach-$(date +%F).json
```

Raw JSON: `docs/bench/attach-2026-07-27.json`.
Remove the bench key from `~/.ssh/authorized_keys` afterwards.

---

## 2026-07-27 — QUIC round trips, measured through a UDP relay

**Result: a meshyy reconnect costs 2.06 round trips to the first application byte,
against SSH's 8.31. A 4x reduction in round trips, and no process spawn.**

### Method

The §1 harness could not do this: `ChaosTCPProxy` is TCP-only and QUIC is UDP. A
userspace UDP relay was written and validated first, because a relay that breaks
QUIC would produce numbers that mean nothing.

**The relay is sound.** Floor cost 0.3 ms (7.8 ms through it vs 7.5 ms direct) —
inside noise, so nothing is subtracted. Six concurrent QUIC connections each got
only their own payload back (`only-own=true`, 0 dropped, 0 rx errors). 4 MiB
echoed byte-identical at 5.5 MB/s with no truncation. And critically, a
**mismatched pin still fails through it** — TLS remains end-to-end, so the relay
is a delay line and not a middlebox.

7 trials per cell.

### Results (median, milliseconds)

| Injected RTT | QUIC handshake | + stream round trip |
|---|---|---|
| 0 (direct) | 7.5 | — |
| 0 (via relay) | 7.8 | 0.5 |
| 20 | 44.0 | 27.0 |
| 40 | 71.7 | 51.8 |
| 80 | 111.2 | 87.9 |
| 120 | 153.6 | 133.9 |
| 160 | 195.8 | 175.8 |
| 240 | 274.2 | 250.7 |

### The fits

```
handshake         = 27.6 ms + 1.038 x RTT
stream round trip =  9.1 ms + 1.019 x RTT
first app byte    = 36.7 ms + 2.06  x RTT
```

The relay saw an identical flight pattern at every RTT — C→S 2 packets/2400 B,
S→C 3/3090 B, C→S 4/1368 B, S→C 4/340 B, C→S 1/31 B — which is what makes the
1.04 and 1.02 coefficients trustworthy rather than curve-fitting noise.

### Against SSH

| | round trips to first byte | fixed cost |
|---|---|---|
| SSH + tmux attach (§1) | **8.31** | 187 ms |
| meshyy over QUIC | **2.06** | 37 ms |

| RTT | SSH + attach | meshyy | saved |
|---|---|---|---|
| 40 ms | 520 ms | 119 ms | 401 ms |
| 60 ms | 686 ms | 160 ms | 526 ms |
| 80 ms | 852 ms | 202 ms | 650 ms |
| 120 ms | 1185 ms | 284 ms | 901 ms |

**This is the project's central claim, now measured rather than assumed.** Note it
is a 4x reduction in round trips, not the 8x that "one round trip instead of five
or six" would have implied — see design doc §6.1, where the 0-RTT assumption that
produced that figure is corrected. 2.06 is what a combined transport+crypto
handshake actually costs.

### Loss tolerance

40 ms RTT, 8 trials per cell, median handshake:

| Loss | Median | Note |
|---|---|---|
| 0 | 62.1 ms | |
| 5% | 70.0 ms | |
| 10% | 68.7 ms | |
| 20% | 77.8 ms | still graceful |
| 30% | 393.0 ms | worst single trial 7078 ms |

**Every handshake completed at every level; nothing hung.** Up to 20% loss the
degradation is mild, which is the property that matters on a bad cell. At 30% the
tail explodes — worth knowing, not worth engineering for.

### Idle timeout, confirmed on the wire

Severing the path mid-session failed the connection after 30011 ms with
`POSIXErrorCode 60 (ETIMEDOUT)` — exactly `options.idleTimeout = 30000`, and
nothing sooner. That is the measurement behind the client dropping to a 5 s idle
timeout with keepalive: since Network framework QUIC does not migrate (design doc
§6.1), the idle timeout is the *only* thing that tells a client its session has
gone deaf, and 30 s of a frozen terminal is not acceptable.

### Reproducing

The relay prototype lives outside the tree, in the session scratchpad under
`udp-chaos/`. **Bringing it into `MeshyyChaos` as `ChaosUDPProxy` is outstanding
work** — it is what design doc §11's chaos harness needs, and until it lands the
§6.4 property test runs against injected disconnects in-process rather than
against a genuinely lossy path.
