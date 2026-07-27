// meshyy — the daemon's TLS identity (design doc §5.1, §8).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Network framework's QUIC needs a `sec_identity_t`, which needs a private key
// and a certificate the keychain can pair. meshyyd generates both at first run and
// reports the certificate's SHA-256 over the already-authenticated SSH channel;
// the client pins that fingerprint. No CA, and no new trust decision for the user.
//
// STORAGE: a dedicated file keychain, which is the only route that works. The M0
// spike (docs/spikes/2026-07-27-quic-network-framework.md) measured the
// alternatives:
//   - data-protection keychain: -34018 errSecMissingEntitlement. Needs a
//     team-prefixed keychain-access-groups entitlement, which an unsigned or
//     ad-hoc-signed binary cannot have.
//   - login keychain: -25308 errSecInteractionNotAllowed. It is locked in an SSH
//     session and cannot prompt — and headless is exactly meshyyd's case.
// Both failures are structural rather than transient, so there is nothing to
// retry. SecKeychainCreate/SecKeychainUnlock are deprecated (macOS 10.10) and
// still functional on 26.4.1; the migration path if they are removed is to sign
// meshyyd with a Developer ID plus the entitlement and switch to the
// data-protection keychain, which already fails *only* for want of it.

import CryptoKit
import Darwin
import Foundation
import MeshyyCore
import Security

public struct DaemonIdentity: @unchecked Sendable {
    /// The paired key and certificate, for `sec_identity_create`.
    public let secIdentity: SecIdentity
    /// DER of the certificate, as sent to no one — only its digest travels.
    public let certificateDER: Data
    /// Lowercase hex SHA-256 of `certificateDER`. This is what the client pins.
    public let fingerprint: String

    public enum IdentityError: Error, CustomStringConvertible {
        case keychain(String, OSStatus)
        case keyGeneration(String)
        case certificateRejected(byteCount: Int)
        case signing(String)
        case selfSignatureInvalid(String)
        case directoryUnavailable(String)

        public var description: String {
            switch self {
            case .keychain(let step, let status):
                let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "identity: \(step) failed: \(text) (OSStatus \(status))"
            case .keyGeneration(let detail):
                return "identity: key generation failed: \(detail)"
            case .certificateRejected(let count):
                return "identity: Security framework rejected our \(count)-byte "
                    + "certificate DER as malformed"
            case .signing(let detail):
                return "identity: signing the certificate failed: \(detail)"
            case .selfSignatureInvalid(let detail):
                return "identity: the certificate we just built does not validate "
                    + "against itself: \(detail)"
            case .directoryUnavailable(let detail):
                return "identity: cannot prepare the keychain directory: \(detail)"
            }
        }
    }

