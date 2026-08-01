// meshyy — a transport that dies must SAY so.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// The silent-death state this exists to prevent: a connection whose stream died
// reported `.closed` — the state a client uses for an end IT chose — so the
// session ignored it. The consumer was then left holding a transport that still
// said "connected", swallowed every byte written to it, and never reconnected,
// because the one event that would have driven recovery had been filed as a
// deliberate close.
//
// It is invisible from inside: nothing errors, nothing logs, the tab looks
// normal. The only way to see it is to kill the far side and assert that the
// session announces it.

import Foundation
import Synchronization
import Testing
@testable import MeshyyCore
@testable import MeshyyKit

extension MeshyyKitSuite {
    @Suite("Transport death is announced")
    struct TransportDeathTests {

        @Test("A daemon that vanishes mid-session produces a failure, not silence")
        func vanishedDaemonIsAnnounced() async throws {
            try await withHarness(child: .shell) { daemon in
                let bootstrap = try daemon.bootstrap(session: "death")
                let session = MeshyySession(size: TerminalSize(cols: 80, rows: 24))

                // ONE consumer of `events`, recording into a box. The first attempt
                // raced a reader task against a timeout task inside a task group and
                // wedged; the stream has a single consumer by design.
                let announcement = Mutex<String?>(nil)
                let seen = Mutex<[String]>([])
                let watcher = Task {
                    for await event in await session.events {
                        switch event {
                        case .failed(let reason):
                            announcement.withLock { $0 = "failed: \(reason)" }
                        case .ended(let reason):
                            announcement.withLock { $0 = "ended: \(reason)" }
                        case .output(let bytes):
                            seen.withLock { $0.append(String(decoding: bytes, as: UTF8.self)) }
                        default:
                            break
                        }
                    }
                }
                defer { watcher.cancel() }

                try await session.attach(
                    bootstrap: bootstrap, sshHost: "127.0.0.1", timeout: .seconds(10))
                // Prove the session is live first, or the assertion below could pass
                // against a session that never worked at all.
                try await session.send(Array("printf '%s%s\\n' 'DEATH' '-READY'\n".utf8))
                var live = false
                let liveBy = Date().addingTimeInterval(15)
                while Date() < liveBy {
                    if seen.withLock({ $0.joined() }).contains("DEATH-READY") { live = true; break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                #expect(live, "the session never came up, so the assertion below would prove nothing")

                // The far side goes away — a daemon restart, a killed process, a
                // path that black-holed. Not a Bye: nobody said goodbye.
                daemon.quic.stop()

                // Generous: the transport's own idle timeout is 5s, and this only
                // decides how long a genuine failure takes to report.
                var outcome: String?
                let deadline = Date().addingTimeInterval(20)
                while Date() < deadline {
                    outcome = announcement.withLock { $0 }
                    if outcome != nil { break }
                    try await Task.sleep(for: .milliseconds(200))
                }

                #expect(outcome != nil, """
                    the session never announced the daemon's disappearance — a consumer \
                    is left with a transport that looks connected, silently drops \
                    everything written to it, and never reconnects. \
                    events seen: \(seen.withLock { $0 })
                    """)
            }
        }
    }
}
