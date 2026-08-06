# meshyy

A resumable, roaming-tolerant terminal transport for a+Terminal.
Clean-room. MIT. Not mosh-compatible, deliberately.

**Status:** design. Nothing built. Read this whole document before writing code.

---

## 0. Non-negotiable rules

These come first because everything else is worthless if they are broken.

### 0.1 Clean-room

mosh is GPL-3.0. The entire point of meshyy is to have an MIT implementation, so
the codebase must never be derived from mosh's source.

**Prohibited, without exception:**

- Cloning, fetching, downloading, or extracting mosh's source. Not upstream
  (`mobile-shell/mosh`), not `blinksh/mosh`, not distro packaging, not a copy
  vendored inside some other project, not a tarball, not a GitHub code search
  result, not a Stack Overflow answer that pastes a function from it.
- Reading mosh's source in any form, including in a diff, a blog post that
  quotes it at length, or an LLM-generated summary of specific functions.
- Reading GPL or AGPL reimplementations, forks, or ports of mosh.
- Copying mosh's identifiers, file layout, message names, or comments.
- Adding any GPL, AGPL, or LGPL dependency to the tree.

**Permitted sources:**

- Winstein and Balakrishnan, "Mosh: An Interactive Remote Shell for Mobile
  Clients," USENIX ATC 2012. The paper describes the design. Designs and
  algorithms are not copyrightable; source code expression is.
- mosh's public website prose and man pages describing behavior.
- RFCs: 9000, 9001, 9002 (QUIC), 8446 (TLS 1.3).
- Apple platform documentation.
- POSIX termios and pty documentation.
- Any MIT, BSD, or Apache-2.0 licensed code, with attribution recorded.
- Observed behavior of a running mosh binary as a black box. Watching what it
  does on the wire or on screen is fine. Reading how it does it is not.

**Deliberate incompatibility.** meshyy does not aim for wire compatibility with
mosh. Compatibility would create constant pressure to consult the source to
resolve ambiguity, which is exactly the failure mode to avoid. Different
protocol, different framing, different name. The incompatibility is a feature.

**If the implementing agent believes it needs to see mosh's source to proceed,
it stops and asks a human. It never proceeds.**

### 0.2 Provenance log

Maintain `docs/provenance.md`. Every non-obvious design decision gets an entry:

```
## 2026-07-28 Ring buffer resume
Decision: resume by byte offset into a per-session ring buffer.
Source: original design. Paper describes screen-state sync (§3.2), which we
        rejected because we control both ends and want scrollback fidelity.
Consulted: USENIX ATC 2012 paper §3; RFC 9000 §2 (streams).
```

This log is the artifact that makes the clean-room claim defensible if anyone
ever asks. It costs two minutes per decision and it is not optional.

### 0.3 Licensing hygiene

- Every file carries an MIT header.
- `NOTICE` records every third-party component and its license.
- CI fails on any dependency whose license is not MIT, BSD-2, BSD-3, Apache-2.0,
  or ISC.
- No OCB mode. Use what TLS 1.3 gives you. This sidesteps an old patent question
  entirely and means there is no bespoke crypto to audit.

### 0.4 CLAUDE.md rules to paste into the repo

```markdown
## Clean-room policy (HARD RULE)

meshyy is a clean-room MIT implementation. mosh is GPL-3.0.

- NEVER clone, fetch, read, or grep mosh's source, any fork of it, or any
  GPL/AGPL reimplementation. This includes blinksh/mosh and distro packaging.
- Design ONLY from: the USENIX ATC 2012 paper, public man pages and prose,
  RFCs, Apple docs, and permissively licensed code.
- Do NOT aim for wire compatibility with mosh.
- Do NOT add GPL, AGPL, or LGPL dependencies.
- Record every design decision in docs/provenance.md with its source.
- If you think you need mosh's source to proceed: STOP and ask. Never proceed.

Running a mosh binary and observing its behavior as a black box is allowed.
Reading how it works is not.
```

---

## 1. Problem

iOS suspends a backgrounded app after roughly 30 seconds. The socket dies. On
foreground, a+Terminal pays a full SSH handshake, a multiplexer reattach, and a
screen redraw before the user can type.

