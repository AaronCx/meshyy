// meshyy — the RFC 8949 subset the control protocol needs.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Deliberately partial. Tags, floats, indefinite-length items and bignums are
// rejected on decode rather than tolerated: nothing in the protocol needs them,
// and a decoder that accepts less is a smaller attack surface on a daemon that
// holds PTYs (design doc §8). See docs/provenance.md, 2026-07-27.

import Foundation

/// A CBOR data item, restricted to the types meshyy's control frames use.
public enum CBOR: Sendable, Equatable {
    case unsigned(UInt64)
    case negative(Int64)
    case bytes([UInt8])
    case text(String)
    case array([CBOR])
    case map([(CBOR, CBOR)])
    case bool(Bool)
    case null

    public static func == (lhs: CBOR, rhs: CBOR) -> Bool {
        switch (lhs, rhs) {
        case (.unsigned(let a), .unsigned(let b)): a == b
        case (.negative(let a), .negative(let b)): a == b
        case (.bytes(let a), .bytes(let b)): a == b
        case (.text(let a), .text(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.bool(let a), .bool(let b)): a == b
        case (.null, .null): true
        case (.map(let a), .map(let b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    // MARK: - Convenience constructors

    public static func int(_ value: Int) -> CBOR {
        value < 0 ? .negative(Int64(value)) : .unsigned(UInt64(value))
    }

    // MARK: - Accessors
    //
    // Returning optionals rather than throwing keeps frame decoding readable:
    // a frame decoder reads the fields it wants and ignores the rest, which is
    // what design doc §5.3 requires for graceful version skew.

    public var intValue: Int? {
        switch self {
        case .unsigned(let value): value <= UInt64(Int.max) ? Int(value) : nil
        case .negative(let value): Int(value)
        default: nil
        }
    }

    public var uint64Value: UInt64? {
        if case .unsigned(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    public var bytesValue: [UInt8]? {
        if case .bytes(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [CBOR]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Map lookup by text key. Linear, because control-frame maps have a
    /// handful of entries and a dictionary would lose the canonical ordering
    /// the golden fixtures depend on.
    public subscript(key: String) -> CBOR? {
        guard case .map(let pairs) = self else { return nil }
        for (mapKey, value) in pairs where mapKey == .text(key) {
            return value
        }
        return nil
    }
}

// MARK: - Encoding

extension CBOR {
    /// Deterministic encoding: shortest-form head for every item, map entries
    /// in the order given. RFC 8949 §4.2 calls the general rule "core
    /// deterministic"; meshyy's frames build their maps in a fixed order, so
    /// keys are not re-sorted here and the golden fixtures pin the result.
    public func encode() -> [UInt8] {
        switch self {
        case .unsigned(let value):
            return Self.head(major: 0, value: value)
        case .negative(let value):
            // RFC 8949 §3.1: major type 1 encodes -1 - n.
            let n = UInt64(-1 - value)
            return Self.head(major: 1, value: n)
        case .bytes(let content):
            return Self.head(major: 2, value: UInt64(content.count)) + content
        case .text(let string):
            let utf8 = Array(string.utf8)
            return Self.head(major: 3, value: UInt64(utf8.count)) + utf8
        case .array(let items):
            return Self.head(major: 4, value: UInt64(items.count))
                + items.flatMap { $0.encode() }
        case .map(let pairs):
            return Self.head(major: 5, value: UInt64(pairs.count))
                + pairs.flatMap { $0.0.encode() + $0.1.encode() }
        case .bool(let value):
            return [value ? 0xF5 : 0xF4]
        case .null:
            return [0xF6]
        }
    }

    /// Major type in the top three bits, then the shortest additional-info
    /// encoding that fits. RFC 8949 §3.
    static func head(major: UInt8, value: UInt64) -> [UInt8] {
        let prefix = major << 5
        switch value {
        case 0..<24:
            return [prefix | UInt8(value)]
        case 24..<0x100:
            return [prefix | 24, UInt8(value)]
        case 0x100..<0x1_0000:
            return [prefix | 25, UInt8(value >> 8), UInt8(value & 0xFF)]
        case 0x1_0000..<0x1_0000_0000:
            return [prefix | 26] + (0..<4).reversed().map { UInt8((value >> ($0 * 8)) & 0xFF) }
        default:
            return [prefix | 27] + (0..<8).reversed().map { UInt8((value >> ($0 * 8)) & 0xFF) }
        }
    }
}

// MARK: - Decoding

extension CBOR {
    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case truncated
        case trailingBytes(Int)
        case unsupportedMajorType(UInt8)
        /// Indefinite length, floats, tags, and other simple values are all
        /// rejected rather than skipped.
        case unsupportedAdditionalInfo(major: UInt8, info: UInt8)
        case invalidUTF8
        case depthLimitExceeded
        case itemLimitExceeded

        public var description: String {
            switch self {
            case .truncated: "cbor: truncated"
            case .trailingBytes(let count): "cbor: \(count) unexpected trailing bytes"
            case .unsupportedMajorType(let major): "cbor: unsupported major type \(major)"
            case .unsupportedAdditionalInfo(let major, let info):
                "cbor: unsupported additional info \(info) for major type \(major)"
            case .invalidUTF8: "cbor: text string is not valid UTF-8"
            case .depthLimitExceeded: "cbor: nesting deeper than \(CBOR.maximumDepth)"
            case .itemLimitExceeded: "cbor: collection larger than \(CBOR.maximumItems)"
            }
        }
    }

    /// Nesting cap. Control frames nest two deep at most; 16 is generous and
    /// still bounds recursion so a hostile frame cannot exhaust the stack.
    static let maximumDepth = 16
    /// Collection-length cap, checked before allocating. A hostile frame that
    /// claims 2^64 entries must not turn into a reserve of 2^64.
    static let maximumItems = 1 << 20

    /// Decodes exactly one item and requires the input to end there.
    public static func decode(_ bytes: [UInt8]) throws -> CBOR {
        var cursor = 0
        let value = try decodeItem(bytes, &cursor, depth: 0)
        guard cursor == bytes.count else {
            throw DecodeError.trailingBytes(bytes.count - cursor)
        }
        return value
    }

    private static func decodeItem(_ bytes: [UInt8], _ cursor: inout Int, depth: Int) throws -> CBOR {
        guard depth < maximumDepth else { throw DecodeError.depthLimitExceeded }
        guard cursor < bytes.count else { throw DecodeError.truncated }

        let initial = bytes[cursor]
        cursor += 1
        let major = initial >> 5
        let info = initial & 0x1F

        // Simple values first: they have no argument to read.
        if major == 7 {
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            default: throw DecodeError.unsupportedAdditionalInfo(major: major, info: info)
            }
        }

        let argument = try readArgument(bytes, &cursor, major: major, info: info)

        switch major {
        case 0:
            return .unsigned(argument)
        case 1:
            // -1 - n. Values below Int64.min are unrepresentable and rejected
            // rather than wrapped.
            guard argument <= UInt64(Int64.max) else {
                throw DecodeError.unsupportedAdditionalInfo(major: major, info: info)
            }
            return .negative(-1 - Int64(argument))
        case 2:
            let count = try boundedCount(argument, available: bytes.count - cursor)
            let content = Array(bytes[cursor..<(cursor + count)])
            cursor += count
            return .bytes(content)
        case 3:
            let count = try boundedCount(argument, available: bytes.count - cursor)
            let slice = bytes[cursor..<(cursor + count)]
            cursor += count
            guard let text = String(bytes: slice, encoding: .utf8) else {
                throw DecodeError.invalidUTF8
            }
            return .text(text)
        case 4:
            let count = try boundedCount(argument, available: bytes.count - cursor, bytesPerItem: 1)
            var items: [CBOR] = []
            items.reserveCapacity(count)
            for _ in 0..<count {
                items.append(try decodeItem(bytes, &cursor, depth: depth + 1))
            }
            return .array(items)
        case 5:
            let count = try boundedCount(argument, available: bytes.count - cursor, bytesPerItem: 2)
            var pairs: [(CBOR, CBOR)] = []
            pairs.reserveCapacity(count)
            for _ in 0..<count {
                let key = try decodeItem(bytes, &cursor, depth: depth + 1)
                let value = try decodeItem(bytes, &cursor, depth: depth + 1)
                pairs.append((key, value))
            }
            return .map(pairs)
        default:
            throw DecodeError.unsupportedMajorType(major)
        }
    }

    private static func readArgument(
        _ bytes: [UInt8], _ cursor: inout Int, major: UInt8, info: UInt8
    ) throws -> UInt64 {
        switch info {
        case 0..<24:
            return UInt64(info)
        case 24, 25, 26, 27:
            let width = 1 << Int(info - 24)
            guard cursor + width <= bytes.count else { throw DecodeError.truncated }
            var value: UInt64 = 0
            for offset in 0..<width {
                value = (value << 8) | UInt64(bytes[cursor + offset])
            }
            cursor += width
            return value
        default:
            // 28–30 are reserved; 31 is indefinite length. Both rejected.
            throw DecodeError.unsupportedAdditionalInfo(major: major, info: info)
        }
    }

    /// Rejects a declared length that the remaining input could not possibly
    /// satisfy, *before* any allocation. `bytesPerItem` is the minimum encoded
    /// size of one element, so a claimed array of a billion items backed by
    /// three bytes of input fails immediately instead of reserving.
    private static func boundedCount(
        _ argument: UInt64, available: Int, bytesPerItem: Int = 1
    ) throws -> Int {
        guard argument <= UInt64(maximumItems) else { throw DecodeError.itemLimitExceeded }
        let count = Int(argument)
        guard count * bytesPerItem <= available else { throw DecodeError.truncated }
        return count
    }
}
