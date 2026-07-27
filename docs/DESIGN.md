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
in section 7.

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
    prediction engine                 alt-screen scanner
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

iOS suspension kills the connection. Nothing prevents that. QUIC connection
migration handles WiFi to LTE **while the app is in the foreground**. It does
not survive suspension.

So meshyy reconnects every time the app returns. What it saves is the SSH
handshake, the tmux attach, and the redraw. QUIC 0-RTT plus a resume token gets
first byte in roughly one round trip instead of five or six.

State this plainly in the README. Do not imply the connection survives
backgrounding, because it does not, and users will notice.

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

## 7. Predictive echo

This is where meshyy can be better than mosh rather than merely different.

### 7.1 The insight

mosh predicts blind. It cannot know whether the remote will echo a keystroke, so
it infers from the output stream and hedges with heuristics. That inference is
the bulk of its overlay engine's complexity and the source of its failure modes.

**meshyy does not have to guess.** The daemon owns the PTY. It can call
`tcgetattr` on the master fd and read the line discipline directly:

- `ECHO` set means the kernel will echo the character. Prediction is safe.
- `ICANON` set means line-buffered input, so the cursor advances predictably.
- Raw mode means the application handles input itself. Prediction is unsafe.

The daemon watches termios and pushes `Termios` frames on change. Poll at 50ms
while a prediction is outstanding, 500ms otherwise. It also scans output for
alt-screen enter and exit and pushes `ScreenMode`.

The client therefore knows, as fact rather than inference, whether it is safe to
predict. That is a real improvement and it is only available because both ends
are yours.

### 7.2 Rules (v1)

Predict only when **all** of:

- `echo == true`
- `icanon == true`
- `alt == false`
- smoothed RTT exceeds a threshold, default 120ms. Below that, prediction is
  invisible and only adds risk.

Predict only printable ASCII and backspace. Never predict across a newline.
Never predict control characters, escape sequences, or paste.

Render predicted cells with an underline attribute until confirmed.

**Kill all outstanding predictions and bump the epoch on:** any `Termios`
change, any `ScreenMode` change, any cursor-moving escape sequence in the
incoming stream, any mismatch between predicted and authoritative bytes, or
reconnect. On kill, the authoritative stream is truth and the screen resyncs.

Confirm silently when incoming bytes match the prediction at that position.

### 7.3 Honest expectation

Agent TUIs run in raw mode with alt-screen. Under the rules above, prediction
will be **off** during a Claude Code session and **on** at a bare shell prompt.
That is correct behavior, and it means the feature will do nothing in the
workflow the app exists for.

Build it anyway if you want it, but build it last, and know what you are buying.
Before starting M6, spend an evening driving real mosh from Blink Shell over LTE
against the same machine, and see whether prediction is noticeable at your actual
RTT. Record the finding in `docs/benchmarks.md`.

### 7.4 Integration risk

SwiftTerm owns the framebuffer. Overlaying predicted cells needs one of: a
shadow model plus a separate render layer, injected sequences that get retracted
(fragile, do not), or a SwiftTerm fork that understands an overlay. This is the
biggest unknown in the project. It is M0 spike work, not M6 work.

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

**M4. Roaming and fast reconnect.** QUIC 0-RTT, path change handling, connection
migration in foreground.
- Acceptance: WiFi to cellular switch mid-session with no visible interruption.
  Foreground-from-suspended shows first byte in under one RTT plus 50ms.

**M5. Agent events.** Termios watcher, alt-screen scanner, agent status on the
control stream, and the daemon pushing notifications to the user's own ntfy or
Pushover endpoint.
- Acceptance: a Claude Code permission prompt produces a phone notification in
  under two seconds, with a deep link back to the session.
- **This is the milestone that actually fixes the product gap. If only part of
  meshyy ever ships, ship M1 through M5.**

**M6. Predictive echo.** Per section 7. Gated on the section 7.3 finding.

**M7. Attachments.** Blob streams replace the separate SFTP round trip.

## 11. Testing

- **Property test (critical):** stream equality across arbitrary
  disconnect and reconnect sequences. Section 6.4.
- **Chaos harness:** a local proxy that injects loss, reorder, latency, and hard
  drops. Every milestone runs against it.
- **Golden protocol tests:** encoded frames as fixtures so wire format changes
  are visible in diffs.
- **Prediction tests:** scripted termios and output sequences, asserting
  predictions are made, confirmed, and killed at the right moments. No network.
- **Manual device matrix** in `docs/qa/`: background 5 minutes, airplane mode 60
  seconds, WiFi to LTE, daemon restart mid-session, buffer overrun, token
  expiry.

## 12. Open questions

1. Does Network framework's QUIC actually do connection migration on iOS? M0
   decides. If not, fall back to TCP+TLS and rely on 0-RTT resume alone, which
   costs little given section 6.1.
2. Can SwiftTerm render an overlay without a fork? M0 decides.
3. Ring buffer sizing. 4 MB is a guess. Instrument real sessions.
4. Multiple PTYs per connection: worth it, or does tmux already cover it?
5. Does the daemon need to survive its own restart with sessions intact? That
   means persisting PTY ownership, which is a large jump in complexity. Probably
   no for v1.
6. Linux daemon support. Deferred, but do not design anything that makes it
   impossible.

## 13. Risks

- **Prediction may never engage in the target workflow.** Section 7.3. This is
  known going in, not a surprise to discover in M6.
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