The work is never lost, because tmux holds it server-side. The cost is latency
and flicker on every single return to the app, which on a phone is dozens of
times a day.

**Measure this before building anything.** Time SSH handshake plus tmux attach
plus first paint over LTE to the target machine. Record it in
`docs/benchmarks.md`. If it is 400ms, meshyy is not worth building and this
document should be closed. If it is two or three seconds, proceed.

## 2. Why not just use mosh

mosh solves this. It is GPL-3.0, which would force a+Terminal off MIT and into
a contested App Store licensing position. That is the entire reason meshyy
exists.

The secondary reason is that mosh was designed in 2012 for a different problem:
a drop-in SSH replacement that works against any host, over any UDP path, with
no cooperating software on either end beyond mosh itself. Every hard part of its
design follows from that constraint.

**meshyy controls both ends.** That single difference removes most of mosh's
complexity and enables the one thing meshyy can genuinely do better, described
in section 7 — which, after the measurement in §7.1, is one-tap agent actions
rather than the predictive echo this document originally proposed.

## 3. Design principles

1. **Own both ends and exploit it.** Never guess something the daemon can simply
   report.
2. **Sync bytes, not screens.** mosh syncs terminal state because it cannot
   assume a cooperating client. meshyy syncs the raw PTY byte stream, which is
   simpler, preserves scrollback exactly, and needs no server-side terminal
   emulator.
3. **Transport is replaceable.** The resume protocol is the core. QUIC is an
   accelerator, not the design. It must work over TCP+TLS too.
4. **One connection, many concerns.** The same connection carries PTY bytes,
   control, agent status events, and file transfer. The transport daemon and the
   notification daemon are the same daemon.
5. **Fail visible.** Never silently degrade. If resume is impossible, say so and
   redraw.
6. **Zero data collection**, inherited from a+Terminal and non-negotiable.

## 4. Architecture

```
iPhone                              Mac mini
------                              --------
a+Terminal                          meshyyd (launchd agent)
  MeshyyKit (Swift)                   PTY ownership
    QUIC/TLS client        <====>     ring buffer per session
    resume state                      termios watcher
    quick actions                     alt-screen scanner
  SwiftTerm renderer                  agent status hooks
  Citadel SSH (bootstrap only)        QUIC/TLS listener
```

`MeshyyCore` is a Swift package shared by both sides: wire format, framing,
session model, and the agent detection logic lifted out of a+Terminal
(`AgentActivityMonitor`, `stripANSI`, `endsAtShellPrompt`). One implementation,
compiled for iOS and macOS.

v1 daemon is macOS only, written in Swift, using Network framework on both ends.
Linux support is deferred and would need a different QUIC backend.

## 5. Protocol

### 5.1 Bootstrap

Reuse a+Terminal's existing SSH stack. Do not reimplement authentication.

1. Client connects over SSH. Host key pinning, key auth, and candidate-host
   fallback all apply unchanged.
2. Exec channel: `meshyyd attach --session <name> --json`
3. Daemon responds with JSON: `{"port": 41xxx, "token": "...", "cert_sha256":
   "...", "session_id": "...", "protocol": 1}`
4. SSH channel closes.
5. Client opens QUIC to `host:port`, pins the server cert against `cert_sha256`,
   and presents `token` in the first control frame.

The trust chain is clean: SSH's pinned host key transitively secures the QUIC
certificate fingerprint. No new trust decision is asked of the user, and no
certificate authority is involved.

Tokens are single-use, TTL 60 seconds, and bound to `session_id`.

### 5.2 Streams

QUIC gives multiplexing for free. Use it.

| Stream | Direction | Purpose |
|---|---|---|
| control (bidi, id 0) | both | handshake, resize, termios, screen mode, agent events, errors |
| pty:N (bidi) | both | raw PTY bytes for session N |
| blob:N (uni, client to server) | up | file and image attachments |

Control frames are length-prefixed CBOR. CBOR over JSON for compactness and
because it round-trips binary cleanly.

### 5.3 Control frames

