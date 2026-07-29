// meshyy — the handshake the SSH exec channel carries (design doc §5.1).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
//   1. Client connects over SSH. Host key pinning, key auth and candidate-host
//      fallback all apply unchanged — meshyy reimplements no authentication.
//   2. Exec channel: `meshyyd attach --session <name> --json`
//   3. Daemon answers with this object.
//   4. SSH channel closes.
//   5. Client opens QUIC, pins the server cert against `certSHA256`, and presents
//      `token` in the first control frame.
//
// The trust chain terminates in a decision the user already made: SSH's pinned
// host key transitively secures the QUIC certificate's fingerprint, so no CA is
// involved and no new trust prompt appears.
//
// JSON rather than CBOR, uniquely in this protocol, because it crosses an SSH
// exec channel that a human may well be reading in a terminal while debugging.

import Foundation

/// What `meshyyd attach --json` prints on stdout.
public struct BootstrapResponse: Sendable, Equatable, Codable {
    /// UDP port the QUIC listener is bound to.
    public var port: UInt16
    /// Single-use, short-TTL, bound to `sessionID` (design doc §5.1).
    public var token: String
    /// Lowercase hex SHA-256 of the server certificate's DER. 64 characters.
    public var certSHA256: String
    /// 128-bit random session identifier (design doc §8).
    public var sessionID: String
    public var `protocol`: Int
    /// Host the client should dial. Absent means "the host you SSH'd to", which
    /// is the normal case; present when the daemon is bound to a specific
    /// interface address the SSH hostname would not resolve to.
    public var host: String?
    /// The session's name. Optional for wire compatibility with older daemons, but
    /// THE answer when the daemon allocated the name (`attach --new-in-group`): a
    /// client that asked for a new session learns here which one it got, and a
    /// missing name on that path means the far end is too old to have understood
    /// the request.
    public var name: String?

    public init(
        port: UInt16,
        token: String,
        certSHA256: String,
        sessionID: String,
        protocol protocolVersion: Int = Meshyy.protocolVersion,
        host: String? = nil,
        name: String? = nil
    ) {
        self.port = port
        self.token = token
        self.certSHA256 = certSHA256
        self.sessionID = sessionID
        self.protocol = protocolVersion
        self.host = host
        self.name = name
    }

    // Snake case on the wire, as design doc §5.1 spells it.
    enum CodingKeys: String, CodingKey {
        case port
        case token
        case certSHA256 = "cert_sha256"
        case sessionID = "session_id"
        case `protocol`
        case host
        case name
    }

    public enum BootstrapError: Error, Equatable, CustomStringConvertible {
        case notJSON(String)
        case badFingerprint(String)
        case badPort(Int)
        case unsupportedProtocol(Int)
        case emptyToken

        public var description: String {
            switch self {
            case .notJSON(let detail):
                "bootstrap: daemon did not answer with JSON (\(detail))"
            case .badFingerprint(let value):
                "bootstrap: cert_sha256 is not 64 hex characters: \(value.debugDescription)"
            case .badPort(let port):
                "bootstrap: port \(port) is out of range"
            case .unsupportedProtocol(let version):
                "bootstrap: daemon speaks protocol \(version); this client speaks "
                    + "\(Meshyy.protocolVersion)"
            case .emptyToken:
                "bootstrap: daemon issued an empty token"
            }
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        // Sorted so the output is stable and diffable when a human is staring at
        // it over SSH; withoutEscapingSlashes because a base64 token would
        // otherwise come back full of backslashes for no reason.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Parses the daemon's answer out of an exec channel's stdout.
    ///
    /// Tolerates surrounding noise on purpose: a login shell may print a MOTD, a
    /// shell rc may echo something, and the SSH server may add a banner. The JSON
    /// object is located rather than assumed to be the whole of stdout — a
    /// parser that required clean stdout would fail on most real hosts.
    public static func parse(_ output: String) throws -> BootstrapResponse {
        guard let json = extractJSONObject(from: output) else {
            throw BootstrapError.notJSON("no JSON object found in \(output.count) bytes of output")
        }
        let decoded: BootstrapResponse
        do {
            decoded = try JSONDecoder().decode(BootstrapResponse.self, from: Data(json.utf8))
        } catch {
            throw BootstrapError.notJSON("\(error)")
        }
        try decoded.validate()
        return decoded
    }

    /// Rejects a malformed response before any of it is used to open a socket or
    /// pin a certificate. Design doc §3.5: fail visible, and fail early.
    ///
    /// The protocol check is a sanity floor, NOT an equality gate. Frames are
    /// additive (§5.3), so a NEWER daemon is compatible by design — and version
    /// POLICY belongs to the caller, who can render a real "daemon is older/newer"
    /// message. An equality check here would pre-break every fielded client on the
    /// day the version first bumps, with an error claiming the response was
    /// unreadable when it read it perfectly well.
    public func validate() throws {
        guard `protocol` >= 1 else {
            throw BootstrapError.unsupportedProtocol(`protocol`)
        }
        guard !token.isEmpty else { throw BootstrapError.emptyToken }
        guard port != 0 else { throw BootstrapError.badPort(Int(port)) }
        guard certSHA256.count == 64,
              certSHA256.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
        else {
            throw BootstrapError.badFingerprint(certSHA256)
        }
    }

    /// Finds the first balanced `{...}` run, ignoring braces inside strings.
    ///
    /// Written out rather than trimming to the first `{` and last `}` because a
    /// MOTD containing a brace would break that, and a fingerprint-pinning
    /// handshake is the wrong place to be relaxed about parsing.
    static func extractJSONObject(from text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        var start: Int?
        var depth = 0
        var inString = false
        var escaped = false

        for (index, scalar) in scalars.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                continue
            }
            switch scalar {
            case "\"":
                inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                guard depth > 0 else { break }
                depth -= 1
                if depth == 0, let begin = start {
                    return String(String.UnicodeScalarView(scalars[begin...index]))
                }
            default:
                break
            }
        }
        return nil
    }

    /// The argv the client runs on the SSH exec channel.
    ///
    /// Returned as explicit argv, never as a joined string: design doc §8 forbids
    /// shell invocation with interpolated strings, and a session name is
    /// user-supplied input that would otherwise be a command-injection vector.
    public static func execArguments(session: String) -> [String] {
        ["meshyyd", "attach", "--session", session, "--json"]
    }
}
