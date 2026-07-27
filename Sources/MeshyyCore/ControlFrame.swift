// meshyy — control-stream frames (design doc §5.3).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Everything is additive and unknown frame types decode to `.unknown` rather
// than failing, so version skew degrades gracefully in both directions. That is
// a protocol guarantee, not an implementation detail: `UnknownFrameTests` pins it.

import Foundation

/// Agent status carried on the control stream (design doc §5.3 `AgentEvent`).
public enum AgentEventKind: String, Sendable, Equatable, CaseIterable {
    case waiting
    case working
    case idle
}

/// A single control-stream message.
public enum ControlFrame: Sendable, Equatable {
    case hello(Hello)
    case welcome(Welcome)
    case resize(cols: Int, rows: Int)
    case ack(ptyID: Int, offset: UInt64)
    case termios(TermiosState)
    case screenMode(alt: Bool)
    case agentEvent(kind: AgentEventKind, agentID: String?, detail: String?)
    case resumeTooOld(ptyID: Int, earliestOffset: UInt64)
    case bye(reason: String)
    case error(code: Int, message: String)
    /// A frame this build does not know. Design doc §5.3: ignore it, but keep it
    /// visible so a receiver can log or count what it skipped.
    case unknown(type: String, payload: CBOR)

    public struct Hello: Sendable, Equatable {
        public var token: String
        public var clientVersion: String
        public var cols: Int
        public var rows: Int
        /// Byte offset the client already holds. Absent on a fresh session.
        public var resumeFrom: UInt64?
        public var protocolVersion: Int

        public init(
            token: String,
            clientVersion: String = Meshyy.version,
            cols: Int,
            rows: Int,
            resumeFrom: UInt64? = nil,
            protocolVersion: Int = Meshyy.protocolVersion
        ) {
            self.token = token
            self.clientVersion = clientVersion
            self.cols = cols
            self.rows = rows
            self.resumeFrom = resumeFrom
            self.protocolVersion = protocolVersion
        }
    }

    public struct Welcome: Sendable, Equatable {
        public var sessionID: String
        public var serverVersion: String
        /// Oldest and newest byte offsets the daemon can still replay. The
        /// client compares its own offset against this window to know whether a
        /// resume will be honoured before it asks.
        public var bufferedFrom: UInt64
        public var bufferedTo: UInt64
        public var protocolVersion: Int

        public init(
            sessionID: String,
            serverVersion: String = Meshyy.version,
            bufferedFrom: UInt64,
            bufferedTo: UInt64,
            protocolVersion: Int = Meshyy.protocolVersion
        ) {
            self.sessionID = sessionID
            self.serverVersion = serverVersion
            self.bufferedFrom = bufferedFrom
            self.bufferedTo = bufferedTo
            self.protocolVersion = protocolVersion
        }
    }

    /// Wire tag. Short because these ride on every keystroke burst's control
    /// traffic; long enough to read in a hex dump.
    var wireType: String {
        switch self {
        case .hello: "hello"
        case .welcome: "welcome"
        case .resize: "resize"
        case .ack: "ack"
        case .termios: "termios"
        case .screenMode: "screen"
        case .agentEvent: "agent"
        case .resumeTooOld: "tooold"
        case .bye: "bye"
        case .error: "error"
        case .unknown(let type, _): type
        }
    }
}

// MARK: - Encoding

extension ControlFrame {
    /// Field order is fixed so the golden fixtures in
    /// `Tests/MeshyyCoreTests/Fixtures` stay stable. Changing the order is a
    /// wire-format change and will show up as a fixture diff.
    public func encode() -> CBOR {
        var pairs: [(CBOR, CBOR)] = [(.text("t"), .text(wireType))]

        switch self {
        case .hello(let hello):
            pairs.append((.text("token"), .text(hello.token)))
            pairs.append((.text("cv"), .text(hello.clientVersion)))
            pairs.append((.text("cols"), .int(hello.cols)))
            pairs.append((.text("rows"), .int(hello.rows)))
            pairs.append((.text("pv"), .int(hello.protocolVersion)))
            if let resumeFrom = hello.resumeFrom {
                pairs.append((.text("from"), .unsigned(resumeFrom)))
            }
        case .welcome(let welcome):
            pairs.append((.text("sid"), .text(welcome.sessionID)))
            pairs.append((.text("sv"), .text(welcome.serverVersion)))
            pairs.append((.text("bfrom"), .unsigned(welcome.bufferedFrom)))
            pairs.append((.text("bto"), .unsigned(welcome.bufferedTo)))
            pairs.append((.text("pv"), .int(welcome.protocolVersion)))
        case .resize(let cols, let rows):
            pairs.append((.text("cols"), .int(cols)))
            pairs.append((.text("rows"), .int(rows)))
        case .ack(let ptyID, let offset):
            pairs.append((.text("pty"), .int(ptyID)))
            pairs.append((.text("off"), .unsigned(offset)))
        case .termios(let state):
            pairs.append((.text("echo"), .bool(state.echo)))
            pairs.append((.text("icanon"), .bool(state.icanon)))
            pairs.append((.text("raw"), .bool(state.raw)))
        case .screenMode(let alt):
            pairs.append((.text("alt"), .bool(alt)))
        case .agentEvent(let kind, let agentID, let detail):
            pairs.append((.text("kind"), .text(kind.rawValue)))
            if let agentID { pairs.append((.text("aid"), .text(agentID))) }
            if let detail { pairs.append((.text("detail"), .text(detail))) }
        case .resumeTooOld(let ptyID, let earliestOffset):
            pairs.append((.text("pty"), .int(ptyID)))
            pairs.append((.text("earliest"), .unsigned(earliestOffset)))
        case .bye(let reason):
            pairs.append((.text("reason"), .text(reason)))
        case .error(let code, let message):
            pairs.append((.text("code"), .int(code)))
            pairs.append((.text("msg"), .text(message)))
        case .unknown(_, let payload):
            // Round-trips whatever came in, minus the type tag we already wrote.
            if case .map(let inner) = payload {
                pairs.append(contentsOf: inner.filter { $0.0 != .text("t") })
            }
        }

        return .map(pairs)
    }

