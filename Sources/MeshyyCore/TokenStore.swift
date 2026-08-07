// meshyy — single-use bootstrap tokens (design doc §5.1, §8).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// "Tokens are single-use, TTL 60 seconds, and bound to session_id."
//
// The token is what carries authentication across the gap between the SSH channel
// closing and the QUIC connection opening. It is issued over a channel the user
// has already authenticated and is redeemed once, so a token observed later is
// worthless — which is what lets §8 say a stolen session id alone is useless.
//
// Time is injected rather than read from the clock so expiry is tested
// deterministically instead of with sleeps.

import Foundation
import Security

/// Issues and redeems bootstrap tokens.
///
/// Not thread-safe; the daemon owns one behind an actor.
public struct TokenStore: Sendable {
    /// Design doc §5.1. Long enough for an SSH channel to close and a QUIC
    /// handshake to complete on a bad cellular link, short enough that a token
    /// captured from a log is dead before anyone reads the log.
    public static let defaultTTL = Duration.seconds(60)

    /// 256 bits. Overkill for a 60-second single-use credential, and the right
    /// kind of overkill.
    public static let tokenBytes = 32

    public enum RedemptionFailure: Error, Equatable, CustomStringConvertible {
        /// No such token: never issued, already redeemed, or swept after expiry.
        /// Deliberately one case rather than three — telling a caller *which*
        /// would let it distinguish "wrong token" from "expired token", which is
        /// a probing oracle.
        case unknownToken
        /// The token is real but was issued for a different session.
        case wrongSession(expected: String)

        public var description: String {
            switch self {
            case .unknownToken: "token: unknown, already used, or expired"
            case .wrongSession: "token: issued for a different session"
            }
        }
    }

    private struct Issued {
        let sessionID: String
        let expiresAt: ContinuousClock.Instant
    }

    private var issued: [String: Issued] = [:]
    private let ttl: Duration

    public init(ttl: Duration = TokenStore.defaultTTL) {
        self.ttl = ttl
    }

    public var outstandingCount: Int { issued.count }

    /// Issues a token bound to `sessionID`, expiring `ttl` from `now`.
    public mutating func issue(
        sessionID: String,
        now: ContinuousClock.Instant,
        randomBytes: (Int) throws -> [UInt8] = TokenStore.secureRandom
    ) rethrows -> String {
        sweepExpired(now: now)
        let token = Self.encode(try randomBytes(Self.tokenBytes))
        issued[token] = Issued(sessionID: sessionID, expiresAt: now.advanced(by: ttl))
        return token
    }

    /// Redeems `token` and returns the session it was issued for.
    ///
    /// The session id comes *from the token*, not from the client — that is the
    /// point of binding them (design doc §5.1). A client cannot redeem a valid
    /// token against a session it was not issued for, because it does not get to
    /// name the session at all.
    ///
    /// `assertingSession`, when given, is checked as defence in depth: the client
    /// received a session id from the bootstrap response and asserting it catches
    /// a daemon-side mix-up that would otherwise attach someone to the wrong
    /// terminal.
    ///
    /// The token is removed before any check, so a token presented with a
    /// mismatched session is still burned — otherwise a holder could probe session
    /// ids with it until one matched.
    @discardableResult
    public mutating func redeem(
        token: String,
        assertingSession: String? = nil,
        now: ContinuousClock.Instant
    ) -> Result<String, RedemptionFailure> {
        sweepExpired(now: now)
        guard let record = issued.removeValue(forKey: token) else {
            return .failure(.unknownToken)
        }
        guard record.expiresAt > now else { return .failure(.unknownToken) }
        if let asserted = assertingSession,
           !constantTimeEquals(record.sessionID, asserted) {
            return .failure(.wrongSession(expected: record.sessionID))
        }
        return .success(record.sessionID)
    }

    /// Drops expired tokens. Called on every issue and redeem, so a daemon that
    /// is never connected to does not accumulate them.
    public mutating func sweepExpired(now: ContinuousClock.Instant) {
        issued = issued.filter { $0.value.expiresAt > now }
    }

    /// Invalidates every token for a session — called when the session closes, so
    /// a token cannot outlive the thing it names.
    public mutating func revokeAll(sessionID: String) {
        issued = issued.filter { $0.value.sessionID != sessionID }
    }

    // MARK: - Primitives

    /// Base64url without padding: safe in a URL, a filename, an argv, and a log
    /// line, and it survives a round trip through JSON without escaping.
    static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A fresh base64url secret of `bytes` length. Used for tokens and for the
    /// daemon keychain's password, which wants the same properties.
    public static func randomSecret(bytes: Int = TokenStore.tokenBytes) throws -> String {
        encode(try secureRandom(bytes))
    }

    /// The CSPRNG refused. Thrown rather than swallowed: token minting has no
    /// meaningful degraded mode, and a partially filled buffer presented as
    /// entropy is strictly worse than a loud failure.
    public struct EntropyUnavailable: Error, CustomStringConvertible {
        public let status: Int32
        public var description: String {
            "SecRandomCopyBytes failed (\(status)); refusing to mint from a partial buffer"
        }
    }

    /// `SecRandomCopyBytes`, not `UInt8.random(in:using:)`. The loop it
    /// replaces was CORRECT — SystemRandomNumberGenerator is CSPRNG-backed on
    /// Apple platforms — but a reviewer skimming an auth path sees a loop of
    /// `random(in:)` and has to stop and reason about it. The system call
    /// states the intent in its name, and a non-zero status throws rather
    /// than returning a partially filled buffer as if it were entropy. The
    /// injectable `randomBytes` parameter is kept — determinism in tests is
    /// worth more than this swap.
    public static func secureRandom(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw EntropyUnavailable(status: status) }
        return bytes
    }

    /// Compares without an early return on the first differing byte.
    ///
    /// Session ids are not secret — §8 says a stolen one is useless on its own —
    /// so this is not load-bearing. It is here because a comparison in an
    /// authentication path that *looks* like it leaks timing invites someone to
    /// copy the pattern somewhere it matters.
    func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices {
            difference |= a[index] ^ b[index]
        }
        return difference == 0
    }
}
