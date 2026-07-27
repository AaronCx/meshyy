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
        .resumeTooOld(ptyID: 0, earliestOffset: 4096),
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
        ("error", .error(code: 7, message: "token expired"),
         "a36174656572726f7264636f646507636d73676d746f6b656e2065787069726564"),
    ]

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
