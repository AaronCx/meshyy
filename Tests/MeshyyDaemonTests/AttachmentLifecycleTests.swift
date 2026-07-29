// meshyy — attachment lifecycle races: the transport can die at any moment.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.

import Foundation
import Testing
@testable import MeshyyCore
@testable import MeshyyDaemon

@Suite("Attachment lifecycle", .serialized,
       .enabled(if: RealProcessTests.isEnabled, RealProcessTests.reason))
struct AttachmentLifecycleTests {

    /// The app sends Hello and is force-quit before the daemon finishes the attach:
    /// the transport's finish() runs first, and finish() is one-shot — whatever the
    /// in-flight attach stores afterwards, nothing will ever detach it. Verified red
    /// against the unconditional store: `attachedClients` read 1 for the session's
    /// whole life, so the survivor picker could never offer it, and its unbounded
    /// event stream buffered output with no consumer.
    @Test("A transport that dies before its attach completes leaves no phantom client")
    func finishBeforeAttachLeavesNoPhantom() async throws {
        let store = SessionStore(config: .deterministicEcho())
        let attachment = SessionAttachment(
            store: store,
            authority: .localSocket,
            send: { _ in },
            close: {}
        )

        // The transport dies FIRST, then the Hello it already carried is processed.
        // This is the deterministic ordering of the race; the mid-attach orderings
        // land in the same conditional store.
        attachment.finish()
        attachment.receive(.control(.hello(.init(
            token: "", cols: 80, rows: 24, session: "lifecycle"
        ))))

        // The attach may still create the session (it resolved before it learned the
        // transport was gone) — that is fine. What must NOT survive is a client count.
        var session: PTYSession?
        let created = Date().addingTimeInterval(10)
        while Date() < created, session == nil {
            session = await store.session(named: "lifecycle")
            if session == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let resolved = try #require(session, "the hello never even created the session")

        var clients = Int.max
        let settled = Date().addingTimeInterval(10)
        while Date() < settled {
            clients = await resolved.info.attachedClients
            if clients == 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(clients == 0, """
                a dead transport left a phantom attached client — this session can \
                never again be offered as detached, and its event buffer grows \
                unboundedly with nobody draining it
                """)
        await store.closeAll()
    }
}
