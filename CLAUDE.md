# meshyy — CC environment notes

Resumable, roaming-tolerant terminal transport for a+Terminal.
Design doc: `docs/DESIGN.md`. Read it before writing code.

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

## Build rules

- Pure SwiftPM. No Xcode project, no XcodeGen.
- **Always go through `make`.** `xcode-select` on this Mac points at
  CommandLineTools, and swift-testing ships only with the Xcode toolchain, so a
  bare `swift test` fails with `no such module 'Testing'`. The Makefile exports
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; a raw `swift`
  invocation needs the same prefix. (`swift build` happens to work without it,
  which makes this easy to get wrong — `swift test` is the one that breaks.)
- Platforms: macOS 26+, iOS 26+. `meshyyd` and the `meshyy` CLI are macOS only;
  `MeshyyCore` and `MeshyyKit` build for both.
- `make check` runs everything CI runs. Do this before every push.

## CI-gated commands (pre-flight these locally)

```
make lint      # licence allowlist + privacy grep + MIT header check
make build     # swift build
make test      # swift test
make check     # all three
```

Baseline: all green, zero known-flaky tests. If something is red, it is a real
regression — do not push past it.

## Constraints

- **Zero dependencies.** `Package.swift` has an empty `dependencies:` array and
  CI enforces it. If you think you need a package, that is a design discussion,
  not a commit.
- **Zero data collection.** No analytics, no crash SDKs, no telemetry, no update
  pings, no third-party endpoints — not in the library, not in the daemon. CI
  greps for this and fails on a hit.
- The daemon writes no session content to disk. Ring buffers are memory-only.
- Every source file carries the MIT header. CI enforces it.
- `meshyyd` holds PTYs and listens on a socket: explicit argv everywhere, no
  shell invocation with interpolated strings, no `eval`.

## Testing

- `MeshyyCoreTests/StreamEqualityTests` is the §6.4 correctness invariant. It is
  the single most important test in the project. Never let it go red, never
  weaken it to make something else pass.
- Golden wire fixtures are the `goldens` table in
  `Tests/MeshyyCoreTests/ControlFrameTests.swift`. A diff there means the wire
  format changed — a deliberate act with a `Meshyy.protocolVersion` bump
  considered, never a fixup to make a test pass.
- When you add a CI gate, plant a violation and confirm it fails. The privacy
  gate shipped once as a regex that silently ate the `//` in `https://` and
  passed vacuously; `scripts/check-privacy.py` is a real scanner because of it.
