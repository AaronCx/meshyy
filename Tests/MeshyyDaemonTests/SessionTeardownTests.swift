// meshyy — closing a session must leave nothing behind.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Measured before this existed: killing a session that had a FOREGROUND JOB
// leaked a permanent zombie 54 times out of 54, and one from cycle ~75 of a
// 200-cycle run was still `<defunct>` eight minutes later. The cause was an
// ordering the controlling-terminal change made load-bearing: a child holding
// the pty as its ctty cannot finish exiting while the daemon still has the slave
// open, so a single non-blocking `waitpid` always raced that exit and lost.

import Darwin
import Foundation
import Testing
@testable import MeshyyCore
@testable import MeshyyDaemon

@Suite("Session teardown", .serialized,
       .enabled(if: RealProcessTests.isEnabled, RealProcessTests.reason))
struct SessionTeardownTests {

    /// And it must not take a quarter of a second each time: the old grace loop
    /// watched the process GROUP, and `kill(-pid, 0)` on a group whose leader is a
    /// zombie answers EPERM rather than ESRCH — so the exit could never be
    /// observed and every close paid the full grace period with the store's actor
    /// blocked behind it.
    @Test("Closing a session does not pay the whole grace period")
    func closingIsPromptRatherThanTimedOut() async throws {
        let store = SessionStore(config: .deterministicEcho())
        _ = try await store.attachOrCreate(name: "teardown-prompt", size: .default)

        let start = Date()
        try await store.close(name: "teardown-prompt")
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.2, """
            closing an idle session took \(String(format: "%.3f", elapsed))s — the \
            grace loop is running to its deadline rather than observing the exit, \
            and it holds the session store's actor while it does
            """)
        await store.closeAll()
    }
}
