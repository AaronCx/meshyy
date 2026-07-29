// meshyy — attachment truth and group allocation (the anti-wormhole suite).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// The bug these exist to keep dead: a client computed "which session is free"
// from its OWN bookkeeping — open tabs — while the sessions lived on the daemon
// and outlived the tabs. Every "new session" then resolved to the lowest slot the
// client had forgotten about, and the user was dropped into a shell that already
// belonged to someone. Design doc §3.1: never guess something the daemon can
// simply report. These tests pin both halves of the answer — the daemon reports
// attachment truthfully, and the daemon does the allocating.

import Foundation
import Testing
@testable import MeshyyCore
@testable import MeshyyDaemon

@Suite("Session inventory", .serialized,
       .enabled(if: RealProcessTests.isEnabled, RealProcessTests.reason))
struct SessionInventoryTests {

    @Test("A session nobody is attached to reports zero clients — with the notifier watching")
    func attachedClientsExcludesTheObserver() async throws {
        // The notifier is the vacuous-truth trap: it subscribes to EVERY session
        // for the session's whole life. If its subscription counted, no session
        // could ever read as detached, and a client filtering on
        // `attached_clients == 0` would simply never offer a resume. So this test
        // runs WITH a notifier configured, not without one.
        let store = SessionStore(config: .deterministicEcho(), notifier: AgentNotifier())
        let session = try await store.attachOrCreate(name: "inv-observer", size: .default)

        #expect(await session.info.attachedClients == 0,
                "the notifier's own subscription must not read as an attached client")

        let (_, _, token) = await session.attach(resumeFrom: nil)
        #expect(await session.info.attachedClients == 1)

        await session.detach(token)
        #expect(await session.info.attachedClients == 0,
                "a detached client must not linger in the count")
        await store.closeAll()
    }

    @Test("Group allocation takes the lowest free slot and reuses freed ones")
    func groupAllocationFillsGaps() async throws {
        let store = SessionStore(config: .deterministicEcho())
        let first = try await store.createLowestFree(inGroup: "inv-g-", size: .default)
        let second = try await store.createLowestFree(inGroup: "inv-g-", size: .default)
        let third = try await store.createLowestFree(inGroup: "inv-g-", size: .default)
        #expect(first.name == "inv-g-0")
        #expect(second.name == "inv-g-1")
        #expect(third.name == "inv-g-2")

        try await store.close(name: "inv-g-1")
        let reused = try await store.createLowestFree(inGroup: "inv-g-", size: .default)
        #expect(reused.name == "inv-g-1",
                "a freed slot is reused — tab positions, not an ever-growing counter")
        await store.closeAll()
    }

    @Test("A group allocation never lands in a session that already exists")
    func allocationSkipsNamedSessions() async throws {
        let store = SessionStore(config: .deterministicEcho())
        let occupant = try await store.attachOrCreate(name: "inv-mixed-0", size: .default)
        let fresh = try await store.createLowestFree(inGroup: "inv-mixed-", size: .default)
        #expect(fresh.name == "inv-mixed-1",
                "slot 0 already belongs to someone; 'new' must never resolve to it")
        #expect(fresh.sessionID != occupant.sessionID)
        await store.closeAll()
    }

    @Test("Racing allocations get distinct sessions")
    func concurrentAllocationsAreDistinct() async throws {
        // `createLowestFree` awaits while spawning the child, and an actor is
        // re-entrant across awaits — this is the test that the claim happens
        // before the suspension point. Verified red against a version with no
        // reservation: all EIGHT landed on the same name, because every
        // computation interleaved ahead of the first creation completing.
        let store = SessionStore(config: .deterministicEcho())
        let names = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await store.createLowestFree(inGroup: "inv-race-", size: .default).name
                }
            }
            var collected: [String] = []
            for try await name in group { collected.append(name) }
            return collected
        }
        #expect(Set(names).count == names.count,
                "two allocations shared a name: \(names.sorted())")
        await store.closeAll()
    }

    @Test("An unusable prefix is refused, not sanitised")
    func invalidPrefixIsRejected() async throws {
        let store = SessionStore(config: .deterministicEcho())
        await #expect(throws: SessionStore.StoreError.self) {
            _ = try await store.createLowestFree(inGroup: "bad prefix ", size: .default)
        }
        await store.closeAll()
    }
}
