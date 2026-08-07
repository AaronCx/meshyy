// meshyy — the daemon's TLS identity (design doc §5.1, §8).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Network framework's QUIC needs a `sec_identity_t`, which needs a certificate and
// its private key. meshyyd generates both at first run and reports the
// certificate's SHA-256 over the already-authenticated SSH channel; the client
// pins that fingerprint. No CA, and no new trust decision for the user.
//
// NO KEYCHAIN. `SecIdentityCreate(nil, certificate, privateKey)` pairs a
// certificate with a key directly — public API, `API_AVAILABLE(macos(10.12))`, not
// deprecated, and it touches no keychain at all.
//
// The M0 spike assumed this function was private SPI and built on a dedicated file
// keychain instead. That was wrong, and the mistake was not free:
//
//   * `SecKeychainCreate` and friends are deprecated (macOS 10.10).
//   * Worse, keys in a file keychain are ACL-bound to the binary that created
//     them, so the daemon would have loaded its own key fine until the next time
//     `meshyyd` was rebuilt — and then **hung**, silently, on a Security prompt no
//     headless process can answer. A bug that appears only after an update is the
//     worst kind to ship.
//   * And it needed a Security session, which a CI runner does not have, so the
//     QUIC integration suites could not run in CI.
//
// All three go away here. See docs/provenance.md, 2026-07-27 (SecIdentityCreate).
//
// Persistence is two files under `~/.meshyy`, both 0600: the raw P-256 private key
// and the certificate DER. The fingerprint is therefore stable across restarts,
// which matters for debugging rather than for security — the client re-pins on
// every bootstrap, so a rotated identity is merely invisible rather than breaking.

import CryptoKit
import Darwin
import Foundation
import MeshyyCore
import Security

public struct DaemonIdentity: @unchecked Sendable {
    /// The paired key and certificate, for `sec_identity_create`.
    public let secIdentity: SecIdentity
    /// DER of the certificate. Only its digest ever travels.
    public let certificateDER: Data
    /// Lowercase hex SHA-256 of `certificateDER`. This is what the client pins.
    public let fingerprint: String

    public enum IdentityError: Error, CustomStringConvertible {
        case keyGeneration(String)
        case certificateRejected(byteCount: Int)
        case signing(String)
        case selfSignatureInvalid(String)
        case identityPairingFailed
        case storageUnavailable(String)

        public var description: String {
            switch self {
            case .keyGeneration(let detail):
                "identity: key generation failed: \(detail)"
            case .certificateRejected(let count):
                "identity: Security framework rejected our \(count)-byte certificate "
                    + "DER as malformed"
            case .signing(let detail):
                "identity: signing the certificate failed: \(detail)"
            case .selfSignatureInvalid(let detail):
                "identity: the certificate we just built does not validate against "
                    + "itself: \(detail)"
            case .identityPairingFailed:
                "identity: SecIdentityCreate refused the certificate/key pair — the "
                    + "certificate's public key does not match the private key"
            case .storageUnavailable(let detail):
                "identity: cannot persist the identity: \(detail)"
            }
        }
    }