    /// Where the keychain and its password live. `~/.meshyy`, 0700.
    public static var defaultDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".meshyy")
    }

    private static let keyLabel = "meshyyd identity key"
    private static let certLabel = "meshyyd identity certificate"
    private static let applicationTag = Data("com.aaroncx.meshyyd.identity".utf8)
    /// Ten years. The certificate is pinned by fingerprint, not trusted by date,
    /// and an expiry that lapses would break a daemon nobody has touched for
    /// years for no security benefit.
    private static let validity: TimeInterval = 60 * 60 * 24 * 3650

    /// Loads the existing identity, or creates one on first run.
    public static func loadOrCreate(directory: String = DaemonIdentity.defaultDirectory) throws -> DaemonIdentity {
        let keychainPath = (directory as NSString).appendingPathComponent("meshyyd.keychain-db")
        let passwordPath = (directory as NSString).appendingPathComponent("keychain-password")

        try prepareDirectory(directory)

        if FileManager.default.fileExists(atPath: keychainPath),
           let password = try? String(contentsOfFile: passwordPath, encoding: .utf8),
           let keychain = try? openKeychain(path: keychainPath, password: password),
           let existing = try? load(from: keychain) {
            return existing
        }

        // Either first run or an unusable keychain. Replace rather than limp:
        // a client that cannot complete a handshake is worse than one that has to
        // re-pin, and re-pinning is free because the fingerprint travels over SSH
        // on every connect (design doc §5.1).
        try? FileManager.default.removeItem(atPath: keychainPath)
        let password = TokenStore.randomSecret(bytes: 32)
        try writePrivately(password, to: passwordPath)
        let keychain = try createKeychain(path: keychainPath, password: password)
        return try generate(into: keychain)
    }

    // MARK: - Keychain

    private static func prepareDirectory(_ directory: String) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // createDirectory does not fix an existing directory's mode.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory
            )
        } catch {
            throw IdentityError.directoryUnavailable("\(error)")
        }
    }

    private static func writePrivately(_ contents: String, to path: String) throws {
        // Created 0600 before anything is written, so the password is never
        // briefly world-readable.
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [
            .posixPermissions: 0o600,
        ])
        do {
            try contents.write(toFile: path, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
        } catch {
            throw IdentityError.directoryUnavailable("cannot write \(path): \(error)")
        }
    }

    // SecKeychain is deprecated but is the only route that works headlessly for an
    // unsigned binary; see the file header. Suppressed narrowly so the rest of the
    // file still gets deprecation warnings.
    @available(macOS, deprecated: 10.10)
    private static func createKeychain(path: String, password: String) throws -> SecKeychain {
        var keychain: SecKeychain?
        let status = SecKeychainCreate(path, UInt32(password.utf8.count), password, false, nil, &keychain)
        guard status == errSecSuccess, let keychain else {
            throw IdentityError.keychain("SecKeychainCreate", status)
        }
        // Never lock on sleep or after an interval: meshyyd must be able to answer
        // a QUIC handshake at 4am with nobody logged in.
        var settings = SecKeychainSettings(
            version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1),
            lockOnSleep: false,
            useLockInterval: false,
            lockInterval: .max
        )
        SecKeychainSetSettings(keychain, &settings)
        let unlock = SecKeychainUnlock(keychain, UInt32(password.utf8.count), password, true)
        guard unlock == errSecSuccess else {
            throw IdentityError.keychain("SecKeychainUnlock", unlock)
        }
        return keychain
    }

    @available(macOS, deprecated: 10.10)
    private static func openKeychain(path: String, password: String) throws -> SecKeychain {
        var keychain: SecKeychain?
        let status = SecKeychainOpen(path, &keychain)
        guard status == errSecSuccess, let keychain else {
            throw IdentityError.keychain("SecKeychainOpen", status)
        }
        let unlock = SecKeychainUnlock(keychain, UInt32(password.utf8.count), password, true)
        guard unlock == errSecSuccess else {
            throw IdentityError.keychain("SecKeychainUnlock", unlock)
        }
        return keychain
    }

    // MARK: - Load

    @available(macOS, deprecated: 10.10)
    private static func load(from keychain: SecKeychain) throws -> DaemonIdentity {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: certLabel,
            kSecMatchSearchList as String: [keychain] as CFArray,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let identity = item as! SecIdentity? else {
            throw IdentityError.keychain("SecItemCopyMatching(identity)", status)
        }

        var certificate: SecCertificate?
        let copy = SecIdentityCopyCertificate(identity, &certificate)
        guard copy == errSecSuccess, let certificate else {
            throw IdentityError.keychain("SecIdentityCopyCertificate", copy)
        }
        let der = SecCertificateCopyData(certificate) as Data
        return DaemonIdentity(
            secIdentity: identity,
            certificateDER: der,
            fingerprint: Self.hex(SHA256.hash(data: der))
        )
    }

    // MARK: - Generate

    @available(macOS, deprecated: 10.10)
    private static func generate(into keychain: SecKeychain) throws -> DaemonIdentity {
        let privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrLabel as String: keyLabel,
            kSecAttrApplicationTag as String: applicationTag,
            kSecUseKeychain as String: keychain,
        ]
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecUseKeychain as String: keychain,
            kSecPrivateKeyAttrs as String: privateAttributes,
        ]

        var error: Unmanaged<CFError>?
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

        var serial = TokenStore.secureRandom(16)
        serial[0] &= 0x7F // positive without needing a pad byte

        let template = X509Template(
            publicKeyPoint: [UInt8](pointData),
            serialNumber: serial,
            commonName: "meshyyd",
            // Backdated an hour so a small clock skew between the daemon and a
            // validator does not make a fresh certificate not-yet-valid.
            notBefore: Date().addingTimeInterval(-3600),
            notAfter: Date().addingTimeInterval(validity),
            dnsNames: Self.subjectAlternativeNames(),
            subjectKeyIdentifier: Array(SHA256.hash(data: pointData).prefix(20))
        )

        let tbs: [UInt8]
        do {
            tbs = try template.tbsCertificate().bytes
        } catch {
            throw IdentityError.signing("building TBSCertificate: \(error)")
        }
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            Data(tbs) as CFData,
            &error
        ) as Data? else {
            throw IdentityError.signing(
                error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown"
            )
        }

        let der: Data
        do {
            der = Data(try template.certificate(signature: [UInt8](signature)))
        } catch {
            throw IdentityError.signing("assembling certificate: \(error)")
        }

        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw IdentityError.certificateRejected(byteCount: der.count)
        }

        // Validate the self-signature with something that actually checks it. A
        // fingerprint-pinning client would happily accept a certificate whose own
        // signature was garbage, so this is the only place the mistake would be
        // caught — and it must be caught here, not by whatever validates it later.
        if let failure = selfSignatureFailure(certificate) {
            throw IdentityError.selfSignatureInvalid(failure)
        }

        let add: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: certLabel,
            kSecUseKeychain as String: keychain,
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw IdentityError.keychain("SecItemAdd(certificate)", addStatus)
        }

        return try load(from: keychain)
    }

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
