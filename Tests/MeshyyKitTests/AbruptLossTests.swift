// meshyy — resume across an UNGRACEFUL disconnect (hardening 1h).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Every other disconnect in this suite is graceful: `close()` or `detach()`, which
// emit CONNECTION_CLOSE or a FIN with nothing in flight. **No user has ever hit a
// graceful close.** iOS suspension means packets simply stop, mid-frame, and
// whatever was on the wire is lost.
//
// THE ASYMMETRY THAT MAKES THIS DANGEROUS. Duplicate replay is visible and
// recoverable — the user sees a repeated line. A gap is silent, and gets blamed on
// the shell or the agent. So the assertion here is stronger than stream equality
// alone. The amendment states it directionally —
//
//     under truncation at any point, the client must never resume from an offset
//     past what it has actually delivered to the renderer
//
// — and the first draft of this file asserted exactly that, `offset <= delivered`.
// It was wrong in one direction and too weak in the other. There IS a licensed way
// to skip bytes: when the ring buffer has evicted what the client still needed, the
// daemon states a higher replay base and the client emits `screenRebuilt` with the
// range. Those bytes are gone, but the user is TOLD. So the real invariant is an
// equality over an account that has to balance:
//
//     consumedOffset == bytes delivered to the renderer + bytes reported as skipped
//
// Every byte the client passes over is either drawn or announced. Nothing is passed
// over quietly. This catches the advance-on-send bug the inequality was aimed at
// (offset reads high), and also catches double-counting and lost acknowledgement
// (offset reads low), which the inequality would have waved through.
//
// The ack cadence is where this lives. At most one ack per 250 ms means there is
// always a window of delivered-but-unacked bytes, and death inside that window is
// the common case rather than the edge case. A client that advanced its pointer on
// *send* rather than on *delivery* would drop bytes on every abrupt disconnect, and
// every graceful test would still pass.
//
// SWEEP, DO NOT SAMPLE. Off-by-ones live at specific boundaries — frame headers,
// ring-buffer wrap, replay chunk edges — and random sampling walks past them. These
// kill at *every* byte offset across the window.

import Foundation
import MeshyyCore
import MeshyyTestSupport
import Testing
@testable import MeshyyKit

/// A daemon whose output is captured as the wire bytes a client would receive, so a
/// test can truncate it anywhere — including inside a frame header.
private struct WireRecorder {
    private(set) var bytes: [UInt8] = []

    mutating func send(_ envelope: FrameEnvelope) {
        bytes += envelope.encoded
    }

    /// Byte length of the replay-base frame, so a caller can say whether a given
    /// truncation delivered the base whole or cut it in half. That is a fact about
    /// the wire, established by the same encoder the daemon uses — deriving it from
    /// the client's resulting offset instead would be circular, since the offset is
    /// the thing under test.
    private(set) var replayBaseFrameLength = 0

    /// What `SessionAttachment` sends on attach: the replay base, then the replayed
    /// bytes. Derived from the daemon's own decision so the harness cannot drift
    /// into testing a fiction of the protocol.
    mutating func attach(_ decision: ResumeDecision) {
        let base = FrameEnvelope.control(.replayBase(ptyID: 0, offset: decision.replayBase))
        replayBaseFrameLength = base.encoded.count
        bytes += base.encoded
        if !decision.bytes.isEmpty { send(.pty(0, decision.bytes)) }
    }

    mutating func output(_ payload: [UInt8]) {
        send(.pty(0, payload))
    }
}

/// Feeds a truncated wire stream to the shipping client and reports what it did.
private struct TruncatedDelivery {
    /// Bytes the client actually handed to the renderer.
    var delivered: [UInt8] = []
    /// Bytes of the wire stream that were decodable as complete frames.
    var consumedWireBytes = 0

