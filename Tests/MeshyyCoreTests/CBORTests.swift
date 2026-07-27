// meshyy — CBOR subset conformance and hostile-input rejection.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.

import Testing
@testable import MeshyyCore

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func bytes(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map {
        let start = hex.index(hex.startIndex, offsetBy: $0)
        let end = hex.index(start, offsetBy: 2)
        return UInt8(hex[start..<end], radix: 16)!
    }
}

@Suite("CBOR")
struct CBORTests {

    // MARK: - Encoding matches RFC 8949 §3 exactly

    /// Test vectors taken from RFC 8949 Appendix A. If any of these drift the
    /// encoder is no longer CBOR, whatever else still passes.
    @Test("Unsigned integers use the shortest head", arguments: [
        (0, "00"), (1, "01"), (10, "0a"), (23, "17"),
        (24, "1818"), (25, "1819"), (100, "1864"), (255, "18ff"),
        (256, "190100"), (1000, "1903e8"), (65535, "19ffff"),
        (65536, "1a00010000"), (1_000_000, "1a000f4240"),
        (4_294_967_295, "1affffffff"), (4_294_967_296, "1b0000000100000000"),
    ])
    func unsignedVectors(value: Int, expected: String) {
        #expect(hex(CBOR.unsigned(UInt64(value)).encode()) == expected)
        #expect(try! CBOR.decode(bytes(expected)) == .unsigned(UInt64(value)))
    }

    @Test("Negative integers encode as -1-n", arguments: [
        (-1, "20"), (-10, "29"), (-24, "37"), (-25, "3818"), (-100, "3863"),
        (-1000, "3903e7"),
    ])
    func negativeVectors(value: Int, expected: String) {
        #expect(hex(CBOR.negative(Int64(value)).encode()) == expected)
        #expect(try! CBOR.decode(bytes(expected)) == .negative(Int64(value)))
    }

    @Test("Text, bytes, bool and null match the RFC vectors")
    func simpleVectors() {
        #expect(hex(CBOR.text("").encode()) == "60")
        #expect(hex(CBOR.text("a").encode()) == "6161")
        #expect(hex(CBOR.text("IETF").encode()) == "6449455446")
        #expect(hex(CBOR.bytes([]).encode()) == "40")
        #expect(hex(CBOR.bytes([1, 2, 3, 4]).encode()) == "4401020304")
        #expect(hex(CBOR.bool(false).encode()) == "f4")
        #expect(hex(CBOR.bool(true).encode()) == "f5")
        #expect(hex(CBOR.null.encode()) == "f6")
    }

