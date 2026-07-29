// meshyy — daemon-side session allocation, end to end over the real bootstrap.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// The client-visible half of the anti-wormhole work (SessionInventoryTests is the
// store-level half): `attach --new-in-group` must come back with a name the client
// can hold onto, the name must be a genuinely fresh session, and the named path
// must keep echoing its name so both flows report the same shape.

import Foundation
import Testing
@testable import MeshyyCore
@testable import MeshyyDaemon

extension MeshyyKitSuite {
    @Suite("Group allocation over the bootstrap")
    struct GroupAllocationTests {

        @Test("Asking for a new session in a group allocates the lowest free name")
        func newInGroupAllocates() async throws {
            try await withHarness { daemon in
                let first = try daemon.bootstrap(newInGroup: "aplus-h-")
                let second = try daemon.bootstrap(newInGroup: "aplus-h-")
                #expect(first.name == "aplus-h-0")
                #expect(second.name == "aplus-h-1")
                #expect(first.sessionID != second.sessionID,
                        "two 'new' requests must never share a shell")
            }
        }

        @Test("Allocation never lands in a session someone created by name")
        func allocationSkipsNamedSessions() async throws {
            try await withHarness { daemon in
                let named = try daemon.bootstrap(session: "aplus-mix-0")
                let fresh = try daemon.bootstrap(newInGroup: "aplus-mix-")
                #expect(fresh.name == "aplus-mix-1",
                        "slot 0 already belongs to someone; 'new' must never resolve to it")
                #expect(fresh.sessionID != named.sessionID)
            }
        }

        @Test("The named path echoes its name, so both flows report the same shape")
        func namedBootstrapEchoesName() async throws {
            try await withHarness { daemon in
                let response = try daemon.bootstrap(session: "echo-check")
                #expect(response.name == "echo-check")
            }
        }
    }
}
