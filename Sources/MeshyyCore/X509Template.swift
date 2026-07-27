// meshyy — self-signed X.509 certificate builder (structure only, no crypto).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Splits into `tbsCertificate` (what gets signed) and `certificate(signature:)`
// (the wrapper). The signing itself is the platform's job — Security framework
// on Apple platforms — so this type stays pure and unit-testable, and no
// bespoke crypto lives in meshyy (design doc §8).
//
// Written against RFC 5280 §4.1 and RFC 5480 §2. See docs/provenance.md.

import Foundation

/// A P-256 self-signed server certificate for the QUIC listener.
///
/// The certificate is not a trust anchor for anything: the client pins its
/// SHA-256 fingerprint, delivered over the already-authenticated SSH channel
/// (design doc §5.1). The fields below exist so the certificate is well-formed
/// enough for TLS 1.3 to accept it, not so anyone will read them.
public struct X509Template: Sendable {
    /// Uncompressed EC point, `0x04 || X || Y`. 65 bytes for P-256, which is
    /// exactly what `SecKeyCopyExternalRepresentation` returns.
    public var publicKeyPoint: [UInt8]
    /// Big-endian positive serial. RFC 5280 §4.1.2.2 caps it at 20 octets.
    public var serialNumber: [UInt8]
    public var commonName: String
    public var organization: String
    public var notBefore: Date
    public var notAfter: Date
    /// dNSName entries for subjectAltName. RFC 5280 §4.2.1.6.
    public var dnsNames: [String]
    /// SHA-256 of the public key point, truncated to 20 octets, as the
    /// subjectKeyIdentifier. RFC 5280 §4.2.1.2 permits any method that yields a
    /// unique value; the SHA-1 method it *suggests* is not something to reach
    /// for in 2026.
    public var subjectKeyIdentifier: [UInt8]

    public init(
        publicKeyPoint: [UInt8],
        serialNumber: [UInt8],
        commonName: String,
        organization: String = "meshyy",
        notBefore: Date,
        notAfter: Date,
        dnsNames: [String],
        subjectKeyIdentifier: [UInt8]
    ) {
        self.publicKeyPoint = publicKeyPoint
        self.serialNumber = serialNumber
        self.commonName = commonName
        self.organization = organization
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.dnsNames = dnsNames
        self.subjectKeyIdentifier = subjectKeyIdentifier
    }

    public enum TemplateError: Error, CustomStringConvertible {
        case badOID(String)
        case badPublicKeyPoint(count: Int)

        public var description: String {
            switch self {
            case .badOID(let oid): "meshyy: malformed OID \(oid)"
            case .badPublicKeyPoint(let count):
                "meshyy: expected a 65-byte uncompressed P-256 point, got \(count) bytes"
            }
        }
    }

    private static func oid(_ dotted: String) throws -> DER {
        guard let value = DER.objectIdentifier(dotted) else {
            throw TemplateError.badOID(dotted)
        }
        return value
    }

    /// `AlgorithmIdentifier { ecdsa-with-SHA256 }`. RFC 5758 §3.2 says the
    /// parameters field is absent, not NULL.
    static func ecdsaSHA256AlgorithmIdentifier() throws -> DER {
        DER.sequence([try oid(OID.ecdsaWithSHA256)])
    }

    /// `SubjectPublicKeyInfo` for a named-curve P-256 key. RFC 5480 §2.
    func subjectPublicKeyInfo() throws -> DER {
        guard publicKeyPoint.count == 65, publicKeyPoint[0] == 0x04 else {
            throw TemplateError.badPublicKeyPoint(count: publicKeyPoint.count)
        }
        return DER.sequence([
            DER.sequence([
                try Self.oid(OID.ecPublicKey),
                try Self.oid(OID.prime256v1),
            ]),
            DER.bitString(publicKeyPoint),
        ])
    }

    /// `Name` with CN and O in separate RDNs, which is the conventional shape.
    private func name() throws -> DER {
        DER.sequence([
            DER.set([DER.sequence([try Self.oid(OID.commonName), DER.utf8String(commonName)])]),
            DER.set([
                DER.sequence([try Self.oid(OID.organizationName), DER.utf8String(organization)])
            ]),
        ])
    }

    private func extensions() throws -> DER {
        var items: [DER] = []

        // basicConstraints, critical, CA:FALSE. An empty SEQUENCE means both
        // DEFAULT values apply (cA FALSE, no pathLen).
        items.append(DER.sequence([
            try Self.oid(OID.basicConstraints),
            DER.boolean(true),
            DER.octetString(DER.sequence([]).bytes),
        ]))

        // keyUsage, critical: digitalSignature only. Bit 0 of a 1-octet BIT
        // STRING with 7 unused bits.
        items.append(DER.sequence([
            try Self.oid(OID.keyUsage),
            DER.boolean(true),
            DER.octetString(DER.bitString([0x80], unusedBits: 7).bytes),
        ]))

        // extKeyUsage: serverAuth. Not critical — TLS stacks that ignore it
        // should still accept the certificate.
        items.append(DER.sequence([
            try Self.oid(OID.extKeyUsage),
            DER.octetString(DER.sequence([try Self.oid(OID.serverAuth)]).bytes),
        ]))

        if !dnsNames.isEmpty {
            // GeneralNames: dNSName is [2] IMPLICIT IA5String.
            let names = dnsNames.map { DER.implicitPrimitive(2, Array($0.utf8)) }
            items.append(DER.sequence([
                try Self.oid(OID.subjectAltName),
                DER.octetString(DER.sequence(names).bytes),
            ]))
        }

        items.append(DER.sequence([
            try Self.oid(OID.subjectKeyIdentifier),
            DER.octetString(DER.octetString(subjectKeyIdentifier).bytes),
        ]))

        return DER.explicit(3, DER.sequence(items))
    }

    /// The `TBSCertificate` DER. This is the byte string that gets signed.
    public func tbsCertificate() throws -> DER {
        let subject = try name()
        return DER.sequence([
            // version [0] EXPLICIT: 2 means v3, which is required once
            // extensions are present.
            DER.explicit(0, DER.integer(2)),
            DER.integer(serialNumber),
            try Self.ecdsaSHA256AlgorithmIdentifier(),
            subject, // issuer == subject: self-signed
            DER.sequence([DER.time(notBefore), DER.time(notAfter)]),
            subject,
            try subjectPublicKeyInfo(),
            try extensions(),
        ])
    }

    /// The complete `Certificate` DER.
    ///
    /// `signature` must be the X9.62 `SEQUENCE { r INTEGER, s INTEGER }` DER
    /// that ECDSA produces over `tbsCertificate()`, which is what
    /// `SecKeyCreateSignature(.ecdsaSignatureMessageX962SHA256)` returns
    /// verbatim (RFC 3279 §2.2.3).
    public func certificate(signature: [UInt8]) throws -> [UInt8] {
        DER.sequence([
            try tbsCertificate(),
            try Self.ecdsaSHA256AlgorithmIdentifier(),
            DER.bitString(signature),
        ]).bytes
    }
}