```
Hello        { token, client_version, cols, rows, resume_from? }
Welcome      { session_id, server_version, buffered_from, buffered_to }
Resize       { cols, rows }
Ack          { pty_id, offset }          // client confirms consumption
Termios      { echo: bool, icanon: bool, raw: bool }
ScreenMode   { alt: bool }
AgentEvent   { kind: waiting|working|idle, agent_id?, detail? }
ResumeTooOld { pty_id, earliest_offset }
Bye          { reason }
Error        { code, message }
```

Everything is additive. Unknown frame types are ignored by both sides so version
skew degrades gracefully.

## 6. Resume

This is the core of the project. Get it right before anything else.

### 6.1 The honest constraint

iOS suspension kills the connection. Nothing prevents that.

**Corrected 2026-07-27: Network framework QUIC does not do connection migration
at all.** This section originally said migration "handles WiFi to LTE while the
app is in the foreground". Measured: a peer address change silently black-holes
the connection until the idle timeout fires, and the multiplex-group API exposes
no path, viability, or better-path signal to notice it with. §12.1's question is
answered **no**, not "foreground only".

Two consequences, both acted on:

- The idle timeout is the *only* signal that a session has gone deaf, so the
  client sets it to 5 s rather than leaving the 30 s default — at the default a
  user stares at a dead terminal for half a minute while the group still reports
  `.ready`.
- QUIC keepalive is enabled (2 s) on the client, which is what makes an idle
  timeout that short safe: without it a quiet-but-healthy session would be
  mistaken for a dead one.

Do **not** take §12.1's stated fallback of moving to TCP+TLS. QUIC is still the
right transport for §5.2's multiplexing and for a handshake that combines
transport and crypto. Only the migration assumption dies.

So meshyy reconnects every time the app returns. What it saves is the SSH
handshake and the process spawn behind it.

**Corrected 2026-07-27: QUIC 0-RTT is not reachable through Network framework.**
This section originally claimed "QUIC 0-RTT plus a resume token gets first byte in
roughly one round trip instead of five or six". Measured, that is wrong on both
halves. There is no public or private path that gets application bytes into
QUIC's first flight: `sec_protocol_options_set_tls_resumption_enabled` is inert
for QUIC, `allowFastOpen` with an `.idempotent` send is accepted and then never
sends early, and the only symbol that engages resumption at all is SPI and buys
about 13 ms of CPU — a fraction of a round trip, never a whole one.

The honest claim, which is still the headline win:

> A QUIC reconnect puts the first byte at the server in about 2 round trips and
> gets output back in about 2.7, with no process spawn. A cold SSH attach costs
> 8.3 round trips (docs/benchmarks.md) plus a shell and multiplexer start.

That win comes from QUIC combining the transport and crypto handshakes, and from
resuming a session that is already running, rather than from 0-RTT. Do not put
0-RTT in the README.

Also state plainly that the connection does not survive backgrounding, because it
does not, and users will notice.

One thing this section used to imply and should not: that the *screen* takes a
round trip to come back. It does not. iOS suspends the app rather than killing it,
so the emulator still holds the frame and first paint on foreground is
effectively free. What costs round trips is the session becoming *live* again —
new output arriving and keystrokes landing. If the app is jetsammed rather than
suspended the screen is genuinely gone, and recovering it without a network round
trip would mean persisting session content to disk, which is a privacy decision
(§9) and not currently taken.

### 6.2 Ring buffer

The daemon keeps a per-session ring buffer of raw PTY output with a monotonic
byte offset. Default 4 MB, configurable.

- Client sends `Ack {offset}` periodically, at most every 250ms.
- On reconnect, client sends `Hello {resume_from: offset}`.
- Daemon replays from that offset. The client feeds the bytes to SwiftTerm
  exactly as if they had arrived live. Scrollback stays correct, which mosh
  cannot do because it syncs screen state and hands scrollback to tmux.

### 6.3 When the gap is too large

If `resume_from` predates the buffer, the daemon replies `ResumeTooOld`. Rather
than dumping megabytes, the daemon tracks the offset of the most recent
full-screen clear or alt-screen entry by scanning output for `ESC[2J`,
`ESC[3J`, and `ESC[?1049h`. This is a stateless byte scan, not a terminal
emulator. Replay from that offset if it is inside the buffer.

