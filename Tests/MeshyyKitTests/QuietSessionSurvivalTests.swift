// meshyy — a session nobody is typing into must not die.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// THE BUG THIS EXISTS FOR, and it wore three disguises.
//
// `idleTimeout` is 5 seconds — deliberately short, because Network framework QUIC does
// not migrate paths and the timeout is the only thing that tells a client its session
// has gone deaf. That is safe ONLY while something keeps putting bytes on the wire. The
// heartbeat is that something.
//
// It used to return early when no `bootstrapProvider` was set, reasoning there was
// "nothing to reconnect with". But the loop has two jobs, and only one of them needs a
// provider. Detecting a dead path does. Keeping a live path alive does not.
//
// A client that drives its own reconnection — which the app does — therefore set no
// provider, sent no probes, and was dropped five seconds after the user stopped typing.
// It surfaced as: a "Reconnecting" flash every few seconds; a screen that flickered
// because every reconnect replays it; and a terminal that ignored its true size until
// one of those reconnects happened to send it. Three bug reports, one line.
//
// So the assertion here is deliberately about SURVIVAL rather than about probes being
// sent. Counting probes would pass on a client that sends them down a connection the
// timeout has already closed.

import Foundation
import MeshyyCore
import Testing
@testable import MeshyyKit

extension MeshyyKitSuite {
    @Suite("Quiet session survival")
    struct QuietSessionSurvivalTests {

        private actor Output {
            var text = ""
            func append(_ bytes: [UInt8]) { text += String(decoding: bytes, as: UTF8.self) }
            func contains(_ needle: String) -> Bool { text.contains(needle) }
        }

        /// THE PROPERTY. Silence for longer than the idle timeout must not cost the
        /// session.
        ///
        /// The wait is `idleTimeout` with room to spare, and no provider is set —
        /// exactly the app's configuration, which is the one that was broken.
        @Test("A session with no client-side reconnect survives a long silence")
        func quietSessionOutlivesTheIdleTimeout() async throws {
            try await withHarness(child: .shell) { daemon in
                let session = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
                let output = Output()
                let collector = Task {
                    for await event in await session.events {
                        if case .output(let bytes) = event { await output.append(bytes) }
                    }
                }
                defer { collector.cancel() }

                // No `bootstrapProvider`: this session cannot redial itself, and its
                // owner is expected to. That must not cost it its heartbeat.
                try await session.attach(
                    bootstrap: try daemon.bootstrap(session: "quiet"), sshHost: "127.0.0.1"
                )
                try await session.send(Array("printf '%s%s\\n' 'SHELL' '-READY'\n".utf8))
                var ready = false
                let readyBy = Date().addingTimeInterval(10)
                while Date() < readyBy, !ready {
                    ready = await output.contains("SHELL-READY")
                    if !ready { try await Task.sleep(for: .milliseconds(100)) }
                }
                #expect(ready, "the shell never came up, so there is nothing to keep alive")

                // Silence, for well over the 5s idle timeout. Nothing is typed and the
                // shell produces nothing: the ONLY traffic possible here is the
                // heartbeat.
                let silence = Duration.seconds(Double(MeshyyConnection.idleTimeoutMilliseconds) / 1000 * 1.6)
                try await Task.sleep(for: silence)

                // Still there? The session must answer, on the same connection.
                let marker = "STILL" + "-ALIVE-42"
                try await session.send(Array("printf '%s%s\\n' 'STILL' '-ALIVE-42'\n".utf8))
                var alive = false
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline, !alive {
                    alive = await output.contains(marker)
                    if !alive { try await Task.sleep(for: .milliseconds(100)) }
                }
                let seen = await output.text
                await session.shutdown(reason: "test finished")

                #expect(alive, """
                    the session did not survive \(silence) of silence, so the QUIC idle \
                    timeout closed it. Nothing was keeping the connection warm — which is \
                    what happens when the heartbeat is gated on being able to reconnect, \
                    because a client that reconnects for itself sets no provider and then \
                    gets no probes. The user sees "Reconnecting" every few seconds. \
                    Saw: \(seen.suffix(300).debugDescription)
                    """)
            }
        }
    }
}