    public static var defaultDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".meshyy")
    }

    /// Ten years. The certificate is pinned by fingerprint, not trusted by date, so
    /// an expiry that lapsed would break a daemon nobody had touched for years in
    /// exchange for nothing.
    private static let validity: TimeInterval = 60 * 60 * 24 * 3650

    // MARK: - Load or create

    public static func loadOrCreate(
        directory: String = DaemonIdentity.defaultDirectory
    ) throws -> DaemonIdentity {
        try prepareDirectory(directory)
        let keyPath = (directory as NSString).appendingPathComponent("identity.key")
        let certPath = (directory as NSString).appendingPathComponent("identity.crt")

        if let existing = try? load(keyPath: keyPath, certPath: certPath) {
            return existing
        }
        // Either first run or unusable material. Replace rather than limp: the client
        // re-pins on every bootstrap (design doc §5.1), so a regenerated identity
        // costs nothing, while a daemon that cannot complete a handshake costs
        // everything.
        return try generate(keyPath: keyPath, certPath: certPath)
    }

    private static func load(keyPath: String, certPath: String) throws -> DaemonIdentity {
        guard let keyData = FileManager.default.contents(atPath: keyPath),
              let certDER = FileManager.default.contents(atPath: certPath)
        else {
            throw IdentityError.storageUnavailable("no stored identity")
        }

        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        guard let privateKey = SecKeyCreateWithData(
            keyData as CFData, attributes as CFDictionary, &error
        ) else {
            throw IdentityError.keyGeneration(
                "stored key is unusable: "
                    + (error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown")
            )
        }
        guard let certificate = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw IdentityError.certificateRejected(byteCount: certDER.count)
        }
        guard let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw IdentityError.identityPairingFailed
        }
        return DaemonIdentity(
            secIdentity: identity,
            certificateDER: certDER,
            fingerprint: hex(SHA256.hash(data: certDER))
        )
    }

    private static func generate(keyPath: String, certPath: String) throws -> DaemonIdentity {
        // Transient: `kSecAttrIsPermanent` false means the key exists only in this
        // process's memory and no keychain is consulted. Persistence is our own file
        // below, which is what keeps the key free of an ACL bound to this binary.
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false],
        ]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw IdentityError.keyGeneration(
                error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown"
            )
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw IdentityError.keyGeneration("SecKeyCopyPublicKey returned nil")
        }
        guard let pointData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw IdentityError.keyGeneration(
                error.map { String(describing: $0.takeRetainedValue()) } ?? "no public point"
            )
        }

        var serial = try TokenStore.secureRandom(16)
        serial[0] &= 0x7F // positive without needing a pad byte

        let template = X509Template(
            publicKeyPoint: [UInt8](pointData),
            serialNumber: serial,
            commonName: "meshyyd",
            // Backdated an hour so a small clock skew does not make a fresh
            // certificate not-yet-valid.
            notBefore: Date().addingTimeInterval(-3600),
            notAfter: Date().addingTimeInterval(validity),
            dnsNames: subjectAlternativeNames(),
            subjectKeyIdentifier: Array(SHA256.hash(data: pointData).prefix(20))
        )

        let tbs: [UInt8]
        do {
            tbs = try template.tbsCertificate().bytes
        } catch {
            throw IdentityError.signing("building TBSCertificate: \(error)")
        }
        guard let signature = SecKeyCreateSignature(
            privateKey, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, &error
        ) as Data? else {
            throw IdentityError.signing(
                error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown"
            )
        }

        let certDER: Data
        do {
            certDER = Data(try template.certificate(signature: [UInt8](signature)))
        } catch {
            throw IdentityError.signing("assembling certificate: \(error)")
        }

        guard let certificate = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw IdentityError.certificateRejected(byteCount: certDER.count)
        }

        // Validate the self-signature with something that actually checks it. A
        // fingerprint-pinning client would accept a certificate whose own signature
        // was garbage, so this is the only place the mistake would ever be caught.
        if let failure = selfSignatureFailure(certificate) {
            throw IdentityError.selfSignatureInvalid(failure)
        }

        guard let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw IdentityError.identityPairingFailed
        }

        guard let keyData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw IdentityError.keyGeneration("cannot export the private key for storage")
        }
        try writePrivately(keyData, to: keyPath)
        try writePrivately(certDER, to: certPath)

        return DaemonIdentity(
            secIdentity: identity,
            certificateDER: certDER,
            fingerprint: hex(SHA256.hash(data: certDER))
        )
    }

    // MARK: - Storage

    private static func prepareDirectory(_ directory: String) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // createDirectory does not fix the mode of a directory that already exists.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory
            )
        } catch {
            throw IdentityError.storageUnavailable("\(error)")
        }
    }

    /// Writes 0600, and creates the file with that mode rather than fixing it after
    /// — otherwise the private key is briefly world-readable.
    private static func writePrivately(_ data: Data, to path: String) throws {
        try? FileManager.default.removeItem(atPath: path)
        guard FileManager.default.createFile(
            atPath: path, contents: data, attributes: [.posixPermissions: 0o600]
        ) else {
            throw IdentityError.storageUnavailable("cannot write \(path)")
        }
    }

    // MARK: - Certificate helpers

    /// dNSNames for the certificate. Not load-bearing — the client pins a
    /// fingerprint and replaces chain validation entirely — but a well-formed
    /// certificate avoids surprises from any layer that does look.
    private static func subjectAlternativeNames() -> [String] {
        var names = ["meshyyd.local", "localhost"]
        let hostName = ProcessInfo.processInfo.hostName
        if !hostName.isEmpty, !names.contains(hostName) { names.append(hostName) }
        return names
    }

    /// nil when the certificate validates against itself as its own anchor.
    private static func selfSignatureFailure(_ certificate: SecCertificate) -> String? {
        var trust: SecTrust?
        let created = SecTrustCreateWithCertificates(
            certificate, SecPolicyCreateBasicX509(), &trust
        )
        guard created == errSecSuccess, let trust else {
            return "SecTrustCreateWithCertificates returned \(created)"
        }
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return nil }
        return error.map { String(describing: $0) } ?? "unknown trust failure"
    }

    static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