If even that fails, the client clears, and issues the multiplexer's refresh
(tmux `refresh-client`) via the existing profile machinery.

### 6.4 Correctness invariant

For any sequence of writes, disconnects, and reconnects, the byte stream the
client delivers to SwiftTerm must equal the byte stream the daemon read from the
PTY. No gaps, no duplicates, no reordering.

This is a property test, and it is the single most important test in the
project. Write it in M3 and never let it go red.

## 7. Quick actions

This is where meshyy can be better than mosh rather than merely different.

### 7.1 The measurement that reshaped this section

The original design for this section was predictive local echo, on the reasoning
that the daemon owns the PTY and can therefore call `tcgetattr` and *know*
whether the kernel will echo a keystroke, rather than inferring it the way a
drop-in SSH replacement must. The gate was: predict only when `ECHO` and
`ICANON` are set and the alternate screen is off.

That reasoning is sound. The conclusion drawn from it was wrong. Measured on a
real PTY, reading `c_lflag` on the master:

| Program | ECHO | ICANON | gate opens? |
|---|---|---|---|
| `/bin/sh` (bash 3.2, readline) | false | false | **no** |
| `bash -i` | false | false | **no** |
| `zsh -i` | false | false | **no** |
| `zsh -f -i` (no rc files) | false | false | **no** |
| `tmux attach` | false | false | **no** |
| `cat` | true | true | yes |
| `sed -u` | true | true | yes |

Readline and zle are line editors. To do history, completion and highlighting
they must see each keystroke as it arrives and control exactly what appears, so
the first thing either does is take the terminal out of cooked mode and echo
characters itself. **The echo you see at a shell prompt is the shell drawing, not
the kernel.** `ECHO` was never on.

So the gate never opens: not in an agent TUI, and not at a bare shell prompt
either. Prediction would have been dead code in every configuration a+Terminal is
used in. The full write-up, including the harness, is
`docs/spikes/2026-07-27-line-discipline.md`.

Two things follow. First, the *capability* is real and the *inference* was
wrong — the daemon does read the line discipline correctly, it just always
learns "no". Second, the "better than mosh" claim does not survive: what needs
predicting is the **shell's** echo, and the shell does not publish its
intentions, so predicting it means inferring from the output stream. That is
mosh's approach and where mosh's complexity lives. Owning both ends does not
help, because the line editor is on neither end.

### 7.2 The right target

Predictive echo was aimed at the wrong latency.

The interaction that actually happens, dozens of times a day, is not typing a
long command into a shell prompt. It is answering an agent: approving a tool
call, denying one, picking option 2 of 3. On a phone that costs finding the key
on a software keyboard, hitting it accurately, and checking it landed — human
latency that dwarfs the 60–120 ms of network RTT prediction was trying to hide.

**Quick actions:** the client shows one-tap buttons — approve, deny, and the
numeric choices — driven off the agent profile. Zero typing, zero prediction.

Why this is strictly better than what it replaces:

- **It works exactly where prediction cannot.** Agents run in raw mode with the
  alternate screen up. That is the case the §7.1 gate rules out and the case the
  product exists for.
- **It removes more latency.** Prediction hid one RTT of echo. This removes a
  keyboard interaction.
- **It needs no overlay.** No shadow cell model, no separate render layer, no
  replicated font metrics, no SwiftTerm fork. §7.4's "biggest unknown in the
  project" is retired by being unnecessary rather than solved.
- **Agent identity stays data.** Actions come from `AgentProfile`, so supporting a
  new agent is a profile entry, not code.

### 7.3 Design

The daemon already scans PTY output for agent state (§5.3 `AgentEvent`, M5) and
for alternate-screen transitions (§6.3). Quick actions ride the same machinery.

- `AgentProfile` gains `quickActions`: an ordered list of
  `{ id, label, matches: [String], sends: [UInt8] }`.
- When a profile's `matches` appear in the recent output tail, the daemon emits
  `QuickActions { actions: [{id, label}] }` on the control stream.
