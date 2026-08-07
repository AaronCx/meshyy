// meshyy — what a restarted daemon owes a returning client (audit PR 3).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// launchd restarts meshyyd — on crash, on install-agent.sh, on logout, on
// update. Ring buffers are memory-only by design and the shells are the
// daemon's children, so both die with the process. A client holding an offset
// then reconnects into a daemon that has never heard of its session.
//
// The one outcome these tests exist to forbid is SILENT CONTINUITY: a client
// resuming into a fresh shell while the user believes it is their session.
// The daemon may legitimately mint a new session under the old name — but the
// client must be able to TELL, and the tell is the session id: a fresh
// PTYSession is a fresh UUID, and BootstrapResponse carries it.

import Foundation
import MeshyyCore
import MeshyyKit
import Testing
@testable import MeshyyDaemon

/// Lock-protected observation flags — same @unchecked Sendable shape as the
/// suite's EventLog, which is file-private to MeshyySessionTests.
private final class RefusalWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var failure = false
    private var output = false
    var sawFailure: Bool { lock.withLock { failure } }
    var sawOutput: Bool { lock.withLock { output } }
    func noteFailure() { lock.withLock { failure = true } }
    func noteOutput() { lock.withLock { output = true } }
}

extension MeshyyKitSuite {
    @Suite("Daemon restart")
    struct DaemonRestartTests {

        @Test("A restarted daemon refuses a stale QUIC token as unknown, not as an empty session")
        func staleTokenIsRefusedAfterRestart() async throws {
            // Daemon A issues a perfectly valid bootstrap...
            let before = try TestDaemonHarness(child: .shell)
            let boot = try before.bootstrap(session: "victim")
            // ...and dies before the client uses it. Everything it knew —
            // sessions, tokens, shells — dies with it.
            await before.shutdown()

            let after = try TestDaemonHarness(child: .shell)
            defer { Task { await after.shutdown() } }

            // The client walks in with daemon A's token and session id, but
            // daemon B's port and fingerprint (the realistic relaunch: the app
            // re-reads the daemon's coordinates, then tries its saved auth).
            var stale = try after.bootstrap(session: "unrelated")
            stale = BootstrapResponse(
                port: stale.port,
                token: boot.token,
                certSHA256: stale.certSHA256,
                sessionID: boot.sessionID,
                name: boot.name
            )
            let session = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
            let watch = RefusalWatch()
            let watcher = Task {
                for await event in await session.events {
                    switch event {
                    case .failed, .ended: watch.noteFailure()
                    case .output(let bytes) where !bytes.isEmpty: watch.noteOutput()
                    default: break
                    }
                }
            }
            defer { watcher.cancel() }

            var thrown = false
            do {
                try await session.attach(bootstrap: stale, sshHost: "127.0.0.1")
                // Attach not throwing is acceptable ONLY if the failure
                // arrives as an event; silence is not.
            } catch {
                thrown = true   // a thrown, typed refusal is the good outcome
            }
            if !thrown {
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline, !watch.sawFailure, !watch.sawOutput {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            #expect(thrown || watch.sawFailure,
                    Comment(rawValue: "a stale token must be REFUSED by a restarted daemon — "
                        + "attaching it to anything is the silent-continuity hole"))
            #expect(!watch.sawOutput,
                    "a refused client must receive NO session bytes")
            await after.shutdown()
        }

        @Test("Re-bootstrapping the old name after a restart is a NEW session, and says so")
        func rebootstrapMintsAVisiblyNewSession() async throws {
            let before = try TestDaemonHarness(child: .shell)
            let original = try before.bootstrap(session: "phoenix")
            await before.shutdown()

            let after = try TestDaemonHarness(child: .shell)
            defer { Task { await after.shutdown() } }
            let reborn = try after.bootstrap(session: "phoenix")

            // Same name — that is the user's label. Different SESSION: the id
            // is the continuity claim, and a fresh shell must never inherit
            // the old one's. This is what a client compares to turn "resuming"
            // into "your session is gone — this is a new one" instead of a
            // silent redraw that implies the shell survived.
            #expect(reborn.name == original.name)
            #expect(reborn.sessionID != original.sessionID,
                    Comment(rawValue: "a restarted daemon re-used a dead session's identity "
                        + "— a client can no longer detect that its session is gone"))
            await after.shutdown()
        }
    }
}