    @Test("Arrays and maps match the RFC vectors")
    func collectionVectors() {
        #expect(hex(CBOR.array([]).encode()) == "80")
        #expect(hex(CBOR.array([.unsigned(1), .unsigned(2), .unsigned(3)]).encode()) == "83010203")
        #expect(hex(CBOR.map([]).encode()) == "a0")
        #expect(hex(CBOR.map([(.unsigned(1), .unsigned(2)), (.unsigned(3), .unsigned(4))]).encode())
                == "a201020304")
    }

    @Test("Multi-byte UTF-8 round-trips as bytes, not scalars")
    func utf8RoundTrip() {
        // A prompt with a glyph outside ASCII, plus an emoji — both realistic in
        // a terminal and both easy to corrupt with a naive length calculation.
        for text in ["❯ ", "水", "🙂", "café", "ĝood"] {
            let encoded = CBOR.text(text).encode()
            #expect(try! CBOR.decode(encoded) == .text(text), "round trip failed for \(text)")
        }
    }

    // MARK: - Round trips

    @Test("Nested structures round-trip")
    func nestedRoundTrip() {
        let value = CBOR.map([
            (.text("t"), .text("hello")),
            (.text("cols"), .unsigned(120)),
            (.text("nested"), .array([.bool(true), .null, .bytes([0xFF, 0x00])])),
        ])
        #expect(try! CBOR.decode(value.encode()) == value)
    }

    @Test("Map lookup is by text key and returns nil for absent keys")
    func mapLookup() {
        let value = CBOR.map([(.text("a"), .unsigned(1)), (.text("b"), .text("two"))])
        #expect(value["a"]?.intValue == 1)
        #expect(value["b"]?.stringValue == "two")
        #expect(value["missing"] == nil)
        #expect(CBOR.unsigned(3)["a"] == nil, "subscript on a non-map must be nil, not a crash")
    }

    // MARK: - What the decoder must refuse

    @Test("Indefinite-length items are rejected")
    func rejectsIndefiniteLength() {
        // 0x5F = byte string, additional info 31 (indefinite).
        #expect(throws: CBOR.DecodeError.unsupportedAdditionalInfo(major: 2, info: 31)) {
            try CBOR.decode([0x5F, 0x41, 0x61, 0xFF])
        }
    }

    @Test("Floats are rejected")
    func rejectsFloats() {
        // 0xFB = major 7, info 27: IEEE 754 double.
        #expect(throws: (any Error).self) { try CBOR.decode(bytes("fb3ff199999999999a")) }
        // 0xF9 = half precision.
        #expect(throws: (any Error).self) { try CBOR.decode(bytes("f93e00")) }
    }

    @Test("Tags are rejected")
    func rejectsTags() {
        // 0xC0 = major 6 (tag) 0: standard date/time string.
        #expect(throws: CBOR.DecodeError.unsupportedMajorType(6)) {
            try CBOR.decode([0xC0, 0x61, 0x61])
        }
    }

    @Test("Reserved additional info 28-30 is rejected")
    func rejectsReservedInfo() {
        for info: UInt8 in 28...30 {
            #expect(throws: (any Error).self) { try CBOR.decode([info]) }
        }
    }

    @Test("Truncated input throws rather than reading past the end")
    func rejectsTruncated() {
        #expect(throws: CBOR.DecodeError.truncated) { try CBOR.decode([]) }
        #expect(throws: CBOR.DecodeError.truncated) { try CBOR.decode([0x19, 0x01]) }
        // Byte string claiming 4 bytes, carrying 2.
        #expect(throws: CBOR.DecodeError.truncated) { try CBOR.decode([0x44, 0x01, 0x02]) }
    }

    @Test("Trailing bytes are rejected — a frame is exactly one item")
    func rejectsTrailingBytes() {
        #expect(throws: CBOR.DecodeError.trailingBytes(1)) { try CBOR.decode([0x01, 0x02]) }
    }

    @Test("Invalid UTF-8 in a text string is rejected")
    func rejectsInvalidUTF8() {
        // 0x62 = 2-byte text string, then a lone continuation byte.
        #expect(throws: CBOR.DecodeError.invalidUTF8) { try CBOR.decode([0x62, 0x80, 0x80]) }
    }

    /// A hostile frame declaring a huge collection must fail on the declared
    /// length, before any allocation. If this regresses, a 3-byte packet can
    /// make the daemon reserve gigabytes.
    @Test("A collection length the input cannot back is rejected without allocating")
    func rejectsImpossibleCollectionLength() {
        // Array claiming 2^32 items, carrying none.
        #expect(throws: (any Error).self) { try CBOR.decode(bytes("9affffffff")) }
        // Map claiming 2^64-1 pairs.
        #expect(throws: (any Error).self) { try CBOR.decode(bytes("bbffffffffffffffff")) }
        // Byte string claiming 2^64-1 bytes.
        #expect(throws: (any Error).self) { try CBOR.decode(bytes("5bffffffffffffffff")) }
    }

    @Test("Nesting beyond the depth limit is rejected")
    func rejectsDeepNesting() {
        // maximumDepth nested single-element arrays, plus one.
        let deep = [UInt8](repeating: 0x81, count: CBOR.maximumDepth + 2) + [0x00]
        #expect(throws: CBOR.DecodeError.depthLimitExceeded) { try CBOR.decode(deep) }
    }

    @Test("Nesting at the depth limit still decodes")
    func acceptsNestingAtLimit() {
        var value = CBOR.unsigned(0)
        for _ in 0..<(CBOR.maximumDepth - 1) { value = .array([value]) }
        #expect(try! CBOR.decode(value.encode()) == value)
    }
}