- The client renders them in the key accessory bar. A tap sends that action's
  `sends` bytes on the PTY channel — byte for byte what the user's own keystroke
  would have sent.
- The offer is withdrawn — `QuickActions { actions: [] }` — on any full-screen
  clear, any alternate-screen transition, or when the matched text leaves the
  tail. The invalidation signals already exist for the resume anchor.

**Two rules that are not negotiable.**

1. **Label and payload come from the local profile, never from remote output.**
   Output only selects *which* profile action matches. Otherwise a hostile or
   merely confused remote could draw text that looks like a permission prompt and
   have the daemon offer a button whose payload it chose — a one-tap confused
   deputy. The remote picks the question; only local data may write the answer.
2. **Never auto-answer.** A quick action is a manual action with fewer taps. The
   daemon must not send an action's bytes on its own for any reason, including a
   timeout. This is a privacy-and-agency product; deciding on the user's behalf
   is out of scope for good.

### 7.4 Honest expectation

This is a real win but a modest one, and it is worth stating what it is not: it
does not reduce round trips, it does not make the transport faster, and it does
nothing for a session that is not running a recognised agent.

It also depends on profile quality. A profile whose `matches` are too loose will
offer buttons at the wrong moment, which is worse than offering none — so
matching should be conservative and each profile needs a test with real captured
output. Design doc §11 gains a case for it.

The M6 milestone in §10 replaces predictive echo with this. The mosh comparison
in §7.1 is no longer a reason to build M6 at all; it is only a reason to be
careful if anyone ever revisits prediction. If prediction is revisited, the entry
point is bracketed-paste mode (`ESC[?2004h`), which readline and zle both set and
which is a genuine signal that a line editor is at a prompt — bounded inference
against two known programs rather than open-ended heuristics.


## 8. Security model

- Bootstrap over SSH, so authentication is a solved problem inherited from
  a+Terminal.
- QUIC means TLS 1.3. No bespoke crypto, nothing novel to audit.
- Self-signed server cert, fingerprint pinned via SSH. No CA.
- Single-use tokens, 60s TTL, bound to a session id.
- Daemon binds to the Tailscale interface or loopback by default. Binding to
  `0.0.0.0` requires an explicit config flag and a startup warning.
- Session ids are 128-bit random. Resume requires both the session id and a
  fresh SSH-issued token, so a stolen session id alone is useless.
- The daemon holds PTYs and listens on a socket. It is the most
  security-sensitive thing in either project. Treat it that way: no shell
  invocation with interpolated strings, no `eval`, explicit argv everywhere.

## 9. Privacy invariants

Inherited from a+Terminal and equally binding here.

- No analytics, no crash SDKs, no telemetry, no update pings, no third party
  endpoints. Not in the app, not in the daemon.
- The daemon writes no session content to disk. The ring buffer is memory only
  and dies with the process.
- Logs are opt-in, local, and redact PTY content by default.
- CI greps both trees for `https?://`, `analytics`, `telemetry`, `sentry`,
  `crashlytics`, and fails on any hit outside comments and license headers.

## 10. Milestones

Each lands green and independently useful.

**M0. Spikes.** Two throwaway prototypes, one week, no production code.
- QUIC client and listener over Network framework, macOS to iOS, including
  connection migration across a WiFi to LTE switch. Confirm it works before
  designing around it.
- SwiftTerm overlay feasibility. Can predicted cells be rendered without forking
  it? Answer this now, not in M6.
- Acceptance: written findings in `docs/spikes/`. Either may kill or reshape the
  design, which is the point.

**M1. Daemon skeleton.** `meshyyd` under launchd. Owns a PTY, spawns a shell,
reads and writes. No network. CLI tool talks to it over a unix socket.
- Acceptance: `meshyyd attach` gives a working local shell.

**M2. Transport.** MeshyyCore wire format, control stream, QUIC listener and
client, SSH bootstrap, a+Terminal renders a live session. No resume yet.
- Acceptance: a session over meshyy is indistinguishable from a session over SSH.

**M3. Resume.** Ring buffer, offsets, acks, `ResumeTooOld`, clear-screen anchor.
- Acceptance: the section 6.4 property test passes under a chaos harness that
  injects loss, latency, and hard disconnects. Background the app for 5 minutes,
  foreground, and the session resumes with correct scrollback.

