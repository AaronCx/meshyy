// meshyy — protocol identity tests.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.

import Testing
@testable import MeshyyCore

@Suite("Protocol identity")
struct VersionTests {
    @Test("ALPN is meshyy's own, never a mosh identifier")
    func alpnIsDistinct() {
        #expect(Meshyy.alpn == "meshyy/1")
        #expect(!Meshyy.alpn.lowercased().contains("mosh"))
    }

    @Test("Protocol version is a positive integer")
    func versionIsPositive() {
        #expect(Meshyy.protocolVersion > 0)
    }
}