    public var encoded: [UInt8] { encode().encode() }
}

// MARK: - Decoding

extension ControlFrame {
    public enum FrameError: Error, Equatable, CustomStringConvertible {
        case notAMap
        case missingType
        case missingField(String, in: String)

        public var description: String {
            switch self {
            case .notAMap: "frame: top level is not a map"
            case .missingType: "frame: no type tag"
            case .missingField(let field, let type):
                "frame: \(type) is missing required field \(field)"
            }
        }
    }

    public static func decode(_ bytes: [UInt8]) throws -> ControlFrame {
        try decode(CBOR.decode(bytes))
    }

    public static func decode(_ item: CBOR) throws -> ControlFrame {
        guard case .map = item else { throw FrameError.notAMap }
        guard let type = item["t"]?.stringValue else { throw FrameError.missingType }

        func requiredInt(_ key: String) throws -> Int {
            guard let value = item[key]?.intValue else {
                throw FrameError.missingField(key, in: type)
            }
            return value
        }
        func requiredOffset(_ key: String) throws -> UInt64 {
            guard let value = item[key]?.uint64Value else {
                throw FrameError.missingField(key, in: type)
            }
            return value
        }
        func requiredText(_ key: String) throws -> String {
            guard let value = item[key]?.stringValue else {
                throw FrameError.missingField(key, in: type)
            }
            return value
        }
        func requiredBool(_ key: String) throws -> Bool {
            guard let value = item[key]?.boolValue else {
                throw FrameError.missingField(key, in: type)
            }
            return value
        }

        switch type {
        case "hello":
            return .hello(Hello(
                token: try requiredText("token"),
                clientVersion: item["cv"]?.stringValue ?? "unknown",
                cols: try requiredInt("cols"),
                rows: try requiredInt("rows"),
                resumeFrom: item["from"]?.uint64Value,
                // A peer that predates the field is protocol 1 by definition.
                protocolVersion: item["pv"]?.intValue ?? 1
            ))
        case "welcome":
            return .welcome(Welcome(
                sessionID: try requiredText("sid"),
                serverVersion: item["sv"]?.stringValue ?? "unknown",
                bufferedFrom: try requiredOffset("bfrom"),
                bufferedTo: try requiredOffset("bto"),
                protocolVersion: item["pv"]?.intValue ?? 1
            ))
        case "resize":
            return .resize(cols: try requiredInt("cols"), rows: try requiredInt("rows"))
        case "ack":
            return .ack(ptyID: try requiredInt("pty"), offset: try requiredOffset("off"))
        case "termios":
            return .termios(TermiosState(
                echo: try requiredBool("echo"),
                icanon: try requiredBool("icanon"),
                raw: try requiredBool("raw")
            ))
        case "screen":
            return .screenMode(alt: try requiredBool("alt"))
        case "agent":
            let raw = try requiredText("kind")
            guard let kind = AgentEventKind(rawValue: raw) else {
                // An unrecognised kind is a *newer* peer, not a corrupt frame.
                // Treating it as unknown keeps §5.3's guarantee intact.
                return .unknown(type: type, payload: item)
            }
            return .agentEvent(
                kind: kind,
                agentID: item["aid"]?.stringValue,
                detail: item["detail"]?.stringValue
            )
        case "tooold":
            return .resumeTooOld(
                ptyID: try requiredInt("pty"),
                earliestOffset: try requiredOffset("earliest")
            )
        case "bye":
            return .bye(reason: item["reason"]?.stringValue ?? "")
        case "error":
            return .error(
                code: item["code"]?.intValue ?? 0,
                message: item["msg"]?.stringValue ?? ""
            )
        default:
            return .unknown(type: type, payload: item)
        }
    }
}
