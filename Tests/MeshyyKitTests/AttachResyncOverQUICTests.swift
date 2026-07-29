// meshyy — the size resync must survive the whole attach path, not just the PTY call.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// `AttachResyncTests` in the daemon target proves `PTY.resyncSize` signals the
// foreground process group. That is the mechanism, not the feature: a client attaching
// over QUIC has to actually reach it, through `SessionAttachment.begin` and the session
// actor, and it did not before — that path called `resize`, which returns early when the
// size has not changed and was therefore the whole bug.
//
// So this drives it the way the app does: attach, leave, attach again at the SAME size,
// and check that a program inside the session was told. Wiring is exactly what this
// covers, so it must not be faked by calling the PTY directly.

import Foundation
import MeshyyCore
import Testing
@testable import MeshyyKit

extension MeshyyKitSuite {
    @Suite("Attach resync over QUIC")
    struct AttachResyncOverQUICTests {

        private actor Output {
            var text = ""
            func append(_ bytes: [UInt8]) { text += String(decoding: bytes, as: UTF8.self) }
            func contains(_ needle: String) -> Bool { text.contains(needle) }
        }

        /// THE PROPERTY, end to end: reattaching at an unchanged size still tells the
        /// program inside the session what that size is.
        ///
        /// Against the old code the second attach did nothing whatsoever — the size
        /// matched what the session had recorded, so there was no ioctl and no signal —
        /// and a full-screen program that had drifted stayed wrong for the life of the
        /// session. That is the terminal that never fills the screen again.
        @Test("Reattaching at the same size still tells the program the size")
        func reattachAtSameSizeSignalsTheChild() async throws {
            try await withHarness(child: .shell) { daemon in
                let size = TerminalSize(cols: 74, rows: 39)
                let name = "resync-quic"

                let first = MeshyySession(size: size)
                let output = Output()
                let collector = Task {
                    for await event in await first.events {
                        if case .output(let bytes) = event { await output.append(bytes) }
                    }
                }
                defer { collector.cancel() }

                try await first.attach(bootstrap: try daemon.bootstrap(session: name), sshHost: "127.0.0.1")
                // A trap makes the signal observable. Without it SIGWINCH is delivered
                // and silently ignored, and the test could only assert on what the
                // daemon believes — which was right all along.
                try await first.send(Array("trap 'stty size' WINCH\n".utf8))
                try await Task.sleep(for: .milliseconds(900))
                await first.detach(reason: "the app was suspended")
                collector.cancel()

                // Back, at exactly the size the session already has recorded.
                let second = MeshyySession(size: size)
                let resumed = Output()
                let secondCollector = Task {
                    for await event in await second.events {
                        if case .output(let bytes) = event { await resumed.append(bytes) }
                    }
                }
                defer { secondCollector.cancel() }
                try await second.attach(bootstrap: try daemon.bootstrap(session: name), sshHost: "127.0.0.1")

                var told = false
                let deadline = Date().addingTimeInterval(8)
                while Date() < deadline, !told {
                    // "39 74" is `stty size` output: rows then columns.
                    told = await resumed.contains("39 74")
                    if !told { try await Task.sleep(for: .milliseconds(100)) }
                }
                let seen = await resumed.text
                await second.shutdown(reason: "test finished")

                #expect(told, """
                    reattaching at an unchanged size did not tell the program the size. \
                    The attach path is calling `resize`, which returns early when nothing \
                    changed — so a program that drifted out of sync can never be corrected, \
                    however many times the client reconnects with the right number. \
                    Saw: \(seen.suffix(300).debugDescription)
                    """)
            }
        }
    }
}
