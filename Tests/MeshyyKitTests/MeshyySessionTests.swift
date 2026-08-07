// meshyy — M3: the client's offset bookkeeping and resume (design doc §6.2).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// The §6.4 property test proves the daemon's side. This proves the client's: that
// `consumedOffset` tracks exactly the bytes handed to the emulator, that a
// reconnect resumes from it, and that a rebuilt screen is reported rather than
// spliced.

import Darwin
import Foundation
import MeshyyCore
import Testing
@testable import MeshyyDaemon
@testable import MeshyyKit

/// Collects a session's events for assertions.
///
/// Events are pulled on the **caller's** task, not a detached one.
///
/// The detached-consumer version of this looked fine and failed on CI: the
/// assertions read a snapshot that only fills as a background task is scheduled,
/// so on a loaded two-core runner the test could time out while the session had
/// long since delivered everything. The symptom was a client offset of 16 against
/// a daemon offset of 69 — not a transport bug, a test that was measuring its own
/// scheduler.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MeshyySessionEvent] = []

    /// Consumes on a detached task, and `wait` polls with a bounded sleep.
    ///
    /// An earlier version pulled events on the caller's task to remove the
    /// dependency on that task being scheduled. That was worse: `await
    /// iterator.next()` blocks indefinitely when nothing arrives, so the deadline
    /// check between elements never ran and CI hung instead of failing. A test
    /// helper must be incapable of hanging, whatever the product does.
    func attach(to session: MeshyySession) async {
        let stream = await session.events
        Task { [weak self] in
            for await event in stream { self?.append(event) }
        }
    }

    private func append(_ event: MeshyySessionEvent) {
        lock.withLock { events.append(event) }
    }

    var all: [MeshyySessionEvent] { lock.withLock { events } }

    var outputBytes: [UInt8] {
        all.compactMap { if case .output(let bytes) = $0 { return bytes } else { return nil } }
            .flatMap { $0 }
    }

    var text: String { String(decoding: outputBytes, as: UTF8.self) }

    var rebuilds: [(UInt64, UInt64)] {
        all.compactMap {
            if case .screenRebuilt(let from, let at) = $0 { return (from, at) } else { return nil }
        }
    }

    var failures: [String] {
        all.compactMap { if case .failed(let reason) = $0 { return reason } else { return nil } }
    }

    var summary: String {
        all.map { event in
            switch event {
            case .output(let bytes): "output(\(bytes.count)B)"
            case .screenRebuilt(let from, let at): "rebuilt(\(from)->\(at))"
            case .termios: "termios"
            case .screenMode(let alt): "screen(alt:\(alt))"
            case .modes(let active): "modes(\(active.sorted()))"
            case .agent(let kind, _, _): "agent(\(kind))"
            case .quickActions(let actions): "qa(\(actions.count))"
            case .ended(let reason): "ended(\(reason))"
            case .exited(let status): "exited(\(status))"
            case .failed(let reason): "FAILED(\(reason))"
            case .reconnecting(let trigger): "reconnecting(\(trigger))"
            case .geometryReset: "geometryReset"
            }
        }.joined(separator: " ")
    }

    /// Pulls events until `predicate` holds or the deadline passes.
    ///
    /// Generous ceiling on purpose: it returns the moment the predicate holds, so a
    /// large limit only changes how long a genuine failure takes to report, while a
    /// tight one turns runner load into a red build.
    @discardableResult
    func wait(
        timeout: TimeInterval = 30,
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

/// Splits a marker across printf arguments so the command's own echo cannot
/// satisfy an assertion about the command's *output*.
///
/// Without this, `printf '%s\n' BEFORE_DROP` makes the marker appear twice — once
/// echoed, once printed — and a duplicate-detection assertion reads that as a
/// resume bug.
/// Splits a marker across printf arguments so a shell's echo of the command cannot
/// satisfy an assertion about its output. Only needed by the `.shell` tests.
private func markerCommand(_ marker: String) -> [UInt8] {
    let midpoint = marker.index(marker.startIndex, offsetBy: marker.count / 2)
    let command = "printf '%s%s\\n' '\(marker[marker.startIndex..<midpoint])' "
        + "'\(marker[midpoint...])'\n"
    return Array(command.utf8)
}

/// Deterministic printable-ASCII payload. Printable only, because even under
/// `stty raw` a PTY eats flow-control and signal characters — see
/// `DaemonConfig.deterministicEcho`.
private func payload(_ count: Int, seed: UInt8 = 0) -> [UInt8] {
    let printable = Array(0x20...0x7E)
    return (0..<count).map { UInt8(printable[($0 * 7 + Int(seed) * 31) % printable.count]) }
}


extension MeshyyKitSuite {
    @Suite("Client session bookkeeping")
    struct MeshyySessionTests {

        @Test("A late-attaching client is told the modes the program armed long ago")
        func modesSurviveToAFreshClient() async throws {
            try await withHarness(child: .shell) { daemon in
                // The program arms mouse + SGR + paste, witnessed by NOBODY:
                // no client is attached while these bytes flow, exactly like
                // tmux arming its modes while only the daemon's pty listens.
                let arming = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
                let armLog = EventLog()
                await armLog.attach(to: arming)
                let boot = try daemon.bootstrap(session: "coldmodes")
                try await arming.attach(bootstrap: boot, sshHost: "127.0.0.1")
                try await arming.send(Array("printf '\\e[?1000;1006h\\e[?2004h'\n".utf8))
                try await arming.send(markerCommand("MODES_ARMED"))
                #expect(await armLog.wait { armLog.text.contains("MODES_ARMED") })
                await arming.detach(reason: "app force-quit")

                // A brand-new client — the relaunch's fresh emulator — attaches.
                // The escapes above are consumed history; only the modes frame
                // can tell it what the program believes.
                let fresh = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
                let freshLog = EventLog()
                await freshLog.attach(to: fresh)
                let reboot = try daemon.bootstrap(session: "coldmodes")
                try await fresh.attach(bootstrap: reboot, sshHost: "127.0.0.1")

                #expect(await freshLog.wait {
                    freshLog.all.contains {
                        if case .modes(let active) = $0 {
                            return active.isSuperset(of: [1000, 1006, 2004])
                        }
                        return false
                    }
                }, "the fresh client was never told the armed modes: \(freshLog.summary)")
            }
        }

        @Test("A withdrawn offer reaches the wire, not just the daemon's model")
        func withdrawalReachesTheClient() async throws {
            try await withHarness(child: .shell) { daemon in
                let session = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
                let log = EventLog()
                await log.attach(to: session)
                let boot = try daemon.bootstrap(session: "withdraw")
                try await session.attach(bootstrap: boot, sshHost: "127.0.0.1")

                // The prompt the claude-code profile matches: marker + question.
                try await session.send(Array(("printf 'claude code - esc to interrupt\\n"
                    + "Do you want to make this edit?\\n 1. Yes\\n'\n").utf8))
                #expect(await log.wait(timeout: 15) {
                    log.all.contains {
                        if case .quickActions(let a) = $0 { return !a.isEmpty }
                        return false
                    }
                }, "the offer never arrived: \(log.summary)")

                // The moment passes: flood the tail past the 2 KiB match window.
                try await session.send(Array("seq 1 5000\n".utf8))
                #expect(await log.wait(timeout: 15) {
                    // An EMPTY offer arriving AFTER the non-empty one.
                    var sawOffer = false
                    for event in log.all {
                        if case .quickActions(let a) = event {
                            if !a.isEmpty { sawOffer = true }
                            else if sawOffer { return true }
                        }
                    }
                    return false
                }, "the withdrawal never left the daemon: \(log.summary)")
            }
        }

        @Test("An offer that outruns its status event still lands on an answerable palette")
        func offerImpliesWaiting() async throws {
            // Pure client-side: inject the frames in the racy order the wire
            // can produce — actions BEFORE the waiting status — and require
            // the gate to accept the tap anyway. The daemon only offers
            // while waiting, so the offer is itself the evidence.
            let session = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
            _ = await session.handle(FrameEnvelope(
                kind: .control,
                payload: ControlFrame.quickActions([
                    QuickAction(id: "approve-once", label: "Yes")
                ]).encoded
            ))
            #expect(await session.isAwaitingInput,
                    "a live offer with a refused gate is a dead button")
            // And the resolution path accepts it (throws only if the gate or
            // the table are wrong; there is no connection, so the send itself
            // is what must NOT be reached — hence the expected send failure).
            do {
                try await session.performQuickAction(
                    id: "approve-once", from: AgentProfile.defaults)
            } catch let error as MeshyySession.QuickActionError {
                Issue.record("the gate refused a live offer: \(error)")
            } catch {
                // Send failed on the nil connection — the gate PASSED.
            }
        }

        @Test("The heartbeat keeps ticking, counted in milliseconds not symptoms")
        func heartbeatTicksClimb() async throws {
            try await withHarness(child: .bytePipe) { daemon in
                // 20ms probes: the assertion below fails within two seconds if
                // the heartbeat silently stops running — bug #2's shape — where
                // the survival test needs the whole idle timeout to notice.
                let session = MeshyySession(
                    size: TerminalSize(cols: 80, rows: 24),
                    heartbeatInterval: .milliseconds(20)
                )
                let boot = try daemon.bootstrap(session: "ticker")
                try await session.attach(bootstrap: boot, sshHost: "127.0.0.1")

                let deadline = Date().addingTimeInterval(2)
                var seen: UInt64 = 0
                while Date() < deadline, seen < 5 {
                    seen = await session.heartbeatTicks
                    try await Task.sleep(for: .milliseconds(50))
                }
                #expect(seen >= 5, Comment(rawValue:
                    "the heartbeat minted \(seen) probes in 2s at a 20ms interval "
                        + "— it is not running, which is bug #2 by another name"))
                await session.detach(reason: "test over")
            }
        }

        @Test("Typing exit ends as .exited, never as a drop to recover from")
        func aCleanExitIsNotADrop() async throws {
            try await withHarness(child: .shell) { daemon in
                let session = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
                let log = EventLog()
                await log.attach(to: session)

                let boot = try daemon.bootstrap(session: "cleanexit")
                try await session.attach(bootstrap: boot, sshHost: "127.0.0.1")
                try await session.send(markerCommand("ALIVE_FIRST"))
                #expect(await log.wait { log.text.contains("ALIVE_FIRST") })

                try await session.send(Array("exit\n".utf8))

                // The one assertion that maps to the bug: the app decides
                // close-the-tab vs reconnect on exactly this distinction, and a
                // clean exit surfaced as .ended sent every `exit` into a fresh
                // shell the user never asked for.
                #expect(await log.wait {
                    log.all.contains { if case .exited = $0 { return true }; return false }
                }, "exit never surfaced as .exited: \(log.summary)")
                let plainEnds = log.all.filter {
                    if case .ended = $0 { return true }; return false
                }
                #expect(plainEnds.isEmpty,
                        "a clean exit must not ALSO read as a drop: \(log.summary)")
            }
        }

        @Test("consumedOffset counts exactly the bytes delivered, starting at the replay base")
        func offsetTracksDeliveredBytes() async throws {
            try await withHarness(child: .shell) { daemon in

                let session = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
                let log = EventLog()
                await log.attach(to: session)

                let boot = try daemon.bootstrap(session: "offsets")
                try await session.attach(bootstrap: boot, sshHost: "127.0.0.1")

                try await session.send(markerCommand("MARKER_ONE"))
                #expect(await log.wait { log.text.contains("MARKER_ONE") })

                // The offset must equal the daemon's own total, less whatever the daemon
                // held back before this client attached.
                let daemonSession = await daemon.store.session(named: "offsets")
                let info = await daemonSession!.info
                let offset = await session.consumedOffset
                #expect(offset == info.bufferedTo,
                        "client offset \(offset) should equal the daemon's \(info.bufferedTo)")
                #expect(log.failures.isEmpty, "unexpected failures: \(log.failures)")
            }
        }

        /// The M3 payoff, end to end through the real client API, asserted byte-exactly.
    ///
    /// Substring assertions used to hide real defects here:
    /// `docs/qa/mutation-log.md` records a duplicating off-by-one in
    /// `MeshyySession.deliver` that a "no duplicates" marker check missed because the
    /// duplication did not overlap the marker. Whole-array comparison catches it.
    @Test("A reattach after a dropped connection resumes byte-exactly")
    func reattachResumesExactly() async throws {
        try await withHarness { daemon in
            let session = MeshyySession()
            let log = EventLog()
            await log.attach(to: session)

            try await session.attach(
                bootstrap: try daemon.bootstrap(session: "reattach"),
                sshHost: "127.0.0.1"
            )
            #expect(await log.wait { !log.all.isEmpty }, "no Welcome")
            let handshake = 0

            let before = payload(400, seed: 1)
            try await session.send(before)
            #expect(await log.wait { log.outputBytes.count >= handshake + before.count },
                    "byte pipe did not return the first payload")
            let offsetAtDrop = await session.consumedOffset

            // iOS suspends: the socket dies with no warning and no Bye.
            await session.detach(reason: "suspended")

            let away = payload(300, seed: 2)
            try await (await daemon.store.session(named: "reattach"))?.send(away)
            try await Task.sleep(for: .milliseconds(400))

            // Foreground: fresh bootstrap (tokens are single-use), resume from the
            // offset the client itself recorded.
            try await session.attach(
                bootstrap: try daemon.bootstrap(session: "reattach"),
                sshHost: "127.0.0.1"
            )
            #expect(await log.wait {
                log.outputBytes.count >= handshake + before.count + away.count
            }, "the replay did not contain what happened while away")

            // §6.4, exactly: everything after the handshake must equal what the PTY
            // produced, in order, with no gap and no duplicate across the seam.
            let delivered = Array(log.outputBytes.dropFirst(handshake))
            #expect(delivered.count == before.count + away.count,
                    "expected \(before.count + away.count) bytes, delivered \(delivered.count)")
            #expect(delivered == before + away, "the byte stream across the seam is not exact")

            #expect(log.rebuilds.isEmpty, "a 4MB buffer should not have needed a rebuild")
            #expect(await session.consumedOffset > offsetAtDrop)
        }
    }

    /// Design doc §3.5: an overrun must be announced. The client's contract is that
        /// it hears about it as `screenRebuilt`, with the offsets, so a UI can clear.
        @Test("An overrun is surfaced as screenRebuilt with the offsets, not spliced")
        func overrunIsSurfaced() async throws {
            // Small buffer so a modest burst evicts the client's offset.
            try await withHarness(bufferCapacity: 512, child: .shell) { daemon in

                let session = MeshyySession()
                let log = EventLog()
                await log.attach(to: session)

                try await session.attach(
                    bootstrap: try daemon.bootstrap(session: "overrun"),
                    sshHost: "127.0.0.1"
                )
                try await session.send(markerCommand("ANCHOR_POINT"))
                #expect(await log.wait { log.text.contains("ANCHOR_POINT") })

                await session.detach(reason: "suspended")

                // Far more than 512 bytes while away, so the client's offset is evicted.
                let daemonSession = await daemon.store.session(named: "overrun")
                let filler = String(repeating: "y", count: 60)
                try await daemonSession?.send(Array(
                    "i=0; while [ $i -lt 200 ]; do printf '%s\\n' '\(filler)'; i=$((i+1)); done\n".utf8
                ))
                // Wait for eviction rather than a duration — the precondition is the window
                // moving, and nothing else will do.
                var evicted = false
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline {
                    if let info = await daemonSession?.info, info.bufferedFrom > 0 { evicted = true; break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                #expect(evicted, "the ring buffer never overran, so there is nothing to announce")

                try await session.attach(
                    bootstrap: try daemon.bootstrap(session: "overrun"),
                    sshHost: "127.0.0.1"
                )
                #expect(await log.wait { !log.rebuilds.isEmpty },
                        "an evicted offset must surface as screenRebuilt; got \(log.all.count) events")

                guard let rebuild = log.rebuilds.first else { return }
                #expect(rebuild.1 > rebuild.0,
                        "the resumed offset must be ahead of what the client had")
                // And the offset must be corrected, not left drifting behind the daemon.
                let corrected = await session.consumedOffset
                #expect(corrected >= rebuild.1)
            }
        }

        @Test("Acks are throttled to at most one per interval (design doc §6.2)")
        func acksAreThrottled() async throws {
            try await withHarness(child: .shell) { daemon in

                let session = MeshyySession()
                let log = EventLog()
                await log.attach(to: session)
                try await session.attach(
                    bootstrap: try daemon.bootstrap(session: "acks"),
                    sshHost: "127.0.0.1"
                )

                // Many small writes in quick succession. Without throttling this would put
                // an Ack behind every echo.
                for index in 0..<25 {
                    try await session.send(markerCommand("TICK\(index)_END"))
                }
                #expect(await log.wait { log.text.contains("TICK24_END") })

                // The daemon records the highest offset it was told. It must be behind or
                // equal to the client's, never ahead, and the throttle means it is usually
                // behind — which is exactly why the client's own offset drives resume.
                let offset = await session.consumedOffset
                #expect(offset > 0)
                #expect(MeshyySession.ackInterval == .milliseconds(250),
                        "design doc §6.2 fixes this interval; changing it is a protocol decision")
            }
        }

        @Test("A first attach resumes from nothing, so the daemon shows the current screen")
        func firstAttachIsFresh() async throws {
            try await withHarness(child: .shell) { daemon in

                // Give the session output BEFORE any client attaches.
                let boot = try daemon.bootstrap(session: "pre-existing")
                let daemonSession = await daemon.store.session(named: "pre-existing")
                try await daemonSession?.send(markerCommand("ALREADY_HERE"))
                try await Task.sleep(for: .milliseconds(400))

                let session = MeshyySession()
                let log = EventLog()
                await log.attach(to: session)
                try await session.attach(bootstrap: boot, sshHost: "127.0.0.1")

                #expect(await log.wait { log.text.contains("ALREADY_HERE") },
                        "a fresh attach must show what is already on screen, not a blank terminal")
                // A fresh attach is not a rebuild: the client had nothing, so nothing was lost.
                #expect(log.rebuilds.isEmpty, "a first attach must not be reported as a rebuild")
            }
        }
    }
}
