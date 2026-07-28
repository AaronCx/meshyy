// meshyy — the adversarial cases the 1g gap analysis found uncovered.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// 1g asked for the nine listed adversarial cases to be checked against the existing
// corpus, with only the missing ones added and the before/after counts reported. The
// analysis is in docs/qa/test-inventory.md. Six were already covered, one partially,
// and two were not covered at all — both of them protocol-abuse cases rather than
// network-failure ones, which is consistent: the suite grew out of resume correctness,
// and a peer that lies had never been the subject.
//
// A NOTE ON HOW THE ANALYSIS WAS DONE, because the first attempt was wrong in a way
// this project has been burned by twice. Grepping the suite for keywords reported all
// nine as covered. Two of those were false positives — one matched the bare word
// "twice" in an unrelated comment, the other matched "simultaneous" in the M4
// reconnect tests, which are about trigger concurrency and not about sessions at all.
// Coverage claims established by keyword are exactly what produced the vacuous privacy
// gate and the unpinned `ClientModel`. The real analysis was done by reading every
// test name in the suite.

import Foundation
import MeshyyCore
import Testing
@testable import MeshyyDaemon
@testable import MeshyyKit

extension MeshyyKitSuite {
    @Suite("Adversarial protocol cases (1g)")
    struct AdversarialTests {

        /// Collects frames, locally — see the note in `ChaosTransportTests`.
        private final class Sink: @unchecked Sendable {
            private let lock = NSLock()
            private var frames: [FrameEnvelope] = []

            var all: [FrameEnvelope] {
                lock.lock()
                defer { lock.unlock() }
                return frames
            }

            var ptyBytes: [UInt8] { all.filter { $0.kind == .pty }.flatMap(\.payload) }

            var controls: [ControlFrame] {
                all.filter { $0.kind == .control }.compactMap { try? ControlFrame.decode($0.payload) }
            }

            var welcomes: Int {
                controls.filter { if case .welcome = $0 { return true } else { return false } }.count
            }

            func append(_ frame: FrameEnvelope) {
                lock.lock()
                frames.append(frame)
                lock.unlock()
            }

            func wait(
                timeout: TimeInterval = 20,
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

        // MARK: - Case 5: a duplicate Hello on one connection

        /// A second `Hello` down a connection that has already attached.
        ///
        /// Not the same as the two cases that looked like it and are already covered:
        /// `tokensAreFreshPerBootstrap` is about two *bootstraps*, and the single-use
        /// token test is about two *connections*. This is one connection attaching
        /// twice, which is what a confused client — or a peer probing for a way to
        /// re-attach without a fresh token — actually sends.
        ///
        /// The danger is not the extra Welcome. It is that a second attach could
        /// re-run the resume path and replay the buffer *again* down a connection that
        /// has already had it, duplicating everything on screen. §6.4 says the byte
        /// stream survives; a duplicate is a violation of it just as a gap is.
        @Test("A duplicate Hello does not replay the session a second time")
        func duplicateHelloDoesNotReplay() async throws {
            try await withHarness { daemon in
                let response = try daemon.bootstrap(session: "dup")
                let sink = Sink()
                let connection = MeshyyConnection(bootstrap: response, sshHost: "127.0.0.1")
                connection.onFrame = { sink.append($0) }
                try await connection.connect()
                defer { connection.close() }

                try connection.send(.hello(.init(
                    token: response.token, cols: 80, rows: 24, session: nil
                )))
                #expect(await sink.wait { sink.welcomes >= 1 }, "no Welcome for the first Hello")

                let marker = Array("adversarial-duplicate-hello\n".utf8)
                try connection.sendKeystrokes(marker)
                #expect(await sink.wait { sink.ptyBytes.contains(marker) })
                let afterFirst = sink.ptyBytes

                // The same connection says hello again. The token has already been
                // spent by the first one.
                try connection.send(.hello(.init(
                    token: response.token, cols: 80, rows: 24, session: nil
                )))
                try await Task.sleep(for: .milliseconds(600))

                let afterSecond = sink.ptyBytes
                // Whatever the daemon decides to do about the duplicate — answer it,
                // ignore it, or refuse it — it must not push the buffer down the wire
                // again. Asserted on bytes rather than on frames because a replay is
                // only visible as content the user reads twice.
                let occurrences = afterSecond.ranges(of: marker).count
                #expect(occurrences == 1,
                        "the marker appears \(occurrences) times: a duplicate Hello replayed the session")
                #expect(afterSecond.count >= afterFirst.count, "bytes went backwards")
            }
        }

        // MARK: - Case 7: an Ack the client never earned