    /// Delivers the first `limit` bytes of `wire`, then stops dead.
    ///
    /// A partial trailing frame is left undecoded, which is exactly what a real peer
    /// holds in its parse buffer when the connection dies mid-frame.
    static func deliver(
        wire: [UInt8],
        limit: Int,
        to session: MeshyySession
    ) async -> TruncatedDelivery {
        var result = TruncatedDelivery()
        var decoder = FrameDecoder()
        let truncated = Array(wire.prefix(limit))
        result.consumedWireBytes = truncated.count

        // Byte at a time, so a frame straddling the kill point is genuinely partial
        // rather than conveniently whole.
        for byte in truncated {
            guard let frames = try? decoder.push([byte]) else { break }
            for frame in frames {
                result.delivered += await session.handle(frame)
            }
        }
        return result
    }
}

extension MeshyyKitSuite {
    @Suite("Abrupt loss (1h)")
    struct AbruptLossTests {

        /// Builds a session that has already attached fresh and consumed `history`.
        private static func primed(history: [UInt8]) async -> (MeshyySession, [UInt8]) {
            let session = MeshyySession()
            await session.resetForAttach(resumeFrom: nil)
            var delivered: [UInt8] = []
            delivered += await session.handle(.control(.replayBase(ptyID: 0, offset: 0)))
            if !history.isEmpty {
                delivered += await session.handle(.pty(0, history))
            }
            return (session, delivered)
        }

        // MARK: - The exhaustive sweep

