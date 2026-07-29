// meshyy — a replay must not impose the geometry it was captured at.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// THE BUG THIS EXISTS FOR, because it took six builds and a user's patience to find.
//
// The ring buffer holds a byte STREAM, and a byte stream carries the geometry of the
// terminal that produced it. The most damaging piece is DECSTBM — `ESC[top;bottom r` —
// which tells the emulator which rows it may paint. A full-screen application sets it
// constantly; tmux sets it on almost every frame.
//
// So replaying a stream captured at 24 rows into a client that is 60 rows tall leaves
// `ESC[1;24r` as the last word on the subject, and the emulator then refuses to paint
// anything below row 24 however tall it is. The user sees a terminal that draws its top
// portion and leaves the rest black, permanently, and no amount of resizing fixes it
// because the size was never the problem.
//
// It does not happen over plain SSH, because SSH never replays anything. That
// asymmetry — "it only breaks on meshyy" — was the clue that identified it, after four
// wrong theories aimed at the rendering path.
//
// The fix is a reset of the state that is geometry-dependent and NOT content, appended
// after every replay. It restores nothing about what is on screen; it only stops a
// stale frame dictating where the next one may be drawn.

import Foundation
import MeshyyCore
import Testing
@testable import MeshyyDaemon
@testable import MeshyyKit

@Suite("Replay geometry")
struct ReplayGeometryTests {

    /// The reset must touch margins and modes, and must NOT clear anything.
    ///
    /// `ESC[2J`, `ESC[3J` or `ESC c` here would throw away the very content the replay
    /// just restored — which would trade a black lower half for a blank screen.
    @Test("The geometry reset restores the full window without erasing anything")
    func resetIsGeometryOnly() {
        let bytes = TerminalGeometry.reset
        let text = String(decoding: bytes, as: UTF8.self)

        #expect(text.contains("\u{1B}[r"), "must reset the scroll region to the whole window")
        #expect(text.contains("\u{1B}[?6l"), "origin mode must go back to absolute addressing")
        #expect(text.contains("\u{1B}[?7h"), "autowrap must be on, or long lines vanish at the margin")

        for destructive in ["\u{1B}[2J", "\u{1B}[3J", "\u{1B}c", "\u{1B}[H\u{1B}[J"] {
            #expect(!text.contains(destructive),
                    "the reset erases content (\(destructive.debugDescription)) — it must only release geometry, never discard what the replay restored")
        }
    }

    /// `ESC[r` with no parameters is what means "the whole window". With parameters it
    /// is another confinement, which is the thing being undone.
    @Test("The scroll-region reset carries no parameters")
    func resetHasNoParameters() {
        let bytes = TerminalGeometry.reset
        // Find ESC [ … r and require the parameter run to be empty.
        var index = 0
        var found = false
        while index < bytes.count - 2 {
            if bytes[index] == 0x1B, bytes[index + 1] == 0x5B {
                var cursor = index + 2
                var parameters = ""
                while cursor < bytes.count, (0x30...0x3B).contains(bytes[cursor]) {
                    parameters.append(Character(UnicodeScalar(bytes[cursor])))
                    cursor += 1
                }
                if cursor < bytes.count, bytes[cursor] == 0x72 {
                    found = true
                    #expect(parameters.isEmpty,
                            "ESC[\(parameters)r confines drawing to rows \(parameters) — the reset must be the unparameterised form")
                }
                index = cursor
            } else {
                index += 1
            }
        }
        #expect(found, "no scroll-region reset in the sequence at all")
    }

    /// The ordering is the entire fix: the reset is worthless before the replay.
    ///
    /// Measured end to end against a live daemon while diagnosing this — a 60-row
    /// client received a replay whose last parameterised region was `1;24` at byte
    /// 1587, and the reset at byte 1966. This asserts the property that made that
    /// ordering correct, so a refactor that moves the reset earlier fails here rather
    /// than on a user's phone.
    @Test("A stale region followed by the reset leaves the full window in force")
    func resetMustComeAfterTheReplay() {
        // A replay captured at 24 rows, as tmux would leave it.
        let captured = Array("\u{1B}[1;24r\u{1B}[24;1Hprompt$ ".utf8)
        let delivered = captured + TerminalGeometry.reset

        func lastScrollRegion(in bytes: [UInt8]) -> (offset: Int, parameters: String)? {
            var index = 0
            var last: (Int, String)?
            while index < bytes.count - 2 {
                if bytes[index] == 0x1B, bytes[index + 1] == 0x5B {
                    var cursor = index + 2
                    var parameters = ""
                    while cursor < bytes.count, (0x30...0x3B).contains(bytes[cursor]) {
                        parameters.append(Character(UnicodeScalar(bytes[cursor])))
                        cursor += 1
                    }
                    if cursor < bytes.count, bytes[cursor] == 0x72 { last = (index, parameters) }
                    index = cursor
                } else {
                    index += 1
                }
            }
            return last
        }

        let last = lastScrollRegion(in: delivered)
        #expect(last?.parameters.isEmpty == true, """
            the last scroll-region command in the delivered stream is \
            "\(last?.parameters ?? "none")" — a client would be confined to those rows, \
            which is the black-lower-half bug
            """)
        // And the same stream WITHOUT the reset is the broken case, so the assertion
        // above is not passing for some unrelated reason.
        #expect(lastScrollRegion(in: captured)?.parameters == "1;24",
                "the fixture no longer reproduces the original condition")
    }
}


@Suite("Replay geometry, on the wire")
struct ReplayGeometryWireTests {
    /// The reset must not be counted as resumed output, or the client's offset runs
    /// ahead of the buffer and the next resume skips real bytes.
    @Test("Applying the reset does not advance the resume offset")
    func resetDoesNotMoveTheOffset() async {
        let session = MeshyySession()
        await session.resetForAttach(resumeFrom: nil)
        _ = await session.handle(.control(.replayBase(ptyID: 0, offset: 0)))
        let payload = Array("hello".utf8)
        _ = await session.handle(.pty(0, payload))
        let before = await session.consumedOffset

        // Returns nothing: the return value is the RESUMED stream, and these bytes were
        // generated here rather than resumed. The emulator receives them through the
        // event stream, which is what production renders from.
        let counted = await session.handle(.control(.resetGeometry))
        #expect(counted.isEmpty, """
            the reset appeared in the resumed-byte accounting — that breaks §6.4 \
            byte-exactness and makes the offset arithmetic disagree with itself
            """)
        #expect(await session.consumedOffset == before, """
            applying the geometry reset advanced consumedOffset — the client would resume \
            past bytes the daemon still holds, and lose them silently
            """)
    }

    /// Additive, per §5.3, so an older peer ignores it instead of failing.
    @Test("The frame round-trips and is inert to a peer that does not know it")
    func frameRoundTrips() throws {
        let encoded = ControlFrame.resetGeometry.encoded
        #expect(try ControlFrame.decode(encoded) == .resetGeometry)
    }
}
