# Manual device matrix

Design doc §11 requires this list. Everything here needs a real iPhone, a real
radio, or both, and therefore cannot run in CI. Anything that *can* be automated
has been — see `swift test` (123 tests) and `docs/benchmarks.md`.

Record the build number in every result. A report against a build nobody can
identify is not a result.

## Why these are manual

The development Mac has one usable network interface and no radio. Three classes
of behaviour are structurally unreachable from it:

1. **Interface changes.** WiFi to cellular, and the QUIC connection migration
   Network framework may or may not perform. `nw_quic_migration_info_*` is
   entirely SPI, so even on a device the test can only assert the session
   survived — not that migration is what saved it.
2. **iOS suspension.** macOS does not suspend processes the way iOS does. Whether
   the per-process TLS resumption cache survives a foreground, and whether the
   app is suspended or jetsammed, are iOS scheduler decisions.
3. **Radio latency and its tail.** Injected delay is a constant. An LTE radio
   coming out of idle pays RRC connection setup, and it pays it on exactly the
   foreground transition meshyy targets.

## Matrix

| # | Case | Procedure | Pass condition |
|---|---|---|---|
| 1 | Background 30 s | Foreground the app after 30 s. | Session resumes. Scrollback continuous — no duplicated or missing lines around the seam. |
| 2 | Background 5 min | Same, after 5 minutes. | As above. Ring buffer default is 4 MB, so a quiet session must not need a rebuild. |
| 3 | Background 1 hour | Same, after an hour of heavy output. | Either resumes cleanly, or reports a rebuilt screen. **A silent gap is a failure.** |
| 4 | Airplane mode 60 s | Toggle airplane mode on, wait 60 s, off. | Session recovers without a manual reconnect. |
| 5 | WiFi to cellular | Turn WiFi off mid-session with an agent running. | No visible interruption, or a reported reconnect. Never a wedged session. |
| 6 | Cellular to WiFi | The reverse. | As above. |
| 7 | Daemon restart | `launchctl kickstart -k` the agent mid-session. | Client reports the session ended; a fresh attach gets a new session. No hang. |
| 8 | Buffer overrun | Run `yes` for a minute while backgrounded. | Screen is rebuilt and the client **says so**. Design doc §3.5. |
| 9 | Token expiry | Bootstrap, wait 70 s, then connect. | Refused with a clear message, not a hang. TTL is 60 s. |
| 10 | Token replay | Reuse a token that already attached. | Refused. Covered by a unit test too, but confirm the app surfaces it. |
| 11 | Wrong fingerprint | Point the app at a daemon whose identity was regenerated. | Refused, naming the fingerprint mismatch. Must not offer to continue. |
| 12 | Agent notification | Trigger a Claude Code permission prompt with the app backgrounded. | Notification within 2 s (M5 acceptance). Deep link opens that session. |
| 13 | Quick actions | Same prompt, app foregrounded. | Approve/deny/numeric buttons appear; one tap answers; buttons disappear when the prompt does. |
| 14 | Quick action withdrawal | Trigger a prompt, then Ctrl-C it. | Buttons disappear. A stale button is worse than none (§7.4). |
| 15 | First paint | Foreground from suspended. | Screen is already there — the app was suspended, not killed, so the emulator still holds the frame. Time to *live* is the metric that costs round trips. |
| 16 | Jetsam recovery | Force the app out of memory, reopen. | Screen is gone; a fresh attach shows the current screen from the daemon's buffer. Design doc §6.1 records that recovering the frame without a round trip would mean persisting session content to disk, which is not done. |

## The §1 single-point measurement

`docs/benchmarks.md` models cold-attach cost as `187 ms + 8.31 x RTT` from
injected-delay measurements. Take one real reading — app on cellular, cold attach
to this Mac — and check it against the table. If it lands far off, the model is
wrong and the benchmark needs redoing on a device.