        /// Kill at EVERY byte offset of a live burst, and check both properties at
        /// each one.
        ///
        /// The scenario is fixed rather than seeded because the point is exhaustive
        /// coverage of *offsets*, not of scenarios — the seeded corpus covers those.
        @Test("Truncating at every byte offset never loses a byte")
        func sweepEveryKillOffset() async {
            let history = Array("session already in progress\r\n".utf8)
            var daemon = SessionBuffer(capacity: 64 * 1024)
            daemon.write(history)

            // A burst the client is mid-way through receiving when the link dies.
            let burst = (0..<600).map { UInt8(32 + ($0 * 7) % 95) }
            daemon.write(burst)

            var wire = WireRecorder()
            wire.output(burst)

            for killOffset in 0...wire.bytes.count {
                let (session, alreadyDelivered) = await Self.primed(history: history)
                let run = await TruncatedDelivery.deliver(
                    wire: wire.bytes, limit: killOffset, to: session
                )
                let deliveredSoFar = alreadyDelivered + run.delivered

                // THE ACCOUNTING ASSERTION (see the header). Nothing was evicted here,
                // so there is no licensed skip and the offset must equal the delivered
                // count exactly. A client that advanced on send would read high.
                let offset = await session.consumedOffset
                #expect(offset == UInt64(deliveredSoFar.count),
                        "kill at \(killOffset): resumed from \(offset) having delivered \(deliveredSoFar.count) bytes — the difference is a silent gap")

                // And the reconnect must close the gap exactly. The SAME session: an
                // abrupt disconnect kills the connection, not the client's place in the
                // stream. Rebuilding it here would fake a resume from zero and hide
                // exactly the arithmetic under test.
                let decision = daemon.resume(from: offset)
                await session.resetForAttach(resumeFrom: nil)
                var replayed: [UInt8] = []
                replayed += await session.handle(
                    .control(.replayBase(ptyID: 0, offset: decision.replayBase))
                )
                replayed += await session.handle(.pty(0, decision.bytes))

                #expect(deliveredSoFar + replayed == history + burst,
                        "kill at \(killOffset): stream not exact across the seam (\(deliveredSoFar.count) + \(replayed.count) vs \(history.count + burst.count))")
            }
        }

        /// The same sweep across the *replay* itself: the link dies while the client
        /// is still catching up from a previous disconnect.
        @Test("Truncating mid-replay never loses a byte")
        func sweepKillDuringReplay() async {
            let history = Array("before the first drop\r\n".utf8)
            var daemon = SessionBuffer(capacity: 64 * 1024)
            daemon.write(history)
            let away = (0..<500).map { UInt8(32 + ($0 * 11) % 95) }
            daemon.write(away)

            // The client saw `history`, then dropped. This is the replay it gets back.
            let decision = daemon.resume(from: UInt64(history.count))
            var wire = WireRecorder()
            wire.attach(decision)

            for killOffset in 0...wire.bytes.count {
                // A client that genuinely lived through the first drop, rather than a
                // fresh one pretending to have. Its offset survived; only the socket
                // died.
                let (session, primed) = await Self.primed(history: history)
                await session.resetForAttach(resumeFrom: nil)
                let run = await TruncatedDelivery.deliver(
                    wire: wire.bytes, limit: killOffset, to: session
                )
                let deliveredSoFar = primed + run.delivered

                let offset = await session.consumedOffset
                #expect(offset == UInt64(deliveredSoFar.count),
                        "kill at \(killOffset) during replay: resumed from \(offset), delivered \(deliveredSoFar.count)")

                let second = daemon.resume(from: offset)
                await session.resetForAttach(resumeFrom: nil)
                var replayed: [UInt8] = []
                replayed += await session.handle(
                    .control(.replayBase(ptyID: 0, offset: second.replayBase))
                )
                replayed += await session.handle(.pty(0, second.bytes))

                #expect(deliveredSoFar + replayed == history + away,
                        "kill at \(killOffset) during replay: stream not exact")
            }
        }

        /// Killing before `Welcome` — that is, before the client has been told
        /// anything at all — must leave it exactly where it started.
        @Test("Killing during the resume handshake, before any base, delivers nothing")
        func killBeforeReplayBase() async {
            var daemon = SessionBuffer(capacity: 1024)
            let history = Array("state".utf8)
            daemon.write(history)

            var wire = WireRecorder()
            wire.send(.control(.welcome(.init(sessionID: "s", bufferedFrom: 0, bufferedTo: 5))))
            wire.attach(daemon.resume(from: UInt64(history.count)))

            // Every offset that lands before the replayBase frame is complete.
            let welcomeLength = FrameEnvelope.control(
                .welcome(.init(sessionID: "s", bufferedFrom: 0, bufferedTo: 5))
            ).encoded.count

            for killOffset in 0...welcomeLength {
                let session = MeshyySession()
                await session.resetForAttach(resumeFrom: nil)
                let run = await TruncatedDelivery.deliver(
                    wire: wire.bytes, limit: killOffset, to: session
                )
                #expect(run.delivered.isEmpty,
                        "kill at \(killOffset): delivered bytes before a replay base existed")
                #expect(await session.consumedOffset == 0,
                        "kill at \(killOffset): advanced its offset without being told a base")
            }
        }

        // MARK: - Frames arriving in an adverse order around the attach
        //
        // Both tests below exist because the mutation battery for this PR found the
        // queue path uncovered — see docs/qa/mutation-log.md. `pty` and `control` ride
        // SEPARATE QUIC streams, and QUIC orders bytes *within* a stream only, so pty
        // bytes genuinely can land before the replay base that gives them a position.
        // The queue is the code that handles it, and nothing was testing the queue.

        /// PTY bytes that arrive before the base are held, then flushed — not dropped.
        ///
        /// Kills the mutant that empties the queue at flush time. That defect loses the
        /// first burst of every reconnect where the streams land out of order, which is
        /// a race: rare, load-dependent, and indistinguishable from the shell having
        /// said nothing.
        @Test("PTY bytes arriving before the replay base are queued, then delivered")
        func ptyBeforeBaseIsQueuedNotLost() async {
            let early = Array("printed before the base arrived\r\n".utf8)
            let session = MeshyySession()
            await session.resetForAttach(resumeFrom: nil)

            // Out of order on purpose: the payload, then its position.
            let heldBack = await session.handle(.pty(0, early))
            #expect(heldBack.isEmpty, "bytes with no known position must not be drawn yet")
            #expect(await session.consumedOffset == 0,
                    "and must not be counted yet either — that would be counting on receipt")

            let flushed = await session.handle(.control(.replayBase(ptyID: 0, offset: 100)))
            #expect(flushed == early, "the queued bytes must arrive intact once the base does")
            #expect(await session.consumedOffset == 100 + UInt64(early.count),
                    "and land at base + their own length")
        }

        /// A queue that outlives its connection is a duplicate waiting to happen.
        ///
        /// If the link dies after pty bytes are queued but before the base arrives, the
        /// daemon will replay those same bytes on the next attach — it never saw an ack
        /// for them. Holding the stale queue across the reattach therefore delivers them
        /// twice. The reset must drop them.
        @Test("A queue orphaned by an abrupt disconnect does not survive the reattach")
        func staleQueueDoesNotSurviveReattach() async {
            let orphaned = Array("queued, then the link died\r\n".utf8)
            let session = MeshyySession()
            await session.resetForAttach(resumeFrom: nil)
            _ = await session.handle(.pty(0, orphaned))  // queued; base never came

            // Reattach. The daemon replays from 0, including the orphaned bytes.
            await session.resetForAttach(resumeFrom: nil)
            var delivered: [UInt8] = []
            delivered += await session.handle(.control(.replayBase(ptyID: 0, offset: 0)))
            delivered += await session.handle(.pty(0, orphaned))

            #expect(delivered == orphaned,
                    "the orphaned queue was flushed as well, so the user saw the line twice")
            #expect(await session.consumedOffset == UInt64(orphaned.count))
        }

        // MARK: - Named cases from the amendment

        /// A control frame cut in half must not be acted on, and must not poison the
        /// next connection — which gets a fresh decoder, so the partial frame dies
        /// with the connection that held it.
        @Test("A partial control frame is never acted on, and does not survive the reconnect")
        func partialControlFrameIsDiscarded() async {
            // A resize is a good probe: acting on half of one would be visible.
            let frame = FrameEnvelope.control(.resize(cols: 200, rows: 60)).encoded
            #expect(frame.count > 4)

            for truncateAt in 1..<frame.count {
                var decoder = FrameDecoder()
                let frames = (try? decoder.push(Array(frame.prefix(truncateAt)))) ?? []
                #expect(frames.isEmpty,
                        "a control frame truncated at \(truncateAt) of \(frame.count) decoded as if whole")
                #expect(decoder.bufferedByteCount == truncateAt,
                        "the partial frame must be held, not dropped or mis-parsed")
            }

            // The reconnect uses a NEW decoder. If a transport ever reused one across
            // connections, the leftover prefix would corrupt the first real frame.
            var fresh = FrameDecoder()
            let complete = (try? fresh.push(frame)) ?? []
            #expect(complete.count == 1, "a fresh decoder must parse the whole frame")
        }

        /// An `Ack` that never reached the daemon changes nothing, because resume is
        /// driven by the client's own offset. Asserted rather than assumed: if the
        /// daemon ever started resuming from *its* record of the ack, an ack lost in
        /// flight would silently skip bytes.
        @Test("An Ack lost in flight does not cost the client any bytes")
        func ackLostInFlight() async {
            var daemon = SessionBuffer(capacity: 64 * 1024)
            let first = Array("first chunk\r\n".utf8)
            daemon.write(first)

            let (session, delivered) = await Self.primed(history: first)
            // The client acks — and the ack is dropped on the floor. The daemon never
            // sees it, so its record stays at zero.
            let clientOffset = await session.consumedOffset
            #expect(clientOffset == UInt64(delivered.count))

            let away = Array("while away\r\n".utf8)
            daemon.write(away)

            // Resume is driven by the client's offset, not the daemon's record.
            let decision = daemon.resume(from: clientOffset)
            #expect(decision.bytes == away,
                    "a lost ack must not change what is replayed")
        }

        /// A resize in flight when the link dies is simply lost, and the client
        /// re-states its geometry on the next `Hello`. Asserted so nobody later
        /// "fixes" this by queueing resizes across connections.
        @Test("A resize lost in flight is re-stated by the next attach, not replayed")
        func resizeLostInFlight() async {
            let resize = FrameEnvelope.control(.resize(cols: 133, rows: 47)).encoded
            var decoder = FrameDecoder()
            // Dies halfway through the resize.
            let partial = (try? decoder.push(Array(resize.prefix(resize.count / 2)))) ?? []
            #expect(partial.isEmpty, "half a resize must not resize anything")

            // The next attach carries the geometry in Hello, which is what makes the
            // lost frame harmless.
            let hello = ControlFrame.hello(.init(token: "t", cols: 133, rows: 47))
            guard case .hello(let decoded) = try! ControlFrame.decode(hello.encoded) else {
                Issue.record("hello did not round-trip")
                return
            }
            #expect(decoded.cols == 133 && decoded.rows == 47,
                    "Hello must carry geometry, or a lost resize would persist")
        }

        /// The corpus, re-scored against abrupt disconnects rather than graceful ones.
        ///
        /// The amendment asks for this explicitly: 1b-bis's mutation score was earned
        /// entirely on the easy path. Here every reconnect is preceded by a truncation
        /// at a seed-derived offset, so the client resumes from wherever it genuinely
        /// got to rather than from a clean boundary.
        @Test("The seeded corpus survives abrupt truncation at every reconnect",
              arguments: 1...200)
        func corpusUnderAbruptLoss(seed: UInt64) async {
            let scenario = ResumeScenario(seed: seed)
            var random = SplitMix64(seed: seed &* 2_654_435_761)
            var daemon = SessionBuffer(capacity: scenario.bufferCapacity)
            var pty: [UInt8] = []

            let session = MeshyySession()
            await session.resetForAttach(resumeFrom: nil)
            var delivered: [UInt8] = []
            delivered += await session.handle(.control(.replayBase(ptyID: 0, offset: 0)))
            var connected = true
            // Bytes the daemon evicted and told the client about. See the reconnect
            // case below.
            var skipped: UInt64 = 0

            for step in scenario.steps {
                switch step {
                case .output(let bytes):
                    pty += bytes
                    daemon.write(bytes)
                    if connected { delivered += await session.handle(.pty(0, bytes)) }

                case .clearScreen:
                    let bytes = ResumeScenario.clearScreenBytes
                    pty += bytes
                    daemon.write(bytes)
                    if connected { delivered += await session.handle(.pty(0, bytes)) }

                case .disconnect:
                    connected = false

                case .reconnect:
                    let before = await session.consumedOffset
                    let decision = daemon.resume(from: before)
                    var wire = WireRecorder()
                    wire.attach(decision)
                    // ABRUPT: cut the replay at an arbitrary point rather than
                    // delivering it whole.
                    let limit = wire.bytes.isEmpty
                        ? 0
                        : Int.random(in: 0...wire.bytes.count, using: &random)
                    await session.resetForAttach(resumeFrom: nil)
                    let run = await TruncatedDelivery.deliver(
                        wire: wire.bytes, limit: limit, to: session
                    )
                    delivered += run.delivered

                    // A forward jump means the ring buffer evicted what this client
                    // still needed. Those bytes are gone, but they are *announced* —
                    // `screenRebuilt` carries the range — so they are a reported hole,
                    // not a silent one, and the account must allow for them.
                    //
                    // Only credit the skip if the base frame survived the truncation.
                    // A client killed mid-base never learned of the jump, so it is
                    // still sitting on its old offset and has skipped nothing; the
                    // next attach re-states the base and the credit lands then.
                    if limit >= wire.replayBaseFrameLength, decision.replayBase > before {
                        skipped += decision.replayBase - before
                    }

                    let offset = await session.consumedOffset
                    #expect(offset == UInt64(delivered.count) + skipped,
                            "seed \(seed): offset \(offset) but delivered \(delivered.count) + reported skips \(skipped)")
                    connected = true
                }
            }

            // Final clean reconnect, so the closing assertion is about the whole stream.
            let final = daemon.resume(from: await session.consumedOffset)
            await session.resetForAttach(resumeFrom: nil)
            delivered += await session.handle(
                .control(.replayBase(ptyID: 0, offset: final.replayBase))
            )
            delivered += await session.handle(.pty(0, final.bytes))

            // Only assert exactness when nothing was evicted; an overrun is a reported
            // hole, which the §6.4 test already covers.
            if daemon.window.from == 0 {
                #expect(delivered == pty,
                        "seed \(seed): expected \(pty.count) bytes, delivered \(delivered.count)")
            } else {
                #expect(delivered.count <= pty.count)
                #expect(Array(delivered.suffix(64)) == Array(pty.suffix(64))
                            || delivered.count < pty.count,
                        "seed \(seed): tail diverged after eviction")
            }
        }
    }
}
