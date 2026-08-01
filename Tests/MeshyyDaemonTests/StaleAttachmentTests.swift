// meshyy — telling a live client from a corpse the transport has not reaped.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// The user-visible failure: "the 'a session is still running' prompt doesn't
// appear for my FIRST session, but subsequent ones get it." A force-quit phone
// leaves its QUIC peer on the daemon until the idle timeout (30s), still counted
// in `attachedClients` — so on relaunch the survivor looks like someone else's
// live screen, gets filtered out of the picker, and the app quietly opens a new
// session instead. Wait long enough and the corpse expires, which is exactly why
// the SECOND session behaves.
//
// A count alone cannot express this. The daemon reports how long the most recent
// client has been silent, and silence past the client's own 1s heartbeat is what
// separates "someone is there" from "nobody is, yet".

import Foundation
import Testing
@testable import MeshyyCore
@testable import MeshyyDaemon

@Suite("Stale attachments", .serialized,
       .enabled(if: RealProcessTests.isEnabled, RealProcessTests.reason))
struct StaleAttachmentTests {

    @Test("A quiet attached client is reported as quiet, and traffic resets it")
    func quietTimeIsReported() async throws {
        let store = SessionStore(config: .deterministicEcho())
        let session = try await store.attachOrCreate(name: "stale-1", size: .default)
        let (_, _, token) = await session.attach(resumeFrom: nil)

        let fresh = await session.info
        #expect(fresh.attachedClients == 1)
        #expect((fresh.clientQuietFor ?? .greatestFiniteMagnitude) < 1,
                "a client that has just attached must not read as quiet")

        try await Task.sleep(for: .milliseconds(1500))
        let aged = await session.info
        #expect((aged.clientQuietFor ?? 0) >= 1.4, """
            a client that has said nothing for 1.5s reported \
            \(String(describing: aged.clientQuietFor)) — without this, a force-quit \
            phone's lingering peer is indistinguishable from a live screen and its \
            session is never offered back
            """)

        // Any frame counts as proof of life, including the ping a merely-watching
        // client sends.
        await session.noteClientActivity(token)
        let revived = await session.info
        #expect((revived.clientQuietFor ?? .greatestFiniteMagnitude) < 0.5,
                "traffic from a client did not reset its quiet time")

        #expect(fresh.attachedClients == 1)
        await store.closeAll()
    }

    @Test("No clients means no quiet time to report")
    func detachedSessionReportsNoQuietTime() async throws {
        let store = SessionStore(config: .deterministicEcho())
        let session = try await store.attachOrCreate(name: "stale-2", size: .default)
        let (_, _, token) = await session.attach(resumeFrom: nil)
        await session.detach(token)

        let info = await session.info
        #expect(info.attachedClients == 0)
        #expect(info.clientQuietFor == nil,
                "a session nobody is attached to has no client to be quiet")
        await store.closeAll()
    }
}