**M4. Reconnect triggering and correctness.** *(Rewritten. The name change is the
point: reconnect **speed** is solved and measured at 2.06 round trips, essentially
optimal without 0-RTT. What was unsolved is **when** the reconnect fires. The
original M4 — 0-RTT, migration, "first byte in under one RTT + 50 ms" — contained
no achievable clause once M0 established that Network framework QUIC has neither
0-RTT nor migration.)*

Three signals, none redundant:
- **4a. Path change.** `NWPathMonitor` reports interface transitions; act on the
  announcement rather than waiting for a timeout to confirm what the OS already
  said. Deduplicated on a path *signature*, because updates arrive that change
  nothing about reachability and a redial storm is worse than the stall it avoids.
- **4b. Heartbeat.** `ping`/`pong` on the control stream, 1 s interval, dead after
  3 misses. Covers what 4a structurally cannot see: a NAT rebind announces
  nothing. Gated on a confirming pong so an older daemon is not redialled forever.
- **4c. Foreground.** `applicationWillEnterForeground()`, a public entry rather
  than a UIKit observer — MeshyyKit builds for macOS too.
- **4d. Single-flight and backoff.** All three fire within a few hundred ms of an
  airplane-mode toggle, and each redial spends a single-use token.

- Acceptance, met in-tree: a black-holed session recovers with no user action and
  the §6.4 property holding across the seam; exactly one reconnect in flight under
  a burst of every trigger, asserted rather than observed.
- Acceptance, **outstanding**: the device clauses. Radio transitions, jetsam and
  backgrounding cannot be measured on loopback. See §10.1.

**M5. Agent events.** Termios watcher, alt-screen scanner, agent status on the
control stream, and the daemon pushing notifications to the user's own ntfy or
Pushover endpoint.
- Acceptance: a Claude Code permission prompt produces a phone notification in
  under two seconds, with a deep link back to the session.
- **This is the milestone that actually fixes the product gap. If only part of
  meshyy ever ships, ship M1 through M5.**

**M6. Quick actions.** *(Rewritten into two tiers. Predictive echo is dropped per
the §7.1 measurement, not deferred.)*
- **Tier 1, built: a fixed keystroke palette.** `y n Enter Esc 1 2 3 Ctrl-C`,
  offered whenever the agent is waiting, with **no screen parsing**. It cannot
  break when an agent's UI changes because it never looked at the UI. These are
  terminal universals, not agent knowledge, which is how "no agent name and no
  prompt string hardcoded in Swift" is satisfied.
- **Tier 2, deliberately not built: labelled actions from declared prompt
  patterns.** Data, never code, following `AgentProfile.detectionMarkers`.
  Screen-scraping an alt-screen TUI demos well once and then breaks silently on
  the next upstream release.
- The gate lives in `MeshyySession`, not the UI: a hidden button is not a
  guarantee, and a tap that arrives after the agent moves on must fail rather than
  land in the middle of what it went on to do.
- **Actionable notifications are a separate milestone, not a clause here.** A
  lock-screen "Approve" reaching the daemon adds an inbound HTTP surface that
  executes input into a live PTY; it needs a per-session capability token,
  tailnet-only binding and a fixed keystroke allowlist.

**M7. Attachments. Deferred, deliberately — not merely unstarted.** Blob streams
would replace the separate SFTP round trip. The SFTP path works today and is in
active daily use; M7 rewrites a functioning subsystem to save one round trip on
an operation performed a handful of times a day, and spends solo-maintainer
capacity that §13 already flags as the real risk. Revisit only if the SFTP path
develops an actual problem.

## 10.1 What remains

Everything above is merged and green except the following, which is stated here
rather than left implied:

- **M4's device acceptance.** WiFi→LTE mid-session, airplane mode for 60 s,
  foreground after 5 minutes suspended, and a simulated NAT rebind, each on a
  physical iPhone with the §6.4 property asserted. Loopback cannot produce a
  radio transition or a jetsam kill, so this is not something the in-tree suite
  can discharge.
