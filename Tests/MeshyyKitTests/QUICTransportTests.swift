// meshyy — M2 acceptance: a session over QUIC (design doc §5, §10 M2).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Drives the real daemon: real identity out of a real keychain, real QUIC
// listener, real fingerprint pinning, real PTY. The only thing stubbed is SSH —
// the bootstrap response is fetched over the unix socket rather than an exec
// channel, which is exactly what `meshyyd attach --json` does on the far side of
// one anyway.

import Darwin
import Foundation
import MeshyyCore
import Testing
@testable import MeshyyDaemon
@testable import MeshyyKit

/// Collects frames arriving on a `MeshyyConnection`.
private final class FrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [FrameEnvelope] = []

    var all: [FrameEnvelope] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    var ptyText: String {
        String(decoding: all.filter { $0.kind == .pty }.flatMap(\.payload), as: UTF8.self)
    }

    var controlFrames: [ControlFrame] {
        all.filter { $0.kind == .control }.compactMap { try? ControlFrame.decode($0.payload) }
    }

    func append(_ frame: FrameEnvelope) {
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }

    /// Polls until `predicate` holds or the deadline passes.
    func wait(
        timeout: TimeInterval = 8,
        until predicate: @Sendable @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return predicate()
    }
}

private func markerCommand(_ marker: String) -> [UInt8] {
    // Split so the command's own echo cannot satisfy an assertion about output.
    let midpoint = marker.index(marker.startIndex, offsetBy: marker.count / 2)
    let command = "printf '%s%s\\n' '\(marker[marker.startIndex..<midpoint])' "
        + "'\(marker[midpoint...])'\n"
    return Array(command.utf8)
}

extension MeshyyKitSuite {
    @Suite("QUIC transport")
    struct QUICTransportTests {

        // MARK: - Bootstrap

        @Test("The bootstrap handshake is well-formed and carries a usable pin")
        func bootstrapShape() async throws {
            try await withHarness() { daemon in

                let response = try daemon.bootstrap(session: "boot")
                #expect(response.port == daemon.quicPort)
                #expect(response.certSHA256 == daemon.identity.fingerprint)
                #expect(response.certSHA256.count == 64)
                #expect(response.sessionID.count == 32, "session ids are 128-bit (design doc §8)")
                #expect(!response.token.isEmpty)
                #expect(response.protocol == Meshyy.protocolVersion)
                try response.validate()
            }
        }

        @Test("Two bootstraps of the same session give different tokens but one session id")
        func tokensAreFreshPerBootstrap() async throws {
            try await withHarness() { daemon in

                let first = try daemon.bootstrap(session: "same")
                let second = try daemon.bootstrap(session: "same")
                #expect(first.token != second.token, "tokens are single-use, so each bootstrap mints one")
                #expect(first.sessionID == second.sessionID, "the same name is the same session")
            }
        }

        // MARK: - M2 acceptance

        /// Design doc M2: "a session over meshyy is indistinguishable from a session
        /// over SSH." The observable version of that is: it renders, it accepts input,
        /// and it resizes.
        @Test("A shell over QUIC renders, accepts input, and resizes")
        func sessionOverQUIC() async throws {
            try await withHarness() { daemon in

                let response = try daemon.bootstrap(session: "live")
                let sink = FrameSink()
                let connection = MeshyyConnection(bootstrap: response, sshHost: "127.0.0.1")
                connection.onFrame = { sink.append($0) }
                try await connection.connect()
                defer { connection.close() }

                #expect(connection.currentState == .connected)

                try connection.send(.hello(.init(
                    token: response.token,
                    cols: 118,
                    rows: 44,
                    session: nil
                )))

                #expect(await sink.wait { sink.controlFrames.contains { frame in
                    if case .welcome = frame { return true }
                    return false
                } }, "no Welcome over QUIC; got \(sink.controlFrames)")

