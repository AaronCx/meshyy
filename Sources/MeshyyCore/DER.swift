// meshyy — minimal DER encoder, enough to build an X.509 certificate.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Written against X.690 (DER) and RFC 5280. Encode-only: meshyy never parses
// certificates, it compares SHA-256 fingerprints, so there is no decoder here
// and no parser attack surface.
//
// See docs/provenance.md, 2026-07-27 (self-signed identity).

import Foundation

/// A DER value: an identifier octet, a definite length, and content.
public struct DER: Sendable, Equatable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    // MARK: - Tags

    public enum Tag: UInt8, Sendable {
        case boolean = 0x01
        case integer = 0x02
        case bitString = 0x03
        case octetString = 0x04
        case null = 0x05
        case objectIdentifier = 0x06
        case utf8String = 0x0C
        case printableString = 0x13
        case ia5String = 0x16
        case utcTime = 0x17
        case generalizedTime = 0x18
        case sequence = 0x30
        case set = 0x31
    }

    // MARK: - Primitives

    /// Wraps `content` in `tag` with a definite DER length.
    public static func tagged(_ tag: UInt8, _ content: [UInt8]) -> DER {
        DER(bytes: [tag] + length(content.count) + content)
    }

    public static func tagged(_ tag: Tag, _ content: [UInt8]) -> DER {
        tagged(tag.rawValue, content)
    }

    /// DER definite-length octets: short form below 128, else long form with
    /// the minimum number of base-256 bytes.
    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var value = count
        var encoded: [UInt8] = []
        while value > 0 {
            encoded.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(encoded.count)] + encoded
    }

    public static func sequence(_ elements: [DER]) -> DER {
        tagged(.sequence, elements.flatMap(\.bytes))
    }

    public static func set(_ elements: [DER]) -> DER {
        tagged(.set, elements.flatMap(\.bytes))
    }

    public static func boolean(_ value: Bool) -> DER {
        tagged(.boolean, [value ? 0xFF : 0x00])
    }

    public static let null = DER.tagged(.null, [])

    /// Big-endian two's-complement INTEGER. A leading 0x00 is prepended when
    /// the high bit is set so the value stays positive, and redundant leading
    /// zeroes are stripped, both as DER requires.
    public static func integer(_ magnitude: [UInt8]) -> DER {
        var value = magnitude
        while value.count > 1, value[0] == 0x00, value[1] & 0x80 == 0 {
            value.removeFirst()
        }
        if value.isEmpty { value = [0x00] }
        if value[0] & 0x80 != 0 { value.insert(0x00, at: 0) }
        return tagged(.integer, value)
    }

    public static func integer(_ value: Int) -> DER {
        var magnitude: [UInt8] = []
        var remaining = value
        precondition(remaining >= 0, "DER.integer(Int) is for non-negative values")
        repeat {
            magnitude.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining > 0
        return integer(magnitude)
    }

    public static func octetString(_ content: [UInt8]) -> DER {
        tagged(.octetString, content)
    }

    /// BIT STRING with `unusedBits` trailing bits in the final octet ignored.
    public static func bitString(_ content: [UInt8], unusedBits: UInt8 = 0) -> DER {
        tagged(.bitString, [unusedBits] + content)
    }

    public static func utf8String(_ text: String) -> DER {
        tagged(.utf8String, Array(text.utf8))
    }

    public static func printableString(_ text: String) -> DER {
        tagged(.printableString, Array(text.utf8))
    }

    public static func ia5String(_ text: String) -> DER {
        tagged(.ia5String, Array(text.utf8))
    }

    /// Explicit context-specific constructed tag `[n]`.
    public static func explicit(_ number: UInt8, _ inner: DER) -> DER {
        tagged(0xA0 | number, inner.bytes)
    }

    /// Implicit context-specific primitive tag `[n]`, content verbatim.
    public static func implicitPrimitive(_ number: UInt8, _ content: [UInt8]) -> DER {
        tagged(0x80 | number, content)
    }

    /// UTCTime `YYMMDDHHMMSSZ`. RFC 5280 §4.1.2.5.1 requires UTCTime for dates
    /// through 2049 and GeneralizedTime after; `time(_:)` picks correctly.
    public static func utcTime(_ date: Date) -> DER {
        tagged(.utcTime, Array(Self.formatted(date, format: "yyMMddHHmmss").utf8) + [0x5A])
    }

    public static func generalizedTime(_ date: Date) -> DER {
        tagged(.generalizedTime, Array(Self.formatted(date, format: "yyyyMMddHHmmss").utf8) + [0x5A])
    }

    /// RFC 5280 §4.1.2.5: UTCTime through 2049, GeneralizedTime from 2050.
    public static func time(_ date: Date) -> DER {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let year = calendar.component(.year, from: date)
        return year < 2050 ? utcTime(date) : generalizedTime(date)
    }

    private static func formatted(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// OBJECT IDENTIFIER from dotted decimal, e.g. "1.2.840.10045.4.3.2".
    /// Returns nil for anything that is not a well-formed OID.
    public static func objectIdentifier(_ dotted: String) -> DER? {
        let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
        guard parts.count >= 2, parts[0] <= 2 else { return nil }
        guard parts[0] == 2 || parts[1] < 40 else { return nil }

        var content: [UInt8] = []
        content.append(contentsOf: base128(parts[0] * 40 + parts[1]))
        for part in parts.dropFirst(2) {
            content.append(contentsOf: base128(part))
        }
        return tagged(.objectIdentifier, content)
    }

    /// Base-128 with the continuation bit set on all but the final octet.
    static func base128(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var encoded: [UInt8] = [UInt8(remaining & 0x7F)]
        remaining >>= 7
        while remaining > 0 {
            encoded.insert(UInt8(remaining & 0x7F) | 0x80, at: 0)
            remaining >>= 7
        }
        return encoded
    }
}

/// Object identifiers meshyy emits. Values from the RFCs cited beside each.
public enum OID {
    /// RFC 5280 §A.1 — id-at-commonName.
    public static let commonName = "2.5.4.3"
    /// RFC 5280 §A.1 — id-at-organizationName.
    public static let organizationName = "2.5.4.10"
    /// RFC 5480 §2.1.1 — id-ecPublicKey.
    public static let ecPublicKey = "1.2.840.10045.2.1"
    /// RFC 5480 §2.1.1.1 — secp256r1 (prime256v1, NIST P-256).
    public static let prime256v1 = "1.2.840.10045.3.1.7"
    /// RFC 5758 §3.2 — ecdsa-with-SHA256.
    public static let ecdsaWithSHA256 = "1.2.840.10045.4.3.2"
    /// RFC 5280 §4.2.1.9 — id-ce-basicConstraints.
    public static let basicConstraints = "2.5.29.19"
    /// RFC 5280 §4.2.1.3 — id-ce-keyUsage.
    public static let keyUsage = "2.5.29.15"
    /// RFC 5280 §4.2.1.12 — id-ce-extKeyUsage.
    public static let extKeyUsage = "2.5.29.37"
    /// RFC 5280 §4.2.1.6 — id-ce-subjectAltName.
    public static let subjectAltName = "2.5.29.17"
    /// RFC 5280 §4.2.1.2 — id-ce-subjectKeyIdentifier.
    public static let subjectKeyIdentifier = "2.5.29.14"
    /// RFC 5280 §4.2.1.12 — id-kp-serverAuth.
    public static let serverAuth = "1.3.6.1.5.5.7.3.1"
}
