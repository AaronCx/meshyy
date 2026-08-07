// meshyy — the lane rule that keeps control and pty frames ordered on QUIC.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// QUIC orders bytes within a stream and promises nothing across streams. The
// protocol's ordering guarantees span control and pty frames in both
// directions — a `modes` frame corrects the output around it, a `resize` is
// ordered against keystrokes — so those two kinds must share a stream, and
// only blobs (which nothing orders against the terminal) get their own.
//
// This is a one-line property, and it is pinned because it was once wrong in
// a way no test could see: output switched from the hello stream to a second
// stream the moment the client first typed, and from then on every
// modes/termios frame raced the pty bytes around it — invisible on loopback,
// real under loss.

import MeshyyCore
import Testing

struct WireLaneTests {

    @Test("Control and pty share a lane; blobs do not")
    func laneAssignment() {
        #expect(ChannelKind.control.wireLane == .control)
        #expect(ChannelKind.pty.wireLane == .control)
        #expect(ChannelKind.blob.wireLane == .blob)
    }

    @Test("Every kind maps to a lane that is itself a stable lane")
    func lanesAreFixedPoints() {
        for kind in ChannelKind.allCases {
            // A lane must be its own lane, or routing would depend on how many
            // times it was applied.
            #expect(kind.wireLane.wireLane == kind.wireLane)
        }
    }
}