        /// A forged `Ack` claiming an offset far beyond anything the client received.
        ///
        /// WHAT THIS TEST DOES AND DOES NOT PROVE — stated because the first version of
        /// it proved nothing and passed anyway.
        ///
        /// The case was written expecting a forged ack to be able to move a later
        /// replay point. It cannot, and the reason is structural rather than defensive:
        /// `ackedOffset` lives on the *attachment*, not the session, and is
        /// re-initialised from `hello.resumeFrom` on every attach — so an ack sent down
        /// one connection is not reachable from the next. Better still, a search for
        /// its readers turns up exactly one, a diagnostics accessor. **Nothing in the
        /// daemon consults an ack when deciding what to replay.** Resume is driven
        /// entirely by the offset the client states in `Hello`.
        ///
        /// That was confirmed by mutation rather than by reading: wiring resume to
        /// `max(hello.resumeFrom, ackedOffset)` left this test green, because there is
        /// no path by which the forged value survives to the next attach.
        ///
        /// So this asserts the property that actually protects the client, and that a
        /// mutation *can* break: **the replay point is exactly what the client asked
        /// for**, byte for byte, whatever it may have claimed earlier. Making resume
        /// ignore the stated offset, or shift it by one, both turn this red.
        ///
        /// The corollary is worth writing down: the ack frame is currently inert on the
        /// daemon side. That is not a defect — the client's own offset being the single
        /// source of truth is exactly what makes resume robust against a lying or buggy
        /// peer — but §6.2 reads as though the daemon uses acks, and it does not.
        @Test("The replay point is the offset the client states, not anything it acked")
        func forgedAckDoesNotSkipBytes() async throws {
            try await withHarness { daemon in
                let first = try daemon.bootstrap(session: "forged")
                let sink = Sink()
                let connection = MeshyyConnection(bootstrap: first, sshHost: "127.0.0.1")
                connection.onFrame = { sink.append($0) }
                try await connection.connect()
                try connection.send(.hello(.init(
                    token: first.token, cols: 80, rows: 24, session: nil
                )))
                #expect(await sink.wait { sink.welcomes >= 1 })

                let before = Array("earned-bytes-before\n".utf8)
                try connection.sendKeystrokes(before)
                #expect(await sink.wait { sink.ptyBytes.contains(before) })
                let honestOffset = UInt64(sink.ptyBytes.count)

                // The lie: an offset far past anything that exists.
                try connection.send(.ack(ptyID: 0, offset: honestOffset + 1_000_000))
                try await Task.sleep(for: .milliseconds(200))

                let after = Array("earned-bytes-after\n".utf8)
                try connection.sendKeystrokes(after)
                #expect(await sink.wait { sink.ptyBytes.contains(after) })
                let truth = sink.ptyBytes
                connection.close()

                // Reconnect honestly, from what was really consumed, and require the
                // rest of the stream verbatim. If the forged ack had reached the resume
                // path, the bytes between `honestOffset` and the lie would be gone.
                var second = try daemon.bootstrap(session: "forged")
                second.port = first.port
                let resumed = Sink()
                let reconnection = MeshyyConnection(bootstrap: second, sshHost: "127.0.0.1")
                reconnection.onFrame = { resumed.append($0) }
                try await reconnection.connect()
                defer { reconnection.close() }
                try reconnection.send(.hello(.init(
                    token: second.token, cols: 80, rows: 24, resumeFrom: honestOffset, session: nil
                )))

                #expect(await resumed.wait { resumed.welcomes >= 1 }, "no Welcome on the honest resume")
                let expectedTail = Array(truth.dropFirst(Int(honestOffset)))
                #expect(await resumed.wait { resumed.ptyBytes.count >= expectedTail.count },
                        "the resume delivered \(resumed.ptyBytes.count) of \(expectedTail.count) bytes — a forged Ack skipped what the client never actually received")
                #expect(Array(resumed.ptyBytes.prefix(expectedTail.count)) == expectedTail,
                        "the resumed tail does not match: the forged Ack moved the replay point")
            }
        }

        // MARK: - Case 6, over QUIC

        /// Two live QUIC connections attached to one session at the same time.
        ///
        /// Partially covered already — `Two clients on the same session both see live
        /// output` asserts this over the unix socket. It is worth asserting over QUIC
        /// too, because the two transports reach `SessionStore` by different paths and
        /// only one of them was tested. Sharing is the intended behaviour (a phone and
        /// a laptop on one session), so the assertion is that both see the stream, not
        /// that the second is refused.
        @Test("Two QUIC connections on one session both see live output")
        func concurrentQUICAttachesShareTheStream() async throws {
            try await withHarness { daemon in
                let firstBootstrap = try daemon.bootstrap(session: "shared")
                let secondBootstrap = try daemon.bootstrap(session: "shared")
                #expect(firstBootstrap.sessionID == secondBootstrap.sessionID,
                        "the two bootstraps did not name one session, so this proves nothing")

                let sinkA = Sink()
                let a = MeshyyConnection(bootstrap: firstBootstrap, sshHost: "127.0.0.1")
                a.onFrame = { sinkA.append($0) }
                try await a.connect()
                defer { a.close() }
                try a.send(.hello(.init(
                    token: firstBootstrap.token, cols: 80, rows: 24, session: nil
                )))
                #expect(await sinkA.wait { sinkA.welcomes >= 1 })

                let sinkB = Sink()
                let b = MeshyyConnection(bootstrap: secondBootstrap, sshHost: "127.0.0.1")
                b.onFrame = { sinkB.append($0) }
                try await b.connect()
                defer { b.close() }
                try b.send(.hello(.init(
                    token: secondBootstrap.token, cols: 80, rows: 24, session: nil
                )))
                #expect(await sinkB.wait { sinkB.welcomes >= 1 },
                        "the second connection never attached to the shared session")

                // Typed on one, seen on both.
                let marker = Array("shared-across-two-quic-clients\n".utf8)
                try a.sendKeystrokes(marker)
                #expect(await sinkA.wait { sinkA.ptyBytes.contains(marker) },
                        "the sender did not see its own echo")
                #expect(await sinkB.wait { sinkB.ptyBytes.contains(marker) },
                        "the second client did not see output typed on the first")
            }
        }
    }
}

private extension Array where Element == UInt8 {
    /// Non-overlapping occurrences of `pattern`. Written out because a replay shows up
    /// as a repeat count, and `contains` cannot tell one from two.
    func ranges(of pattern: [UInt8]) -> [Range<Int>] {
        guard !pattern.isEmpty, count >= pattern.count else { return [] }
        var found: [Range<Int>] = []
        var index = 0
        while index <= count - pattern.count {
            if Array(self[index..<index + pattern.count]) == pattern {
                found.append(index..<index + pattern.count)
                index += pattern.count
            } else {
                index += 1
            }
        }
        return found
    }
}
