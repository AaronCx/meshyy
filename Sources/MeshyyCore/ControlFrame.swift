// meshyy — control-stream frames (design doc §5.3).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Everything is additive and unknown frame types decode to `.unknown` rather
// than failing, so version skew degrades gracefully in both directions. That is
// a protocol guarantee, not an implementation detail; `ControlFrameTests` pins it.

import Foundation

/// One thing the user can do to the agent in a single tap (design doc §7.3).
///
/// The label and the bytes both come from the local `AgentProfile`. Remote output
/// only selects *which* action matches — it never supplies either field. That
/// separation is the whole security property: otherwise a remote that draws a
/// convincing fake permission prompt gets to choose what a tap sends.
public struct QuickAction: Sendable, Equatable {
    /// Stable identifier from the profile, so a client can remember placement.
    public var id: String
    /// What the button says. From the profile, never from the output stream.
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

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
    /// Liveness probe (M4 4b). The client sends `ping`, the daemon echoes the nonce
    /// back as `pong`.
    ///
    /// A round trip on the control stream is the only thing that proves the path is
    /// still two-way. Measured in 1d-bis: after a NAT rebind the client's transport
    /// reports `.connected` while nothing at all is arriving, so "my sends succeed"
    /// is not evidence of anything.
    ///
    /// The nonce exists so a late pong cannot satisfy a later ping — without it, one
    /// straggler arriving after two missed probes would reset the miss count and the
    /// deadline would never fire.
    case ping(nonce: UInt64)
    case pong(nonce: UInt64)
    case termios(TermiosState)
    case screenMode(alt: Bool)
    case agentEvent(kind: AgentEventKind, agentID: String?, detail: String?)
    /// The absolute offset the bytes that follow begin at.
    ///
    /// Always sent immediately before a replay, on every attach. Without it a
    /// client cannot do its own offset arithmetic in the `fresh` and
    /// `replayFromAnchor` cases: it knows how many bytes it received but not where
    /// they started, so its next `Ack` — and therefore its next resume — would be
    /// wrong by however much the daemon chose to rewind.
    ///
    /// Deliberately separate from `resumeTooOld`: that frame is the *warning* that
    /// a gap occurred, this one is the *arithmetic*. Overloading one to mean both
    /// made the fresh-attach case unrepresentable.
    case replayBase(ptyID: Int, offset: UInt64)
    /// The actions currently answerable in one tap (design doc §7.3). An empty
    /// list withdraws a previous offer — sent on a full clear, an alt-screen
    /// transition, or when the matched prompt leaves the output tail.
    case quickActions([QuickAction])
    case resumeTooOld(ptyID: Int, earliestOffset: UInt64)
    /// Asks the daemon for a session and a single-use token (design doc §5.1
    /// step 2). Local transport only — over QUIC the handshake has already
    /// happened, and answering this there would let a connection mint itself a
    /// fresh token, defeating single use.
    /// Enumerate the daemon's live sessions (`meshyyd list`).
    ///
    /// Added because persistence that cannot be observed cannot be trusted: the first
    /// user of the feature reported "I'm not seeing this stay alive server side", and
    /// they were right — `list` printed "not implemented" and there was no way to check
    /// whether a session existed at all. A claim nobody can verify is indistinguishable
    /// from a false one.
    /// End a session and the shell behind it (`meshyyd kill NAME`).
    ///
    /// Added because there was no way to remove one. A client that stops attaching
    /// leaves the session running forever, and with a shell rc that auto-attaches a
    /// multiplexer, orphans accumulate into a pile that silently degrades every live
    /// session — tmux sizes to its smallest client, so one stale attachment clamps the
    /// terminal for all of them.
    case sessionKillRequest(name: String)
    case sessionListRequest
    /// JSON array of live sessions. A JSON payload rather than a CBOR structure for the
    /// same reason `bootstrapResponse` uses one: this is diagnostic output for a human
    /// and a script, not a hot path, and a schema change here must not need a new frame.
    case sessionListResponse(json: String)
    case bootstrapRequest(session: String)
    /// The §5.1 handshake, as the JSON the client parses. Carried as an opaque
    /// string rather than re-modelled so the bytes the client sees are exactly the
    /// bytes the daemon produced.
    case bootstrapResponse(json: String)
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
        /// Session to attach to, by name.
        ///
        /// Unused over QUIC, where §5.1's single-use token is already bound to a
        /// session id and naming a second one would be a confused-deputy hole.
        /// Needed over the unix socket, where there is no token to bind: the
        /// caller has already proved local access by opening a 0600 socket.
        public var session: String?
        public var protocolVersion: Int