- **Integration.** *(Done — kept for the record.)* a+Terminal speaks meshyy as
  an opt-in transport, merged to its main and shipping on TestFlight since
  build 62 (2026-08-06). M4's device clauses are therefore unblocked: the only
  thing between here and discharging them is a physical iPhone and a human.
- **M6 tier 2** and **M7**, both open and unstarted by intent. That is the
  correct end state, not an incomplete one.

## 11. Testing

- **Property test (critical):** stream equality across arbitrary
  disconnect and reconnect sequences. Section 6.4.
- **Chaos harness:** a local proxy that injects loss, reorder, latency, and hard
  drops. Every milestone runs against it.
- **Golden protocol tests:** encoded frames as fixtures so wire format changes
  are visible in diffs.
- **Quick action tests:** captured real agent output, asserting the right actions
  are offered, that they are withdrawn on a clear or an alt-screen transition, and
  that a label or payload is never taken from remote output. No network.
- **Manual device matrix** in `docs/qa/`: background 5 minutes, airplane mode 60
  seconds, WiFi to LTE, daemon restart mid-session, buffer overrun, token
  expiry.

## 12. Open questions

1. ~~Does Network framework's QUIC actually do connection migration on iOS?~~
   **Answered: no.** Not on macOS 26, in either direction — a peer address change
   black-holes the connection until the idle timeout, and no path or viability
   signal is exposed to detect it. §6.1 has the correction and the two mitigations
   (short idle timeout, keepalive). The stated fallback of moving to TCP+TLS was
   **not** taken: QUIC still earns its place on multiplexing and a combined
   handshake, and TCP+TLS would not migrate either.
2. ~~Can SwiftTerm render an overlay without a fork?~~ **Resolved and now moot.**
   M0 found it feasible without a fork (`docs/spikes/2026-07-27-swiftterm-overlay.md`),
   and §7's move to quick actions removes the need for an overlay at all.
3. ~~Ring buffer sizing. 4 MB is a guess.~~ **Still open, and still a guess.** No
   real-session instrumentation exists, because nothing real runs on meshyy yet —
   see §10.1. Not answerable before integration, and dishonest to close before then.
4. ~~Multiple PTYs per connection: worth it, or does tmux already cover it?~~
   **Answered: tmux covers it.** The §1 benchmark measured `tmux attach` as free
   inside the 8.31-RTT SSH cost, and the multiplexer matrix already works. The
   frame format carries a `ptyID` so this stays possible, but building a second
   multiplexer to replace a working one is the M7 mistake in a different costume.
5. ~~Does the daemon need to survive its own restart with sessions intact?~~
   **Answered: no for v1.** Persisting PTY ownership across a restart is a large
   jump in complexity, and the failure it protects against — a daemon restart —
   is rare and already visible to the user, which §3.5 says is the acceptable
   kind. A tmux session inside meshyy survives it anyway, which is the honest
   mitigation.
6. Linux daemon support. Deferred, but do not design anything that makes it
   impossible.

## 13. Risks

- **Predictive echo was unreachable, and this was found by measuring rather than
  by shipping it.** Section 7.1. Replaced by quick actions, whose own risk is
  profile quality: matching too loosely offers a button at the wrong moment, which
  is worse than offering none.
- **The daemon is new attack surface** on a privacy-branded product. It holds
  PTYs and listens on a port. A vulnerability here is worse than anything in the
  app.
- **Solo maintainer load.** This is a second codebase, a second release process,
  and a second CVE surface, alongside an App Store app, an unreleased VNC
  feature, and grad school. The honest mitigation is the M5 stopping point: M1
  through M5 is a coherent, shippable product on its own, and M6 and M7 are
  optional.
- **Scope drift into rebuilding mosh.** Every time a decision starts with "well,
  mosh does it this way," check it against section 0.1 and against whether you
  actually need it.

## 14. Naming

meshyy is distinct enough from mosh to support the clean-room story, which is
useful. Do not describe it anywhere as a mosh clone, a mosh port, or
mosh-compatible. It is an independent implementation of a similar idea. That
phrasing is both accurate and the one you want on record.
