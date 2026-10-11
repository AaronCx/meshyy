// meshyy — what a client-side emulator BELIEVES about mouse/alt state vs what
// the far side armed, across live streaming, reattach, and ring-flood resume.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// The user-visible failure under investigation: a+Terminal's swipe-to-scroll
// picks its mode from the app emulator's state (alt screen? mouse reporting?).
// When that belief diverges from what tmux actually armed on the daemon's pty,
// a swipe is routed wrong — most damagingly to "native scrollback", which on a
// full-screen TUI is a dead swipe. The escapes that arm these modes are sent
// ONCE (tmux arms its client — the daemon's pty — at attach and never again),
// so any client whose emulator missed them stays wrong until the next real
// change, which can be days away. That is what makes wrongness here PERSISTENT
// rather than cosmetic, and why these tests measure it end to end.
//
// The belief model (ScrollBeliefSupport.swift) replicates the app side faithfully:
//   - SwiftTerm's semantics, including the trap that `?1006l` (SGR encoding
//     off) resets mouseMode to .off outright — not just the encoding.
//   - a+Terminal's synthesis of a daemon `modes` frame into escapes
//     (MeshyyTransport.modeEscapes in the app repo — keep the replica synced).

import Darwin
import Foundation
import MeshyyCore
import Testing
@testable import MeshyyDaemon
@testable import MeshyyKit

// The belief model, the app's synthesis replica, the event log and the isolated
// tmux server live in ScrollBeliefSupport.swift, shared with the SSH-oracle suite.

// MARK: - The suite

extension MeshyyKitSuite {
    @Suite("Scroll-mode belief vs far-side truth", .serialized,
           .enabled(if: ScrollTmux.available, Comment(rawValue: ScrollTmux.unavailableReason)))
    struct ScrollModeBeliefTests {

        /// Waits for the daemon-side pty to have seen tmux arm the outer
        /// terminal, as witnessed by a client that lived through every byte.
        private func armOuter(
            _ log: BeliefLog, expectAlt: Bool = true
        ) async -> Bool {
            await log.wait(timeout: 20) {
                let belief = log.belief
                return belief.mouseOn && (!expectAlt || belief.alt)
            }
        }

