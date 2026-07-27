// meshyy — daemon test suite root.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.

import Testing
@testable import MeshyyDaemon

@Suite("Daemon")
struct DaemonSurfaceTests {
    @Test("Daemon reports a version")
    func hasVersion() {
        #expect(!MeshyyDaemon.version.isEmpty)
    }
}
