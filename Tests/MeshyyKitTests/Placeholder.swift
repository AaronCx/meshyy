// meshyy — client test suite root.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.

import Testing
@testable import MeshyyKit

@Suite("Kit")
struct KitSurfaceTests {
    @Test("Kit reports a version")
    func hasVersion() {
        #expect(!MeshyyKit.version.isEmpty)
    }
}
