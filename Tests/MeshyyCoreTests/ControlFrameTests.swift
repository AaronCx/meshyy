// meshyy — control-frame round trips and golden wire fixtures.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// The GOLDEN section pins the exact bytes on the wire. A diff there means the
// wire format changed. That is allowed, but it must be a deliberate act with a
// protocol-version bump considered — never a drive-by fixup to make a test pass.

import Testing
@testable import MeshyyCore

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

@Suite("Control frames")
struct ControlFrameTests {

    // MARK: - Round trips

    static let everyFrame: [ControlFrame] = [
        .hello(.init(token: "t0ken", clientVersion: "0.1.0", cols: 120, rows: 40)),
        .hello(.init(token: "t0ken", clientVersion: "0.1.0", cols: 120, rows: 40,
                     resumeFrom: 1_234_567)),
        .welcome(.init(sessionID: "5f3a", serverVersion: "0.1.0",
                       bufferedFrom: 0, bufferedTo: 4096)),
        .resize(cols: 80, rows: 25),
        .ack(ptyID: 0, offset: 987_654_321),
        .termios(.cooked),
        .termios(.rawMode),
        .screenMode(alt: true),
        .screenMode(alt: false),
        .agentEvent(kind: .waiting, agentID: nil, detail: nil),
        .agentEvent(kind: .working, agentID: "claude-code", detail: "esc to interrupt"),
        .agentEvent(kind: .idle, agentID: "claude-code", detail: nil),
        .quickActions([
            QuickAction(id: "approve", label: "Approve"),
            QuickAction(id: "deny", label: "Deny"),
            QuickAction(id: "opt2", label: "2"),
        ]),
        .quickActions([]),
        .resumeTooOld(ptyID: 0, earliestOffset: 4096),
        .sessionListRequest,
        .sessionListResponse(json: "[]"),
        .sessionListResponse(json: "[{\"name\":\"aplus-1\",\"alive\":true}]"),
        .bootstrapNewInGroup(prefix: "aplus-1f-"),
        .ping(nonce: 0),
        .ping(nonce: .max),
        .pong(nonce: 0x0123_4567_89AB_CDEF),
        .bye(reason: "client requested"),
        .error(code: 7, message: "token expired"),
    ]

    @Test("Every frame round-trips through CBOR unchanged", arguments: everyFrame)
    func roundTrip(frame: ControlFrame) throws {
        #expect(try ControlFrame.decode(frame.encoded) == frame)
    }

