// meshyy — full-clear and alt-screen detection (design doc §6.3, §7.1).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.

import Testing
@testable import MeshyyCore

private let clearScreen = Array("\u{1B}[2J".utf8)
private let clearScrollback = Array("\u{1B}[3J".utf8)
private let enterAlt = Array("\u{1B}[?1049h".utf8)
private let leaveAlt = Array("\u{1B}[?1049l".utf8)

@Suite("Screen scanner")
struct ScreenScannerTests {

    @Test("ESC[2J and ESC[3J are full clears; ESC[J and ESC[1J are not")
    func fullClearDetection() {
        for (sequence, isFullClear) in [
            ("\u{1B}[2J", true),
            ("\u{1B}[3J", true),
            ("\u{1B}[J", false),   // erase below the cursor
            ("\u{1B}[0J", false),
            ("\u{1B}[1J", false),  // erase above the cursor
            ("\u{1B}[2K", false),  // erase line, not display
        ] {
            var scanner = ScreenScanner()
            let events = scanner.scan(Array(sequence.utf8), startingAt: 0)
            #expect(events.contains(.fullClear(offset: 0)) == isFullClear,
                    "\(sequence.debugDescription) full clear should be \(isFullClear)")
        }
    }

    @Test("The clear offset points at the ESC, so replay re-executes the clear")
    func clearOffsetIsSequenceStart() {
        var scanner = ScreenScanner()
        let prefix = Array("some output\r\n".utf8)
        scanner.scan(prefix, startingAt: 0)
        let events = scanner.scan(clearScreen, startingAt: UInt64(prefix.count))
        #expect(events == [.fullClear(offset: UInt64(prefix.count))])
        #expect(scanner.lastFullRedrawOffset == UInt64(prefix.count))
    }

    @Test("Alt-screen enter and leave are tracked, including the legacy spellings")
    func altScreenModes() {
        for mode in ["1049", "1047", "47"] {
            var scanner = ScreenScanner()
            scanner.scan(Array("\u{1B}[?\(mode)h".utf8), startingAt: 0)
            #expect(scanner.altScreenActive, "mode \(mode) should enter alt screen")
            scanner.scan(Array("\u{1B}[?\(mode)l".utf8), startingAt: 100)
            #expect(!scanner.altScreenActive, "mode \(mode) should leave alt screen")
        }
    }

    @Test("An unrelated private mode does not toggle alt screen")
    func unrelatedPrivateModes() {
        var scanner = ScreenScanner()
        // 25 = cursor visibility, 1000 = mouse reporting, 2004 = bracketed paste.
        for mode in ["25", "1000", "2004", "1006"] {
            scanner.scan(Array("\u{1B}[?\(mode)h".utf8), startingAt: 0)
            #expect(!scanner.altScreenActive, "mode \(mode) must not be treated as alt screen")
        }
    }

    /// The subtle one. PTY reads split wherever the kernel decides, so a
    /// sequence straddling two reads must still be recognised. Every split point
    /// of every sequence of interest is checked.
    @Test("Tracked input modes are remembered, dropped on reset, and combined sequences count each")
    func modesAreTracked() {
        var scanner = ScreenScanner()
        // tmux arming a mouse client: combined set, two modes in one sequence.
        scanner.scan(Array("\u{1B}[?1000;1006h".utf8), startingAt: 0)
        #expect(scanner.activeModes == [1000, 1006])
        scanner.scan(Array("\u{1B}[?2004h\u{1B}[?1004h".utf8), startingAt: 14)
        #expect(scanner.activeModes == [1000, 1006, 2004, 1004])
        // Leaving copy-mode style: one reset drops only its mode.
        scanner.scan(Array("\u{1B}[?1006l".utf8), startingAt: 30)
        #expect(scanner.activeModes == [1000, 2004, 1004])
        // A mode nobody tracks changes nothing.
        scanner.scan(Array("\u{1B}[?2031h".utf8), startingAt: 38)
        #expect(scanner.activeModes == [1000, 2004, 1004])
    }

    @Test("A combined set split across chunks still lands every mode")
    func combinedSetSurvivesChunkBoundary() {
        var scanner = ScreenScanner()
        let sequence = Array("\u{1B}[?1000;1002;1006h".utf8)
        for (index, byte) in sequence.enumerated() {
            scanner.scan([byte], startingAt: UInt64(index))
        }
        #expect(scanner.activeModes == [1000, 1002, 1006])
    }

    @Test("Alt screen arriving in a combined sequence still anchors the redraw")
    func altScreenInCombinedSequence() {
        var scanner = ScreenScanner()
        scanner.scan(Array("\u{1B}[?1049;1000h".utf8), startingAt: 100)
        #expect(scanner.altScreenActive)
        #expect(scanner.activeModes == [1000])
        #expect(scanner.lastFullRedrawOffset == 100)
    }

    @Test("A sequence split across chunk boundaries is still detected")
    func splitAcrossChunks() {
        for sequence in [clearScreen, clearScrollback, enterAlt, leaveAlt] {
            for split in 1..<sequence.count {
                var scanner = ScreenScanner()
                var events: [ScreenScanner.Event] = []
                events += scanner.scan(Array(sequence[0..<split]), startingAt: 0)
                events += scanner.scan(Array(sequence[split...]), startingAt: UInt64(split))

                #expect(!events.isEmpty,
                        "split at \(split) of \(sequence.count) lost the event")
                // Whatever the split, the reported offset is the ESC at 0.
                switch events.first {
                case .fullClear(let offset), .altScreen(_, let offset):
                    #expect(offset == 0, "split at \(split) reported offset \(offset), want 0")
                case .mode, nil:
                    break   // mode events carry no offset
                }
            }
        }
    }

    @Test("One byte at a time still works")
    func byteAtATime() {
        var scanner = ScreenScanner()
        let stream = Array("hello\u{1B}[2Jworld\u{1B}[?1049h".utf8)
        var events: [ScreenScanner.Event] = []
        for (index, byte) in stream.enumerated() {
            events += scanner.scan([byte], startingAt: UInt64(index))
        }
        // "hello" is 5 bytes (0-4), ESC[2J occupies 5-8, "world" 9-13, so the
        // second ESC is at 14.
        #expect(events == [.fullClear(offset: 5), .altScreen(active: true, offset: 14)])
        #expect(scanner.altScreenActive)
    }

    @Test("Entering the alt screen sets the redraw anchor; leaving it does not")
    func anchorSemantics() {
        var scanner = ScreenScanner()
        scanner.scan(enterAlt, startingAt: 10)
        #expect(scanner.lastFullRedrawOffset == 10,
                "entering the alt screen repaints everything, so it is a valid anchor")

        scanner.scan(leaveAlt, startingAt: 200)
        // Leaving restores the primary screen from the application's own memory;
        // nothing after that point in the byte stream rebuilds it, so it is not
        // a usable anchor.
        #expect(scanner.lastFullRedrawOffset == 10, "leaving the alt screen must not set an anchor")
    }

    @Test("The anchor is refused when it has been evicted from the buffer")
    func anchorRespectsEviction() {
        var scanner = ScreenScanner()
        scanner.scan(clearScreen, startingAt: 100)
        #expect(scanner.replayAnchor(notOlderThan: 50) == 100)
        #expect(scanner.replayAnchor(notOlderThan: 100) == 100, "exactly at the edge is usable")
        #expect(scanner.replayAnchor(notOlderThan: 101) == nil, "an evicted anchor must be refused")
    }

    @Test("With no clear ever seen there is no anchor")
    func noAnchorWithoutClear() {
        var scanner = ScreenScanner()
        scanner.scan(Array("plain output with no escapes\r\n".utf8), startingAt: 0)
        #expect(scanner.lastFullRedrawOffset == nil)
        #expect(scanner.replayAnchor(notOlderThan: 0) == nil)
    }

    /// A hostile or broken stream must not make the scanner buffer without
    /// bound. It abandons the run and resynchronises at the next ESC.
    @Test("A runaway parameter run is abandoned, and the next real sequence still lands")
    func runawayParameters() {
        var scanner = ScreenScanner()
        let garbage = Array("\u{1B}[".utf8) + Array(repeating: UInt8(ascii: "9"), count: 5000)
        let events = scanner.scan(garbage, startingAt: 0)
        #expect(events.isEmpty)

        let after = scanner.scan(clearScreen, startingAt: UInt64(garbage.count))
        #expect(after == [.fullClear(offset: UInt64(garbage.count))],
                "the scanner must resynchronise after abandoning a runaway run")
    }

    @Test("ESC ESC restarts the sequence rather than losing the second one")
    func doubleEscape() {
        var scanner = ScreenScanner()
        let stream = Array("\u{1B}\u{1B}[2J".utf8)
        let events = scanner.scan(stream, startingAt: 0)
        #expect(events == [.fullClear(offset: 1)],
                "the second ESC begins the real sequence, at offset 1")
    }

    @Test("A two-character escape does not swallow what follows")
    func twoCharacterEscape() {
        var scanner = ScreenScanner()
        // ESC M (reverse index), then a real clear.
        let stream = Array("\u{1B}M".utf8) + clearScreen
        #expect(scanner.scan(stream, startingAt: 0) == [.fullClear(offset: 2)])
    }

    @Test("Realistic tmux attach traffic yields exactly one anchor and alt-screen state")
    func realisticTmuxTraffic() {
        var scanner = ScreenScanner()
        // Roughly what a tmux attach sends: smcup, clear, cursor moves, content.
        let stream = Array("\u{1B}[?1049h\u{1B}[2J\u{1B}[H\u{1B}[1;1Hprompt $ ".utf8)
        let events = scanner.scan(stream, startingAt: 0)
        #expect(events == [.altScreen(active: true, offset: 0), .fullClear(offset: 8)])
        #expect(scanner.altScreenActive)
        #expect(scanner.lastFullRedrawOffset == 8, "the later clear supersedes the alt-screen entry")
    }
}