        @Test("What tmux 'mouse on' actually arms on the outer terminal")
        func tmuxArmsTheOuterTerminal() async throws {
            try await withHarness(child: .shell) { daemon in
                let tmux = try ScrollTmux(mouse: true)
                defer { tmux.kill() }

                let observer = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
                let log = BeliefLog()
                await log.attach(to: observer)
                let boot = try daemon.bootstrap(session: "arming")
                try await observer.attach(bootstrap: boot, sshHost: "127.0.0.1")
                try await observer.send(Array(tmux.attachCommand.utf8))

                let armed = await armOuter(log)
                let final = log.belief
                #expect(armed, """
                    the outer terminal was never armed: mouseOn=\(final.mouseOn) \
                    alt=\(final.alt) — \(log.summary)
                    """)

                // MEASUREMENT, not just a pass mark: record exactly which
                // tracked modes tmux 3.6a arms, because the app's synthesis is
                // defined over this set.
                let lastModes = log.modesFrames.last ?? []
                print("MEASURE tmuxArming: modes frames \(log.modesFrames.map { $0.sorted() }), final \(lastModes.sorted())")
                #expect(lastModes.contains(1000) || lastModes.contains(1002)
                        || lastModes.contains(1003),
                        "tmux armed no mouse mode the tracker saw: \(log.summary)")

                await observer.shutdown()
            }
        }

        @Test("A fresh client after tmux armed long ago: replay + modes frame must land it right")
        func freshAttachBelievesTheArmedState() async throws {
            try await withHarness(child: .shell) { daemon in
                let tmux = try ScrollTmux(mouse: true)
                defer { tmux.kill() }

                // Arm, witnessed by a first client, which then goes away —
                // the app relaunch / new-tab shape.
                let first = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
                let firstLog = BeliefLog()
                await firstLog.attach(to: first)
                let boot = try daemon.bootstrap(session: "freshbelief")
                try await first.attach(bootstrap: boot, sshHost: "127.0.0.1")
                try await first.send(Array(tmux.attachCommand.utf8))
                #expect(await armOuter(firstLog), "outer never armed: \(firstLog.summary)")
                await first.detach(reason: "app force-quit")
                await first.shutdown()

                // The fresh emulator.
                let fresh = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
                let freshLog = BeliefLog()
                await freshLog.attach(to: fresh)
                let reboot = try daemon.bootstrap(session: "freshbelief")
                try await fresh.attach(bootstrap: reboot, sshHost: "127.0.0.1")

                let settled = await freshLog.wait(timeout: 20) {
                    freshLog.belief.mouseOn
                }
                let belief = freshLog.belief
                #expect(settled && belief.mouseOn, """
                    fresh client's emulator believes mouse is OFF while tmux \
                    has it armed — the dead-swipe state: \(freshLog.summary)
                    """)

                // MEASUREMENTS the report needs:
                //  - could the replay alone have taught it? (anchor still live)
                //  - did the modes synthesis have to rescue it?
                //  - what does it believe about the alt screen? The app
                //    ignores `.screenMode`, so `belief.alt` here is exactly
                //    what the shipping app would believe.
                let replayOnly = freshLog.beliefFromOutputOnly
                print("""
                    MEASURE freshAttach: replay-only mouseOn=\(replayOnly.mouseOn) \
                    alt=\(replayOnly.alt); with-synthesis mouseOn=\(belief.mouseOn) \
                    alt=\(belief.alt); modes frames \(freshLog.modesFrames.map { $0.sorted() })
                    """)

                await fresh.shutdown()
            }
        }

        @Test("Resume after an output flood that ate the ring: only the modes frame can rescue")
        func floodedRingStillYieldsTheRightBelief() async throws {
            // A small ring so the flood reliably evicts both the alt-screen
            // anchor and the arming escapes.
            try await withHarness(bufferCapacity: 32_768, child: .shell) { daemon in
                let tmux = try ScrollTmux(mouse: true)
                defer { tmux.kill() }

                let first = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
                let firstLog = BeliefLog()
                await firstLog.attach(to: first)
                let boot = try daemon.bootstrap(session: "floodbelief")
                try await first.attach(bootstrap: boot, sshHost: "127.0.0.1")
                try await first.send(Array(tmux.attachCommand.utf8))
                #expect(await armOuter(firstLog), "outer never armed: \(firstLog.summary)")

                // The flood, inside the pane — the Claude Code shape: full
                // repaints, over and over. `clear` matters twice: it makes
                // tmux draw real bytes on the OUTER stream (a plain `seq`
                // flood is collapsed into a handful of redraws and never
                // fills the ring — measured), and each ESC[2J moves the
                // replay ANCHOR forward, past the arming escapes, which is
                // exactly how a long-lived session's arming becomes
                // unreplayable history.
                // The marker is split in the typed command (`FLOOD_''OVER`)
                // so the ECHO of the command being typed into the pane cannot
                // satisfy the wait — only the command's own output can. The
                // 10ms pacing keeps tmux from collapsing the loop into a few
                // frames: each iteration must actually be DRAWN to put bytes
                // through the ring.
                _ = tmux.run(["send-keys", "-t", "p",
                              "i=0; while [ $i -lt 200 ]; do clear; seq $i $((i+23)); "
                              + "sleep 0.01; i=$((i+1)); done; echo FLOOD_''OVER", "Enter"])
                #expect(await firstLog.wait(timeout: 60) {
                    firstLog.text.contains("FLOOD_OVER")
                }, "the flood never finished: \(firstLog.text.suffix(200))")
                await first.detach(reason: "app force-quit mid-flood")
                await first.shutdown()

                let fresh = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
                let freshLog = BeliefLog()
                await freshLog.attach(to: fresh)
                let reboot = try daemon.bootstrap(session: "floodbelief")
                try await fresh.attach(bootstrap: reboot, sshHost: "127.0.0.1")

                let settled = await freshLog.wait(timeout: 20) {
                    freshLog.belief.mouseOn
                }
                let belief = freshLog.belief
                let replayOnly = freshLog.beliefFromOutputOnly

                // The end-to-end invariant: after a flood consumed the arming
                // history, a fresh client must still end up believing mouse
                // is armed — through the modes frame, or through tmux's own
                // WINCH pulse (the attach resync makes tmux disarm+rearm the
                // outer terminal; see the measurement below). Either path
                // failing is a dead swipe until the next real mode change.
                #expect(settled && belief.mouseOn, """
                    after a flood consumed the arming history, the fresh \
                    client's emulator believes mouse is OFF while tmux has it \
                    on — a swipe here is dead until tmux next changes a mode: \
                    \(freshLog.summary)
                    """)

                // MEASUREMENT: what taught the fresh emulator? (Both paths
                // usually do; alt is taught by NEITHER — the ?1049h is
                // evicted history, 1049 is not a tracked mode, and the app
                // ignores `.screenMode` — so `alt` here is what the shipping
                // app would wrongly believe.)
                let inventory = decModeInventory(freshLog)
                print("""
                    MEASURE floodedRing: replay-only mouseOn=\(replayOnly.mouseOn) \
                    alt=\(replayOnly.alt); with-synthesis mouseOn=\(belief.mouseOn) \
                    alt=\(belief.alt); escape/frame flow (\(inventory.count) entries): \
                    \(inventory.prefix(2)) … \(inventory.suffix(2))
                    """)

                await fresh.shutdown()
            }
        }

        @Test("A flapping program: belief tracks truth live, and every reattach settles right")
        func flappingProgramBeliefSettles() async throws {
            try await withHarness(child: .shell) { daemon in
                // No tmux here on purpose: this measures the TRANSPORT's
                // tracking of a program that toggles mouse reporting, the H1
                // shape, without tmux's own policy in the way.
                let observer = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
                let observerLog = BeliefLog()
                await observerLog.attach(to: observer)
                let boot = try daemon.bootstrap(session: "flapper")
                try await observer.attach(bootstrap: boot, sshHost: "127.0.0.1")

                // The flapper: ~4 Hz for ~10 s, announcing each state so the
                // log carries truth alongside the escapes themselves.
                let flapper = "i=0; while [ $i -lt 40 ]; do "
                    + "printf 'ON\\033[?1000h\\033[?1006h'; sleep 0.12; "
                    + "printf 'OFF\\033[?1000l\\033[?1006l'; sleep 0.12; "
                    + "i=$((i+1)); done; printf 'ON\\033[?1000h\\033[?1006h'; "
                    + "printf 'FLAPS_DONE\\n'\n"
                try await observer.send(Array(flapper.utf8))

                // While the flapper runs, a subject client detaches and
                // reattaches repeatedly — the foreground/background shape —
                // and after every attach its belief must settle to the
                // observer's within a bounded window.
                let subject = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
                let subjectLog = BeliefLog()
                await subjectLog.attach(to: subject)

                var settleTimes: [TimeInterval] = []
                var failures = 0
                for cycle in 0..<8 {
                    let reboot = try daemon.bootstrap(session: "flapper")
                    let began = Date()
                    try await subject.attach(bootstrap: reboot, sshHost: "127.0.0.1")
                    // Settled = agreeing with the live observer. Both sides
                    // keep moving, so "agree at some instant within 3s" is
                    // the assertion; the time to first agreement is the
                    // measurement.
                    let agreed = await subjectLog.wait(timeout: 3) {
                        subjectLog.belief.mouseOn == observerLog.belief.mouseOn
                    }
                    if agreed {
                        settleTimes.append(Date().timeIntervalSince(began))
                    } else {
                        failures += 1
                        print("MEASURE flapSettle cycle \(cycle): NEVER AGREED — subject \(subjectLog.belief.mouseOn) vs observer \(observerLog.belief.mouseOn)")
                    }
                    await subject.detach(reason: "cycle \(cycle)")
                    try await Task.sleep(for: .milliseconds(150))
                }

                #expect(await observerLog.wait(timeout: 20) {
                    observerLog.text.contains("FLAPS_DONE")
                }, "the flapper never finished")

                // After the dust settles the flapper left mouse ON; both
                // clients must agree on that — a reattach that lands wrong
                // and STAYS wrong is the dead-swipe bug.
                let final = try daemon.bootstrap(session: "flapper")
                try await subject.attach(bootstrap: final, sshHost: "127.0.0.1")
                let finallyRight = await subjectLog.wait(timeout: 5) {
                    subjectLog.belief.mouseOn
                }
                #expect(finallyRight, """
                    after the flapping stopped with mouse armed, a reattached \
                    client still believes it is off: \(subjectLog.summary.suffix(400))
                    """)

                let worst = settleTimes.max() ?? -1
                print("""
                    MEASURE flapSettle: \(settleTimes.count)/8 cycles agreed, \
                    worst settle \(Int(worst * 1000))ms, failures \(failures)
                    """)
                #expect(failures == 0, "some reattach cycles never agreed with live truth")

                await subject.shutdown()
                await observer.shutdown()
            }
        }

        @Test("Inner-pane mouse flaps do not flap the outer terminal while tmux owns the mouse")
        func innerFlapsStayInsideTmux() async throws {
            try await withHarness(child: .shell) { daemon in
                let tmux = try ScrollTmux(mouse: true)
                defer { tmux.kill() }

                let observer = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
                let log = BeliefLog()
                await log.attach(to: observer)
                let boot = try daemon.bootstrap(session: "innerflap")
                try await observer.attach(bootstrap: boot, sshHost: "127.0.0.1")
                try await observer.send(Array(tmux.attachCommand.utf8))
                #expect(await armOuter(log), "outer never armed: \(log.summary)")

                // The inner program (Claude Code's shape: it arms mouse and
                // the alt screen) flaps its OWN mouse reporting.
                _ = tmux.run(["send-keys", "-t", "p",
                              "i=0; while [ $i -lt 20 ]; do "
                              + "printf '\\033[?1000h\\033[?1006h'; sleep 0.05; "
                              + "printf '\\033[?1000l\\033[?1006l'; sleep 0.05; "
                              + "i=$((i+1)); done; echo INNER_DONE", "Enter"])
                #expect(await log.wait(timeout: 20) {
                    log.text.contains("INNER_DONE")
                }, "the inner flapper never finished")

                // Count OUTER transitions during the flapping: with tmux
                // owning the mouse, the outer terminal should stay armed the
                // whole time. Any outer disarm is a window in which a swipe
                // picks the wrong mode — H1 confirmed at the tmux layer.
                var transitions = 0
                var wasOn = false
                var current = EmulatorBelief()
                var everOn = false
                for entry in log.all {
                    if case .output(let bytes) = entry.event {
                        current.feed(bytes)
                        if everOn && current.mouseOn != wasOn { transitions += 1 }
                        if current.mouseOn { everOn = true }
                        wasOn = current.mouseOn
                    }
                }
                print("MEASURE innerFlaps: outer transitions after first arm = \(transitions)")
                #expect(log.belief.mouseOn, "outer ended disarmed: \(log.summary.suffix(300))")

                await observer.shutdown()
            }
        }

        @Test("A resize makes tmux pulse the outer mouse off and back on — measure the window")
        func resizePulsesTheOuterMouse() async throws {
            // The mechanism behind "sometimes swipes are dead": tmux answers
            // every WINCH/attach redraw by DISARMING the outer terminal's
            // mouse modes and re-arming them (measured on tmux 3.6a:
            // `?1006l ?1000l ?1002l ?1003l … ?1006h ?1000h ?1002h`). The
            // phone resizes on every keyboard show/dismiss, so this pulse is
            // CONSTANT in real use. Between the halves the emulator honestly
            // believes mouse is off; a swipe that samples inside that window
            // — or a client that never receives the second half — routes
            // wrong. This test measures the believed-off windows a client
            // actually observes across resizes.
            try await withHarness(child: .shell) { daemon in
                let tmux = try ScrollTmux(mouse: true)
                defer { tmux.kill() }

                let session = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
                let log = BeliefLog()
                await log.attach(to: session)
                let boot = try daemon.bootstrap(session: "pulse")
                try await session.attach(bootstrap: boot, sshHost: "127.0.0.1")
                try await session.send(Array(tmux.attachCommand.utf8))
                #expect(await armOuter(log), "outer never armed: \(log.summary)")

                // Keyboard show / dismiss, five times.
                for flip in 0..<5 {
                    try await session.resize(to: TerminalSize(cols: 80, rows: flip % 2 == 0 ? 18 : 24))
                    try await Task.sleep(for: .milliseconds(300))
                }

                // Walk the recorded events and measure every believed-off
                // window after the first arming: how many there were and how
                // long each lasted (arrival-stamped, so this is the window a
                // swipe on this client could actually land in).
                var current = EmulatorBelief()
                var offSince: Date?
                var windows: [TimeInterval] = []
                var armedOnce = false
                for entry in log.all {
                    switch entry.event {
                    case .output(let bytes): current.feed(bytes)
                    case .modes(let active): current.feed(appModeEscapes(active: active))
                    default: continue
                    }
                    if current.mouseOn {
                        armedOnce = true
                        if let began = offSince {
                            windows.append(entry.at.timeIntervalSince(began))
                            offSince = nil
                        }
                    } else if armedOnce, offSince == nil {
                        offSince = entry.at
                    }
                }
                let milliseconds = windows.map { Int($0 * 1000) }
                print("""
                    MEASURE resizePulse: \(windows.count) believed-off windows \
                    across 5 resizes, durations \(milliseconds)ms, \
                    modes frames \(log.modesFrames.map { $0.sorted() })
                    """)

                // The invariant: every pulse must CLOSE — a session that ends
                // disarmed after resizes is the persistent dead-swipe state.
                #expect(log.belief.mouseOn,
                        "the outer terminal ended disarmed after resizes: \(log.summary.suffix(300))")
                #expect(offSince == nil,
                        "a disarm pulse never closed: \(log.summary.suffix(300))")

                await session.shutdown()
            }
        }

        @Test("Client-side ordering: modes never reorder against the output around them")
        func clientOrderingIsPreserved() async throws {
            // The H2 question, answered at the layer the client controls: the
            // attach burst arrives as [replayBase, pty, resetGeometry,
            // termios, screenMode, modes, pty] and the event stream must
            // preserve output/modes relative order — synthesised state may
            // never be overtaken by the bytes it corrects, nor overtake bytes
            // that came after it.
            let session = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
            let log = BeliefLog()
            await log.attach(to: session)

            await session.resetForAttach(resumeFrom: nil)
            await session.handle(.control(.welcome(.init(
                sessionID: "s", bufferedFrom: 0, bufferedTo: 0))))
            await session.handle(.control(.replayBase(ptyID: 0, offset: 0)))
            await session.handle(.pty(0, Array("REPLAY\u{1B}[?1000l".utf8)))
            await session.handle(.control(.resetGeometry))
            await session.handle(.control(.termios(.cooked)))
            await session.handle(.control(.screenMode(alt: true)))
            await session.handle(.control(.modes(active: [1000, 1006])))
            await session.handle(.pty(0, Array("LIVE".utf8)))

            let complete = await log.wait(timeout: 5) {
                log.text.contains("LIVE")
            }
            #expect(complete, "events never drained: \(log.summary)")

            // Order out: output(replay) then modes then output(live).
            var shape: [String] = []
            for entry in log.all {
                switch entry.event {
                case .output: shape.append("output")
                case .modes: shape.append("modes")
                case .geometryReset: shape.append("geo")
                default: break
                }
            }
            #expect(shape == ["output", "geo", "modes", "output"],
                    "event order scrambled: \(shape) — \(log.summary)")

            // And the belief that order produces: the stale `?1000l` in the
            // replay is CORRECTED by the modes synthesis, because the
            // synthesis comes after it.
            #expect(log.belief.mouseOn,
                    "the synthesis was overtaken by the stale replay escape")

            await session.shutdown()
        }
    }
}
