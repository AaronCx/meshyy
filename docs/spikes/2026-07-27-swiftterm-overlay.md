# M0 spike: can predicted cells be rendered without forking SwiftTerm?

**Date:** 2026-07-27
**Question (design doc §7.4, §10 M0, §12.2):** design doc §7.4 calls this "the
biggest unknown in the project" and demands it be answered now rather than in M6.
**Answer: yes, no fork needed — but one piece has to be replicated rather than
read, and that is the whole of the risk.**

Method: source reading of SwiftTerm at the revision a+Terminal currently pins
(`SwiftTerm-74b92343`, checked out under the app's SPM cache). SwiftTerm is MIT
(Miguel de Icaza; portions from xterm.js authors, SourceLair, Christopher
Jeffrey), so reading it is permitted and recorded in `docs/provenance.md`.

---

## What a shadow-model overlay needs, and whether it is reachable

Design doc §7.4 lists three options and rules out injected-and-retracted escape
sequences ("fragile, do not"). That leaves shadow model + render layer, or a
fork. Scoring the shadow-model option against SwiftTerm's public surface:

| Requirement | API | Access |
|---|---|---|
| Subclass or wrap the view | `open class TerminalView: UIScrollView` | **open** |
| Reach the emulator | `AppleTerminalView.getTerminal() -> Terminal` | **public** |
| Cursor cell | `Terminal.getCursorLocation() -> (x, y)` | **public** |
| Authoritative cell contents, to confirm or kill a prediction | `Terminal.getCharData(col:row:) -> CharData?` | **public** |
| Grid size | `Terminal.cols`, `Terminal.rows` | **public** (private setters) |
| Know when to invalidate the overlay | `TerminalViewDelegate.rangeChanged(source:startY:endY:)` | **public**, already implemented by a+Terminal |
| **Pixel geometry of one cell** | `cellDimension` | **internal — not reachable** |

Six of seven are public. Everything the prediction *logic* needs — predict,
confirm, kill on mismatch, kill on cursor move — is available. The only gap is
pixel geometry, and it is the one thing a render layer cannot do without.

## The gap, and the dead end that looked like a fix

`cellDimension` is declared `var cellDimension: CellDimension` in
`iOSTerminalView.swift` with no access modifier, so it is internal. A subclass
outside the module cannot see it either — Swift access control is
module-scoped, not inheritance-scoped.

`caretRect(for:)` looked like a free way out: `TerminalView` conforms to
`UITextInput`, so `caretRect(for:)` is public by protocol, and a caret rect is
by definition one cell. **It does not work.** The implementation in
`iOSTextInput.swift:341` is a stub:

```swift
public func caretRect(for position: UITextPosition) -> CGRect {
    return bounds
}
```

It returns the whole view. `selectionRects(for:)` immediately below it is the
same stub. Neither carries geometry.

## Recommendation

**Replicate the metric computation in the app, and upstream a one-line fix.**

a+Terminal owns the font — it hands SwiftTerm the `UIFont` — so it can compute
the same numbers SwiftTerm does. `computeFontDimensions()` in
`AppleTerminalView.swift` is short and stable in shape:

- width: the advancement of one glyph from the normal font (`"W"` on iOS)
- height: `ceil(lineAscent + lineDescent + lineLeading)`
- both snapped to the pixel grid: `ceil(value * scale) / scale`

Replicating that is roughly ten lines. The risk is **drift**: if SwiftTerm
changes the formula, the overlay misaligns by a subpixel and nobody notices until
predicted glyphs sit slightly wrong. Two mitigations, both cheap:

1. A unit test that asserts the replicated cell size against
   `terminal.cols == floor(viewWidth / cellWidth)` for a set of known widths.
   Drift breaks the test rather than the screen.
2. A PR to SwiftTerm making `cellDimension` `public private(set)`. It is MIT and
   actively maintained; this is a one-line change with no behavioural effect.
   Once it lands and a+Terminal's pin moves, delete the replication.

A fork remains unnecessary in every case.

## Why this is a smaller risk than §7.4 assumes

Design doc §7.4 calls this the biggest unknown in the project. On the evidence it
is the *smallest* of the open questions, for two reasons:

- It is confined to ten lines of geometry with a test that catches drift. It
  touches no protocol, no daemon, and no resume path.
- §7.3 already predicts that prediction will be **off** during a Claude Code
  session — raw mode plus alt-screen fails the §7.2 gate — and on only at a bare
  shell prompt. So the overlay affects a workflow the app is explicitly not
  centred on, and M1–M5 do not depend on it at all.

The genuinely large unknown is the one §7.3 names: whether prediction is
noticeable at Aaron's real RTT. That is an evening with real mosh from Blink
Shell over LTE, it is black-box observation and therefore permitted under §0.1,
and it needs a phone. It gates M6, not M0.

## Verdict

- §12.2 "Can SwiftTerm render an overlay without a fork?" — **yes.**
- No design change. §7.4's "shadow model plus a separate render layer" stands.
- One piece of debt recorded: replicated font metrics, with a drift test and an
  upstream PR as the exit.
- M6 stays gated on the §7.3 finding, which is a product question, not this one.
