// meshyy — full-clear and alt-screen detection by byte scan (design doc §6.3, §7.1).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Design doc §6.3: "This is a stateless byte scan, not a terminal emulator."
// Almost true — it carries a partial escape sequence across chunk boundaries,
// because PTY reads split wherever the kernel feels like it and a sequence
// straddling two reads must still be seen. That is a few bytes of state, not a
// screen model: no grid, no cursor, no scrollback, no parsing of anything the
// two questions below do not need.
//
// The two questions:
//   1. Where was the most recent point the whole screen was thrown away? Replay
//      from there is as good as replay from the beginning (§6.3).
//   2. Is an alternate-screen application running? If so, do not predict (§7.2).

import Foundation

/// Scans a PTY output stream for the two events resume and prediction depend on.
public struct ScreenScanner: Sendable {
    public enum Event: Sendable, Equatable {
        /// A sequence that discards the visible screen (`ESC[2J`) or the
        /// scrollback (`ESC[3J`). `offset` is where the sequence *starts*, so
        /// replaying from it re-executes the clear.
        case fullClear(offset: UInt64)
        /// Alternate screen entered or left.
        case altScreen(active: Bool, offset: UInt64)
    }

    /// Parser position. Only enough to reassemble one CSI sequence.
    private enum State: Sendable, Equatable {
        case ground
        /// Saw ESC.
        case escape
        /// Inside `ESC[`; accumulating parameter and intermediate bytes.
        case csi(parameters: [UInt8])
    }

    /// A CSI parameter run longer than this is not a sequence meshyy cares
    /// about, so the scanner gives up on it rather than growing without bound.
    /// The longest sequence of interest is `ESC[?1049h` — four parameter bytes.
    private static let maximumParameterBytes = 24

    private var state: State = .ground
    /// Absolute offset of the ESC that began the sequence in progress.
    private var sequenceStart: UInt64 = 0

    /// Offset of the most recent full clear or alt-screen entry, which is the
    /// anchor design doc §6.3 replays from when the client's offset is too old.
    public private(set) var lastFullRedrawOffset: UInt64?
    public private(set) var altScreenActive = false

    public init() {}

    /// Feeds `bytes`, which begin at absolute `offset`, and returns what it saw.
    @discardableResult
    public mutating func scan(_ bytes: [UInt8], startingAt offset: UInt64) -> [Event] {
        var events: [Event] = []

        for (index, byte) in bytes.enumerated() {
            let absolute = offset + UInt64(index)

            switch state {
            case .ground:
                if byte == 0x1B {
                    state = .escape
                    sequenceStart = absolute
                }

            case .escape:
                if byte == 0x5B { // '['
                    state = .csi(parameters: [])
                } else if byte == 0x1B {
                    // ESC ESC: the second one starts a fresh sequence.
                    sequenceStart = absolute
                } else {
                    // Two-character escape. Nothing here is of interest.
                    state = .ground
                }

            case .csi(var parameters):
                if (0x40...0x7E).contains(byte) {
                    // Final byte: the sequence is complete.
                    if let event = Self.classify(
                        parameters: parameters,
                        final: byte,
                        offset: sequenceStart
                    ) {
                        apply(event)
                        events.append(event)
                    }
                    state = .ground
                } else if parameters.count >= Self.maximumParameterBytes {
                    // Runaway parameter run: abandon and resynchronise at the
                    // next ESC rather than buffering it.
                    state = .ground
                } else {
                    parameters.append(byte)
                    state = .csi(parameters: parameters)
                }
            }
        }

        return events
    }

    private mutating func apply(_ event: Event) {
        switch event {
        case .fullClear(let offset):
            lastFullRedrawOffset = offset
        case .altScreen(let active, let offset):
            altScreenActive = active
            // Entering the alternate screen repaints everything, so it is just
            // as good an anchor as a clear. Leaving it is not: the application
            // restores the primary screen from *its* memory, and nothing in the
            // byte stream after that point rebuilds what was there.
            if active { lastFullRedrawOffset = offset }
        }
    }

    /// Maps a completed CSI sequence to an event, or nil for the vast majority
    /// that are neither a full clear nor an alt-screen toggle.
    private static func classify(
        parameters: [UInt8],
        final: UInt8,
        offset: UInt64
    ) -> Event? {
        switch final {
        case 0x4A: // 'J' — erase in display
            // CSI 2 J clears the visible screen, CSI 3 J the scrollback.
            // A bare CSI J (erase below the cursor) is not a full redraw.
            let text = String(decoding: parameters, as: UTF8.self)
            return (text == "2" || text == "3") ? .fullClear(offset: offset) : nil

        case 0x68, 0x6C: // 'h' set / 'l' reset — private modes
            guard parameters.first == 0x3F else { return nil } // '?'
            let mode = String(decoding: parameters.dropFirst(), as: UTF8.self)
            // 1049 is what tmux, vim and every modern TUI use. 47 and 1047 are
            // the older spellings, still emitted by some curses builds — cheap
            // to accept, and missing one would leave prediction on inside a TUI.
            guard ["1049", "1047", "47"].contains(mode) else { return nil }
            return .altScreen(active: final == 0x68, offset: offset)

        default:
            return nil
        }
    }

    /// Best offset to replay from when the client's own offset is gone.
    ///
    /// Returns the last full-redraw anchor if the buffer still holds it,
    /// otherwise nil — and nil means the client must clear and ask the
    /// multiplexer to repaint (design doc §6.3). The benchmark says that
    /// fallback costs about 4 ms, so it is not a path worth dreading.
    public func replayAnchor(notOlderThan earliest: UInt64) -> UInt64? {
        guard let anchor = lastFullRedrawOffset, anchor >= earliest else { return nil }
        return anchor
    }
}