        public init(
            token: String,
            clientVersion: String = Meshyy.version,
            cols: Int,
            rows: Int,
            resumeFrom: UInt64? = nil,
            session: String? = nil,
            protocolVersion: Int = Meshyy.protocolVersion
        ) {
            self.token = token
            self.clientVersion = clientVersion
            self.cols = cols
            self.rows = rows
            self.resumeFrom = resumeFrom
            self.session = session
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
        case .ping: "ping"
        case .pong: "pong"
        case .termios: "termios"
        case .screenMode: "screen"
        case .agentEvent: "agent"
        case .quickActions: "qa"
        case .replayBase: "base"
        case .sessionKillRequest: "kill"
        case .sessionListRequest: "ls"
        case .sessionListResponse: "lsr"
        case .bootstrapRequest: "boot"
        case .bootstrapResponse: "booted"
        case .resumeTooOld: "tooold"
        case .bye: "bye"
        case .error: "error"
        case .unknown(let type, _): type
        }
    }
}

// MARK: - Encoding

extension ControlFrame {
    /// Field order is fixed so the `goldens` table in `ControlFrameTests` stays
    /// stable. Changing the order is a wire-format change and shows up there as a
    /// diff — which is the point.
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
            if let session = hello.session {
                pairs.append((.text("sess"), .text(session)))
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
        case .ping(let nonce), .pong(let nonce):
            pairs.append((.text("n"), .unsigned(nonce)))
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
        case .replayBase(let ptyID, let offset):
            pairs.append((.text("pty"), .int(ptyID)))
            pairs.append((.text("off"), .unsigned(offset)))
        case .quickActions(let actions):
            pairs.append((.text("actions"), .array(actions.map { action in
                .map([(.text("id"), .text(action.id)), (.text("label"), .text(action.label))])
            })))
        case .resumeTooOld(let ptyID, let earliestOffset):
            pairs.append((.text("pty"), .int(ptyID)))
            pairs.append((.text("earliest"), .unsigned(earliestOffset)))
        case .sessionKillRequest(let name):
            pairs.append((.text("name"), .text(name)))
        case .sessionListRequest:
            break   // the type tag is the whole message
        case .sessionListResponse(let json):
            pairs.append((.text("json"), .text(json)))
        case .bootstrapRequest(let session):
            pairs.append((.text("sess"), .text(session)))
        case .bootstrapResponse(let json):
            pairs.append((.text("json"), .text(json)))
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
                session: item["sess"]?.stringValue,
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
        case "ping":
            return .ping(nonce: try requiredOffset("n"))
        case "pong":
            return .pong(nonce: try requiredOffset("n"))
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
        case "base":
            return .replayBase(ptyID: try requiredInt("pty"), offset: try requiredOffset("off"))
        case "qa":
            // A malformed entry drops that action rather than the whole frame: a
            // partly-understood offer is still safe, because every field a client
            // acts on comes from its own profile.
            let actions = (item["actions"]?.arrayValue ?? []).compactMap { entry -> QuickAction? in
                guard let id = entry["id"]?.stringValue,
                      let label = entry["label"]?.stringValue
                else { return nil }
                return QuickAction(id: id, label: label)
            }
            return .quickActions(actions)
        case "tooold":
            return .resumeTooOld(
                ptyID: try requiredInt("pty"),
                earliestOffset: try requiredOffset("earliest")
            )
        case "kill":
            return .sessionKillRequest(name: try requiredText("name"))
        case "ls":
            return .sessionListRequest
        case "lsr":
            return .sessionListResponse(json: try requiredText("json"))
        case "boot":
            return .bootstrapRequest(session: try requiredText("sess"))
        case "booted":
            return .bootstrapResponse(json: try requiredText("json"))
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