    @Test("resumeFrom is omitted when absent and present when set")
    func optionalResumeFrom() throws {
        let fresh = ControlFrame.hello(.init(token: "a", cols: 1, rows: 1))
        #expect(fresh.encode()["from"] == nil, "a fresh Hello must not carry a from key")

        let resuming = ControlFrame.hello(.init(token: "a", cols: 1, rows: 1, resumeFrom: 0))
        #expect(resuming.encode()["from"] == .unsigned(0),
                "resumeFrom 0 is meaningful — the client holds nothing but wants to resume")
    }

    // MARK: - §5.3 graceful version skew

    @Test("An unknown frame type decodes to .unknown rather than throwing")
    func unknownFrameType() throws {
        let future = CBOR.map([
            (.text("t"), .text("holographic-projection")),
            (.text("intensity"), .unsigned(11)),
        ])
        let decoded = try ControlFrame.decode(future)
        guard case .unknown(let type, let payload) = decoded else {
            Issue.record("expected .unknown, got \(decoded)")
            return
        }
        #expect(type == "holographic-projection")
        #expect(payload["intensity"] == .unsigned(11))
    }

    @Test("An unknown frame round-trips its payload, so a relay does not corrupt it")
    func unknownFrameRoundTrips() throws {
        let future = CBOR.map([
            (.text("t"), .text("newthing")),
            (.text("a"), .unsigned(1)),
            (.text("b"), .text("two")),
        ])
        let reencoded = try ControlFrame.decode(future).encode()
        #expect(reencoded["t"] == .text("newthing"))
        #expect(reencoded["a"] == .unsigned(1))
        #expect(reencoded["b"] == .text("two"))
    }

    @Test("Extra fields on a known frame are ignored, not fatal")
    func extraFieldsIgnored() throws {
        let fromTheFuture = CBOR.map([
            (.text("t"), .text("resize")),
            (.text("cols"), .unsigned(80)),
            (.text("rows"), .unsigned(25)),
            (.text("pixelWidth"), .unsigned(1920)),
        ])
        #expect(try ControlFrame.decode(fromTheFuture) == .resize(cols: 80, rows: 25))
    }

    @Test("An unrecognised AgentEvent kind is treated as a newer peer, not corruption")
    func unknownAgentKind() throws {
        let future = CBOR.map([
            (.text("t"), .text("agent")),
            (.text("kind"), .text("deliberating")),
        ])
        guard case .unknown = try ControlFrame.decode(future) else {
            Issue.record("an unknown agent kind must decode to .unknown")
            return
        }
    }

    @Test("A missing required field throws with the field named")
    func missingRequiredField() {
        let broken = CBOR.map([(.text("t"), .text("resize")), (.text("cols"), .unsigned(80))])
        #expect(throws: ControlFrame.FrameError.missingField("rows", in: "resize")) {
            try ControlFrame.decode(broken)
        }
    }

    @Test("A frame that is not a map is rejected")
    func nonMapRejected() {
        #expect(throws: ControlFrame.FrameError.notAMap) {
            try ControlFrame.decode(CBOR.array([.text("hello")]))
        }
        #expect(throws: ControlFrame.FrameError.missingType) {
            try ControlFrame.decode(CBOR.map([(.text("x"), .unsigned(1))]))
        }
    }

    @Test("A peer that predates the protocol-version field is treated as version 1")
    func absentProtocolVersionDefaultsToOne() throws {
        let old = CBOR.map([
            (.text("t"), .text("hello")),
            (.text("token"), .text("a")),
            (.text("cols"), .unsigned(80)),
            (.text("rows"), .unsigned(24)),
        ])
        guard case .hello(let hello) = try ControlFrame.decode(old) else {
            Issue.record("expected hello")
            return
        }
        #expect(hello.protocolVersion == 1)
        #expect(hello.clientVersion == "unknown")
    }

    // MARK: - GOLDEN wire fixtures
    //
    // A diff below is a wire-format change. Read docs/DESIGN.md §5.3 before
    // updating one, and consider whether Meshyy.protocolVersion must move.

    /// name -> exact bytes on the wire.
    static let goldens: [(name: String, frame: ControlFrame, wire: String)] = [
        ("hello_fresh",
         .hello(.init(token: "t0ken", clientVersion: "0.1.0", cols: 120, rows: 40)),
         "a661746568656c6c6f65746f6b656e6574306b656e62637665302e312e3064636f6c73187864726f7773182862707601"),
        ("hello_resume",
         .hello(.init(token: "t0ken", clientVersion: "0.1.0", cols: 120, rows: 40,
                      resumeFrom: 1_234_567)),
         "a761746568656c6c6f65746f6b656e6574306b656e62637665302e312e3064636f6c73187864726f77731828627076016466726f6d1a0012d687"),
        ("welcome",
         .welcome(.init(sessionID: "5f3a", serverVersion: "0.1.0",
                        bufferedFrom: 0, bufferedTo: 4096)),
         "a661746777656c636f6d6563736964643566336162737665302e312e30656266726f6d006362746f19100062707601"),
        ("resize", .resize(cols: 80, rows: 25),
         "a3617466726573697a6564636f6c73185064726f77731819"),
        ("ack", .ack(ptyID: 0, offset: 4096),
         "a361746361636b6370747900636f6666191000"),
        // M4 4b. Deliberately tiny: a heartbeat that costs a full MTU would be a
        // battery decision as well as a latency one.
        // `meshyyd list`. A frame with no fields at all — the type tag IS the message
        // — so this fixture is also the proof that a fieldless frame encodes and
        // decodes rather than being mistaken for a malformed map.
        ("session_list_request", .sessionListRequest, "a16174626c73"),
        ("session_list_response", .sessionListResponse(json: "[]"), "a26174636c7372646a736f6e625b5d"),
        ("bootstrap_new_in_group", .bootstrapNewInGroup(prefix: "aplus-"),
         "a2617465626f6f7467667072656669786661706c75732d"),
        ("ping", .ping(nonce: 7), "a261746470696e67616e07"),
        ("pong", .pong(nonce: 7), "a2617464706f6e67616e07"),
        ("termios_cooked", .termios(.cooked),
         "a46174677465726d696f73646563686ff5666963616e6f6ef563726177f4"),
        ("termios_raw", .termios(.rawMode),
         "a46174677465726d696f73646563686ff4666963616e6f6ef463726177f5"),
        ("screen_alt", .screenMode(alt: true),
         "a261746673637265656e63616c74f5"),
        ("agent_working",
         .agentEvent(kind: .working, agentID: "claude-code", detail: "esc to interrupt"),
         "a46174656167656e74646b696e6467776f726b696e67636169646b636c617564652d636f64656664657461696c7065736320746f20696e74657272757074"),
        ("tooold", .resumeTooOld(ptyID: 0, earliestOffset: 4096),
         "a3617466746f6f6f6c646370747900686561726c69657374191000"),
        ("bye", .bye(reason: "client requested"),
         "a261746362796566726561736f6e70636c69656e7420726571756573746564"),
        ("modes", .modes(active: [1000, 1006]),
         "a26174656d6f64657366616374697665821903e81903ee"),
        ("bye_exit", .bye(reason: "session exited with status 0", exitStatus: 0),
         "a361746362796566726561736f6e781c73657373696f6e206578697465642077697468207374617475732030646578697400"),
        ("error", .error(code: 7, message: "token expired"),
         "a36174656572726f7264636f646507636d73676d746f6b656e2065787069726564"),
        ("qa_offer",
         .quickActions([
             QuickAction(id: "approve", label: "Approve"),
             QuickAction(id: "deny", label: "Deny"),
             QuickAction(id: "opt2", label: "2"),
         ]),
         "a2617462716167616374696f6e7383a262696467617070726f7665656c6162656c67417070726f7665a26269646464656e79656c6162656c6444656e79a2626964646f707432656c6162656c6132"),
        ("qa_withdraw", .quickActions([]), "a2617462716167616374696f6e7380"),
    ]

    // MARK: - Quick actions (design doc §7.3)

    @Test("An empty quick-action list withdraws an offer and is distinct from absent")
    func quickActionWithdrawal() throws {
        let withdraw = ControlFrame.quickActions([])
        #expect(try ControlFrame.decode(withdraw.encoded) == withdraw)
        #expect(withdraw.encode()["actions"] == .array([]),
                "withdrawal must be an explicit empty list, not a missing key")
    }

    /// Design doc §7.3: a malformed entry drops that action, not the whole frame.
    /// A partly-understood offer is still safe, because everything a client acts
    /// on comes from its own profile.
    @Test("A malformed quick action is dropped without discarding the others")
    func malformedQuickActionIsDropped() throws {
        let mixed = CBOR.map([
            (.text("t"), .text("qa")),
            (.text("actions"), .array([
                .map([(.text("id"), .text("ok")), (.text("label"), .text("Approve"))]),
                .map([(.text("id"), .text("no-label"))]),
                .map([(.text("label"), .text("no id"))]),
                .map([(.text("id"), .text("fine")), (.text("label"), .text("Deny"))]),
            ])),
        ])
        #expect(try ControlFrame.decode(mixed) == .quickActions([
            QuickAction(id: "ok", label: "Approve"),
            QuickAction(id: "fine", label: "Deny"),
        ]))
    }

    /// The security property from §7.3: the wire carries an id and a label and
    /// nothing else. Bytes-to-send live only in the client's local profile, so a
    /// remote cannot choose what a tap sends even if it forges the whole frame.
    @Test("The wire form of a quick action carries no payload for the client to send")
    func quickActionCarriesNoPayload() {
        let encoded = ControlFrame.quickActions([
            QuickAction(id: "approve", label: "Approve"),
        ]).encode()
        guard let actions = encoded["actions"]?.arrayValue, let first = actions.first,
              case .map(let fields) = first
        else {
            Issue.record("unexpected encoding: \(encoded)")
            return
        }
        let keys = Set(fields.compactMap { $0.0.stringValue })
        #expect(keys == ["id", "label"],
                "a quick action must never carry sendable bytes on the wire; got \(keys)")
    }

    @Test("Golden: the bytes on the wire are exactly these", arguments: goldens)
    func goldenWireFormat(golden: (name: String, frame: ControlFrame, wire: String)) {
        #expect(hex(golden.frame.encoded) == golden.wire,
                "\(golden.name): wire format changed — read docs/DESIGN.md §5.3 before updating")
    }

    @Test("Golden: every fixture decodes back to the frame it came from", arguments: goldens)
    func goldenDecodes(golden: (name: String, frame: ControlFrame, wire: String)) throws {
        var bytes: [UInt8] = []
        var index = golden.wire.startIndex
        while index < golden.wire.endIndex {
            let next = golden.wire.index(index, offsetBy: 2)
            bytes.append(UInt8(golden.wire[index..<next], radix: 16)!)
            index = next
        }
        #expect(try ControlFrame.decode(bytes) == golden.frame, "\(golden.name)")
    }
}
