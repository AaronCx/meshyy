# Security

meshyyd holds PTYs and listens on a socket. It is the most security-sensitive
thing in this repo or its consumer, so this file is factual rather than
boilerplate: what the trust model is, what is exposed, and how to report a
hole in it.

## Trust model

- **Bootstrap is authenticated by SSH.** A client obtains a session the only
  way it can: over an SSH connection the user already authenticated, by asking
  the daemon's unix socket for a bootstrap. There is no other enrolment path.
- **The QUIC certificate is pinned transitively through the SSH host key.**
  The bootstrap response carries the daemon's certificate SHA-256; the client
  connects only to a peer presenting exactly that certificate. There is no CA,
  no trust store, and nothing to misissue — the fingerprint travelled over the
  channel the user's own pinned host key protects.
- **Tokens are single-use, 60-second, 256-bit, and bound to a session id.**
  Redeeming one names the session it was minted for; the client's claimed
  session in `Hello` is deliberately never honoured, because honouring it
  would let any valid token attach to any session (the confused-deputy hole
  the binding exists to close). An unknown token is refused; a valid token
  whose session died is refused as `sessionGone` — never treated as an empty
  session (pinned by `DaemonRestartTests`).

## Exposure

- **Default bind is not the world.** The daemon prefers loopback or the
  Tailscale interface. Binding all interfaces requires an explicit
  `bindAllInterfaces` flag, prints a startup warning, and
  `scripts/check-privacy.py` fails CI on any unguarded wildcard bind.
- **The private key lives in `~/.meshyy`,** two files, mode 0600 — created
  with that mode rather than fixed up afterwards.
- **Session content never touches disk.** Ring buffers are memory-only; the
  daemon logs no session bytes and prints no endpoints that could carry a
  token.

## Resume cannot be steered by a peer

Resume is driven entirely by the offset the client states in its own `Hello`.
The daemon files the acks a client sends but consults nothing from them when
deciding what to replay — `ackedOffset` lives on the attachment and dies with
it. This is deliberate: the client's own offset being the single source of
truth is what makes resume robust against a lying or buggy peer, and the
adversarial suite pins it — a forged ack cannot move another client's replay
point, walk an offset backwards, or resurrect a dead session.
(`docs/qa/test-inventory.md` §1g has the full analysis.)

## Reporting a vulnerability

Open a GitHub security advisory on this repository (preferred), or a plain
issue if the report is not sensitive. This is a solo-maintained project:
expect acknowledgement within a week. No fix window is promised — what is
promised is an honest answer about severity and timeline once the report is
understood.