                guard case .welcome(let welcome)? = sink.controlFrames.first(where: {
                    if case .welcome = $0 { return true }
                    return false
                }) else {
                    Issue.record("no Welcome")
                    return
                }
                #expect(welcome.sessionID == response.sessionID,
                        "the session must be the one the token was bound to")

                try connection.sendKeystrokes(markerCommand("QUIC_RENDERS"))
                #expect(await sink.wait { sink.ptyText.contains("QUIC_RENDERS") },
                        "shell did not run the command; got \(sink.ptyText.debugDescription)")

                // The size from Hello reached the PTY.
                try connection.sendKeystrokes(Array("stty size\n".utf8))
                #expect(await sink.wait { sink.ptyText.contains("44 118") },
                        "Hello's size did not reach the shell; got \(sink.ptyText.debugDescription)")

                // And a resize does too.
                try connection.send(.resize(cols: 90, rows: 30))
                try connection.sendKeystrokes(Array("stty size\n".utf8))
                #expect(await sink.wait { sink.ptyText.contains("30 90") },
                        "resize did not reach the shell")
            }
        }

        // MARK: - §5.1 security properties

        @Test("A wrong certificate fingerprint is refused with an actionable error")
        func wrongPinIsRefused() async throws {
            try await withHarness() { daemon in

                let response = try daemon.bootstrap(session: "pin")
                let connection = MeshyyConnection(
                    host: "127.0.0.1",
                    port: response.port,
                    certificateSHA256: String(repeating: "00", count: 32)
                )
                // The M0 spike measured that a rejected pin never produces a clean failure
                // state — the group just never becomes ready — so the client's own verdict
                // is what must surface, and quickly.
                await #expect(throws: MeshyyConnection.ConnectionError.self) {
                    try await connection.connect(timeout: .seconds(6))
                }
                guard case .failed(let reason) = connection.currentState else {
                    Issue.record("expected .failed, got \(connection.currentState)")
                    return
                }
                #expect(reason.contains("fingerprint"),
                        "the reason must name the actual problem; got \(reason)")
                connection.close()
            }
        }

        @Test("A token is single-use: the second connection with it is refused")
        func tokenIsSingleUse() async throws {
            try await withHarness() { daemon in

                let response = try daemon.bootstrap(session: "once")

                let first = MeshyyConnection(bootstrap: response, sshHost: "127.0.0.1")
                let firstSink = FrameSink()
                first.onFrame = { firstSink.append($0) }
                try await first.connect()
                try first.send(.hello(.init(token: response.token, cols: 80, rows: 24)))
                #expect(await firstSink.wait { firstSink.controlFrames.contains { frame in
                    if case .welcome = frame { return true }
                    return false
                } }, "the first use of a token must succeed")

                // Same token, fresh connection.
                let second = MeshyyConnection(bootstrap: response, sshHost: "127.0.0.1")
                let secondSink = FrameSink()
                second.onFrame = { secondSink.append($0) }
                try await second.connect()
                try second.send(.hello(.init(token: response.token, cols: 80, rows: 24)))

                #expect(await secondSink.wait { secondSink.controlFrames.contains { frame in
                    if case .error = frame { return true }
                    return false
                } }, "a replayed token must be refused; got \(secondSink.controlFrames)")
                #expect(!secondSink.controlFrames.contains { frame in
                    if case .welcome = frame { return true }
                    return false
                }, "a replayed token must not yield a Welcome")

                first.close()
                second.close()
            }
        }

        @Test("A fabricated token is refused")
        func fabricatedTokenIsRefused() async throws {
            try await withHarness() { daemon in

                let response = try daemon.bootstrap(session: "forge")
                let connection = MeshyyConnection(bootstrap: response, sshHost: "127.0.0.1")
                let sink = FrameSink()
                connection.onFrame = { sink.append($0) }
                try await connection.connect()
                defer { connection.close() }

                try connection.send(.hello(.init(token: "not-a-real-token", cols: 80, rows: 24)))
                #expect(await sink.wait { sink.controlFrames.contains { frame in
                    if case .error = frame { return true }
                    return false
                } }, "an invented token must be refused; got \(sink.controlFrames)")
            }
        }

        /// The confused-deputy case. A client holding a valid token for session A must
        /// not reach session B by naming it in Hello — the token, not the client, says
        /// which session is in scope.
        @Test("Naming a different session in Hello does not escape the token's binding")
        func tokenBindingCannotBeOverridden() async throws {
            try await withHarness() { daemon in

                // Two sessions exist, each with its own id.
                let mine = try daemon.bootstrap(session: "mine")
                let theirs = try daemon.bootstrap(session: "theirs")
                #expect(mine.sessionID != theirs.sessionID)

                let connection = MeshyyConnection(bootstrap: mine, sshHost: "127.0.0.1")
                let sink = FrameSink()
                connection.onFrame = { sink.append($0) }
                try await connection.connect()
                defer { connection.close() }

                // Valid token for "mine", but asking for "theirs".
                try connection.send(.hello(.init(
                    token: mine.token,
                    cols: 80,
                    rows: 24,
                    session: "theirs"
                )))

                #expect(await sink.wait { sink.controlFrames.contains { frame in
                    if case .welcome = frame { return true }
                    return false
                } }, "the attach should still succeed — for the bound session")

                guard case .welcome(let welcome)? = sink.controlFrames.first(where: {
                    if case .welcome = $0 { return true }
                    return false
                }) else {
                    Issue.record("no Welcome")
                    return
                }
                #expect(welcome.sessionID == mine.sessionID,
                        "the token's session must win over the one named in Hello")
                #expect(welcome.sessionID != theirs.sessionID,
                        "naming another session in Hello must not reach it")
            }
        }

        // MARK: - Resume over QUIC (M3's payoff on M2's transport)

        @Test("Reconnecting over QUIC with an offset replays byte-exactly")
        func resumeOverQUIC() async throws {
            try await withHarness() { daemon in

                let first = try daemon.bootstrap(session: "resume")
                let firstSink = FrameSink()
                let firstConnection = MeshyyConnection(bootstrap: first, sshHost: "127.0.0.1")
                firstConnection.onFrame = { firstSink.append($0) }
                try await firstConnection.connect()
                try firstConnection.send(.hello(.init(token: first.token, cols: 80, rows: 24)))
                // A fresh attach replays the buffer, so the shell's prompt arrives without
                // anything being typed.
                #expect(await firstSink.wait { !firstSink.ptyText.isEmpty },
                        "a fresh attach must show the current screen, not a blank one")

                try firstConnection.sendKeystrokes(markerCommand("BEFORE_SUSPEND"))
                #expect(await firstSink.wait { firstSink.ptyText.contains("BEFORE_SUSPEND") })
                let consumed = firstSink.all.filter { $0.kind == .pty }.flatMap(\.payload)

                // iOS suspends: the connection dies without warning.
                firstConnection.close()

                // Output continues while nobody is attached.
                let session = await daemon.store.session(named: "resume")
                try await session?.send(markerCommand("WHILE_SUSPENDED"))
                try await Task.sleep(for: .milliseconds(500))

                // Foreground: a fresh bootstrap (the SSH channel is cheap) and a resume.
                let second = try daemon.bootstrap(session: "resume")
                #expect(second.sessionID == first.sessionID)
                let secondSink = FrameSink()
                let secondConnection = MeshyyConnection(bootstrap: second, sshHost: "127.0.0.1")
                secondConnection.onFrame = { secondSink.append($0) }
                try await secondConnection.connect()
                defer { secondConnection.close() }

                try secondConnection.send(.hello(.init(
                    token: second.token,
                    cols: 80,
                    rows: 24,
                    resumeFrom: UInt64(consumed.count)
                )))

                #expect(await secondSink.wait { secondSink.ptyText.contains("WHILE_SUSPENDED") },
                        "the replay must contain what happened while suspended")

                // §6.4: no gaps, no duplicates. A duplicated replay would show the
                // pre-suspend marker twice across the two clients' streams.
                let combined = String(decoding: consumed, as: UTF8.self) + secondSink.ptyText
                let occurrences = combined.components(separatedBy: "BEFORE_SUSPEND").count - 1
                #expect(occurrences == 1,
                        "resume duplicated bytes the client already had (\(occurrences) copies)")
                #expect(!secondSink.controlFrames.contains { frame in
                    if case .resumeTooOld = frame { return true }
                    return false
                }, "the 4MB default should have covered this easily")
            }
        }
    }
}
