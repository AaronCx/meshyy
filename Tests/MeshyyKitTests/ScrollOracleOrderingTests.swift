// meshyy — SSH as the oracle for swipe-to-scroll: one real tmux session, reached
// once by a real ssh client and once by MeshyySession through the UDP relay,
// swiped the same way, judged by what TMUX did.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Over SSH the emulator sees every byte tmux sends, so its belief about mouse
// mode and the alt screen is always right. Under meshyy a fresh or resumed
// emulator learns its modes from replay plus the daemon's `modes` frame, and
// a+Terminal routes every swipe on that belief. Every scroll bug so far has
// been that belief diverging from tmux's real state, and every one of them was
// "verified" by asserting the belief. This suite asserts the OUTCOME instead:
//
//   1. the wheel/arrow bytes the app would route from each side's belief are
//      fed to tmux, and tmux is asked whether it scrolled
//      (`#{pane_in_mode} #{scroll_position}`) and what the pane received;
//   2. the meshyy outcome must equal the ssh outcome. SSH is the oracle; any
//      difference is the bug.
//
// THE ORACLE is `/usr/bin/ssh -tt` to this Mac's own sshd, in a real PTY
// (MeshyyDaemon.PTY), running `tmux attach`. Its output feeds the same
// `EmulatorBelief` the subject uses; a keyboard show/hide is a PTY resize,
// which ssh turns into a window-change request.
// THE SUBJECT is a `MeshyySession` attached through `ChaosUDPProxy` to an
// in-process daemon whose shell runs `tmux attach` on the same session.
// Exactly one client is attached at a time, so tmux sizes the window to it.
//
// The pane runs a transcriber (`dd bs=1` into a file, tty in -icanon -echo) on
// top of 400 lines of scrollback, so one swipe has one observable outcome
// whichever route it took: copy mode and a scroll position for wheel events
// (tmux `mouse on`), the exact bytes the program received for arrow keys
// (tmux `mouse off`, where tmux owns the alt screen and arms no mouse mode).
//
// Measured on tmux 3.6a while building this (recorded so nobody re-derives it):
//   - a wheel event on a row BELOW the client's current height is ignored —
//     no copy mode — so "swipe at a row that only exists after the resize" is
//     a real outcome signal;
//   - but tmux applies a resize LATE relative to input that follows it.
//     Over plain ssh — one ordered TCP stream — resize 18→24 rows then a wheel
//     at row 20 0 ms later was taken at the OLD size in 17/20 runs, 10 ms
//     later in 10/20 (consistent with tmux's server reading the tty directly
//     while learning the size from its client process). That race is tmux's
//     own, on every transport, and it swallows transport reordering: a resize
//     delayed behind its swipe and a resize delivered in the same burst as its
//     swipe look alike to tmux. So the #63 ordering ASSERTION uses a far-side
//     program that applies a resize synchronously (`dismissAndSwipeStayOrdered`),
//     and the through-tmux loop records tmux's distribution on both transports
//     and asserts only that every swipe was taken whole, at one size.
//   - with `mouse off`, tmux re-encodes the app's SS3 arrows for the pane as
//     a mix of CSI and SS3 depending on how the burst was read; the count of
//     Up arrows is the transport-independent fact.
//
// Gate: tmux, the probe key ~/.ssh/aplus_probe (authorized for this user) and
// sshd answering on 127.0.0.1:22. CI runners have none of the last two, so this
// suite SKIPS in CI by design and runs under `make check` on the dev Mac.

import Darwin
import Foundation
import Synchronization
@testable import MeshyyChaos
import MeshyyCore
import Testing
@testable import MeshyyDaemon
@testable import MeshyyKit

// MARK: - Capability

enum SSHOracleSupport {
    static let probeKey = NSHomeDirectory() + "/.ssh/aplus_probe"

    static let isAvailable: Bool = ScrollTmux.available
        && FileManager.default.isReadableFile(atPath: probeKey)
        && loopbackSSHAnswers()

    static let reason: Comment = """
        needs tmux, the probe key ~/.ssh/aplus_probe authorized for this user, and \
        sshd on 127.0.0.1:22 — CI runners have no probe key or sshd, so this suite \
        skips there by design; it runs under make check on the dev Mac
        """

    /// A bounded TCP connect, so a machine without sshd skips in about a second
    /// instead of hanging the suite.
    private static func loopbackSSHAnswers() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(22).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let started = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if started == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, 1000) == 1 else { return false }
        var failure: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length)
        return failure == 0
    }
}

// MARK: - The oracle

/// A real ssh client in a real PTY, attached to the tmux session. Everything it
/// prints feeds an `EmulatorBelief`, exactly as the subject's output does.
final class SSHOracle: @unchecked Sendable {
    private let pty: PTY
    private let lock = NSLock()
    private var current = EmulatorBelief()
    private var received: [UInt8] = []
    private var stopping = false
    private let readerDone = DispatchSemaphore(value: 0)
    private(set) var size: TerminalSize

    init(tmux: ScrollTmux, knownHosts: String, size: TerminalSize) throws {
        self.size = size
        pty = try PTY(
            executable: "/usr/bin/ssh",
            arguments: [
                "-tt", "-i", SSHOracleSupport.probeKey,
                "-o", "BatchMode=yes",
                "-o", "IdentitiesOnly=yes",
                "-o", "UserKnownHostsFile=\(knownHosts)",
                "-o", "StrictHostKeyChecking=accept-new",
                "127.0.0.1",
                "\(ScrollTmux.path) -L \(tmux.label) attach -t p",
            ],
            environment: [
                "HOME": NSHomeDirectory(),
                "PATH": "/usr/bin:/bin",
                "TERM": "xterm-256color",
            ],
            size: size
        )
        let thread = Thread { [self] in readLoop() }
        thread.start()
    }

    private func readLoop() {
        defer { readerDone.signal() }
        while !lock.withLock({ stopping }) {
            var poller = pollfd(fd: pty.masterFD, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 50) >= 0 else { continue }
            guard let bytes = try? pty.read() else { return }   // EOF: ssh exited
            if bytes.isEmpty { continue }
            lock.withLock {
                received += bytes
                current.feed(bytes)
            }
        }
    }

    var belief: EmulatorBelief { lock.withLock { current } }
    var text: String { lock.withLock { String(decoding: received, as: UTF8.self) } }

    /// Writes everything, never blocking the caller for long: a swipe is a few
    /// dozen bytes and the PTY takes kilobytes.
    func send(_ bytes: [UInt8]) throws {
        var rest = bytes[...]
        let deadline = Date().addingTimeInterval(5)
        while !rest.isEmpty, Date() < deadline {
            let written = try pty.writeSome(Array(rest))
            rest = rest.dropFirst(written)
            if written == 0 { usleep(1_000) }
        }
    }

    func resize(to newSize: TerminalSize) throws {
        size = newSize
        try pty.resize(to: newSize)
    }

    func close() {
        lock.withLock { stopping = true }
        _ = readerDone.wait(timeout: .now() + 2)
        pty.terminate()
    }
}

// MARK: - Outcomes

/// What one swipe DID, as tmux and the pane's program report it.
struct ScrollOutcome: Equatable, CustomStringConvertible {
    let inMode: Int
    let scrollPosition: Int?
    /// The bytes the pane's program received, ESC shown as `^[`.
    let received: String

    var description: String {
        "mode=\(inMode) pos=\(scrollPosition.map(String.init) ?? "-") rx=\"\(received)\""
    }

    /// The same outcome with every Up arrow spelled one way. tmux re-encodes
    /// arrows for the pane as CSI or SS3 depending on how a burst was read
    /// (header), so the spelling is tmux's read timing, not the transport.
    var semantic: ScrollOutcome {
        ScrollOutcome(inMode: inMode, scrollPosition: scrollPosition,
                      received: received.replacingOccurrences(of: "^[OA", with: "^[[A"))
    }
}

/// One swipe on one side: what the belief said, what was routed and sent,
/// and what tmux then did.
struct SwipeRecord: CustomStringConvertible {
    let side: String
    let step: String
    let belief: String
    let route: AppScrollBridge.Route
    let row: Int
    let bytes: Int
    let outcome: ScrollOutcome
    let sendError: String?
    /// Scrollback lines above the screen when the swipe was sent.
    let history: Int
    /// Seconds from the send until tmux first showed any effect; nil if it
    /// never did (or nothing was sent).
    let landedAfter: TimeInterval?

    var description: String {
        "\(side)[\(step)] belief{\(belief)} route=\(route.rawValue) row=\(row) "
            + "sent=\(bytes)B hist=\(history) landed=\(landedAfter.map { "\(Int($0 * 1000))ms" } ?? "never") "
            + "\(outcome)" + (sendError.map { " SEND-ERROR \($0)" } ?? "")
    }
}

/// The isolated tmux server plus the pane's transcriber.
struct OracleBench {
    let tmux: ScrollTmux
    let mouse: Bool
    let transcriptPath: String
    let knownHosts: String

    init(mouse: Bool) throws {
        tmux = try ScrollTmux(mouse: mouse)
        self.mouse = mouse
        transcriptPath = "/tmp/\(tmux.label).keys"
        knownHosts = "/tmp/\(tmux.label).known_hosts"
    }

    /// `-icanon -echo min 1` so every byte reaches `dd` the moment tmux writes
    /// it; `isig` stays on so a C-c can stop it and give the shell back.
    var transcriber: String {
        "stty -icanon -echo min 1; dd bs=1 of=\(transcriptPath) 2>/dev/null; stty sane"
    }

    /// Starts the server and the pane: scrollback, then the transcriber.
    func start() async throws {
        #expect(tmux.startDetached(), "tmux would not start session p on \(tmux.label)")
        tmux.seed(then: transcriber)
        #expect(await waitForTranscriber(), "the pane's transcriber never started")
    }

    func paneCommand() -> String {
        (tmux.run(["display", "-p", "-t", "p", "#{pane_current_command}"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func waitForTranscriber(timeout: TimeInterval = 90) async -> Bool {
        await poll(timeout: timeout) { paneCommand() == "dd" }
    }

    /// Stops whatever the pane runs and types `line` at its shell.
    func paneRun(_ line: String) {
        tmux.cancelCopyMode()
        _ = tmux.run(["send-keys", "-t", "p", "C-c"])
        _ = tmux.run(["send-keys", "-t", "p", line, "Enter"])
    }

    var transcriptCount: Int {
        ((try? FileManager.default.attributesOfItem(atPath: transcriptPath))?[.size] as? Int) ?? 0
    }

    func transcript(from offset: Int) -> String {
        guard let data = FileManager.default.contents(atPath: transcriptPath),
              data.count > offset
        else { return "" }
        return String(decoding: data.dropFirst(offset), as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}", with: "^[")
    }

    func outcome(since offset: Int) -> ScrollOutcome {
        let state = tmux.scrollState()
        return ScrollOutcome(inMode: state.inMode, scrollPosition: state.scrollPosition,
                             received: transcript(from: offset))
    }

    /// Whether `outcome` is what a correct swipe of `ticks` up does here,
    /// independent of transport: with `mouse on` tmux enters copy mode and every
    /// wheel event after the first scrolls 5 lines; with `mouse off` the program
    /// receives exactly 3 Up arrows per tick and nothing else. (tmux re-encodes
    /// the arrows for the pane — measured: the first two of a burst as CSI A,
    /// the rest as SS3 A, identically over both transports — so the count is
    /// the transport-independent fact, not the encoding.)
    func isCorrectScroll(_ outcome: ScrollOutcome, ticks: Int = 3) -> Bool {
        if mouse {
            return outcome == ScrollOutcome(inMode: 1, scrollPosition: 5 * (ticks - 1), received: "")
        }
        let arrows = outcome.received.components(separatedBy: "^[[A").count - 1
            + outcome.received.components(separatedBy: "^[OA").count - 1
        let rest = outcome.received.replacingOccurrences(of: "^[[A", with: "")
            .replacingOccurrences(of: "^[OA", with: "")
        return outcome.inMode == 0 && arrows == 3 * ticks && rest.isEmpty
    }

    var correctScrollText: String {
        mouse ? "copy mode, scrolled 10 lines" : "exactly 9 Up arrows to the program"
    }

    func waitForClients(_ heights: [Int], timeout: TimeInterval = 20) async -> Bool {
        await poll(timeout: timeout) { tmux.clientHeights() == heights }
    }

    func detachEveryone() async -> Bool {
        tmux.detachAllClients()
        return await waitForClients([])
    }

    func kill() {
        tmux.kill()
        try? FileManager.default.removeItem(atPath: transcriptPath)
        try? FileManager.default.removeItem(atPath: knownHosts)
    }
}

/// Polls `predicate` every 25 ms until it holds or `timeout` passes.
@discardableResult
func poll(timeout: TimeInterval, _ predicate: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return predicate()
}

/// One way of reaching tmux: its current belief, its size, and how bytes get in.
struct SwipeSide {
    let name: String
    let belief: () -> EmulatorBelief
    let rows: () -> Int
    let deliver: ([UInt8]) async throws -> Void
}

extension EmulatorBelief {
    var summary: String { "mouse=\(mouseOn ? 1 : 0) alt=\(alt ? 1 : 0) ckm=\(applicationCursor ? 1 : 0)" }
}

/// One swipe's emission: what the belief said and what went out.
struct SentSwipe {
    let belief: EmulatorBelief
    let route: AppScrollBridge.Route
    let row: Int
    let bytes: [UInt8]
    let offset: Int
    let history: Int
    let sentAt: Date
    let sendError: String?
}

/// Routes and sends one swipe on `side` exactly as a+Terminal would — route
/// from the belief at this instant, bytes from the replica — without waiting
/// for tmux. Fails the test if the pane has nothing to scroll back to, since a
/// swipe over an empty history cannot show a scroll whatever the transport.
func emitSwipe(
    _ side: SwipeSide,
    on bench: OracleBench,
    ticks: Int = 3,
    row requestedRow: Int? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> SentSwipe {
    // Every swipe is judged from out-of-copy-mode; a leftover scroll would
    // read as this swipe's outcome whether or not it was delivered.
    let before = bench.tmux.scrollState()
    #expect(before.inMode == 0,
            "\(side.name): the pane is still in copy mode (\(before)) before the swipe is sent",
            sourceLocation: sourceLocation)
    let history = bench.tmux.historySize()
    #expect(history >= 5 * ticks,
            "\(side.name): the pane has \(history) lines of scrollback — too few for a swipe to show a scroll",
            sourceLocation: sourceLocation)
    let belief = side.belief()
    let rows = side.rows()
    // The view is `rows` cells of 20 pt; an unspecified swipe is mid-screen.
    let row = requestedRow
        ?? AppScrollBridge.wheelRow(forY: Double(rows) * 20 / 2, height: Double(rows) * 20, rows: rows)
    let route = AppScrollBridge.route(belief)
    let bytes = AppScrollBridge.bytes(route, up: true, ticks: ticks, col: 40, row: row,
                                      applicationCursor: belief.applicationCursor)
    let offset = bench.transcriptCount
    let sentAt = Date()
    var sendError: String?
    do {
        if !bytes.isEmpty { try await side.deliver(bytes) }
    } catch {
        sendError = "\(error)"
    }
    return SentSwipe(belief: belief, route: route, row: row, bytes: bytes, offset: offset,
                     history: history, sentAt: sentAt, sendError: sendError)
}

/// Waits for tmux's verdict on `sent` and records it.
///
/// Bytes take time to land, so "nothing happened" is only concluded after a
/// full `timeout` with no change at all; once anything changes, the verdict is
/// the state once it has been still for `settle` (or as soon as `done` holds).
/// A native swipe sends nothing, so there it is still for `quiet` and done.
func verdict(
    _ sent: SentSwipe,
    side: SwipeSide,
    step: String,
    on bench: OracleBench,
    settle: TimeInterval = 0.5,
    quiet: TimeInterval = 1.0,
    timeout: TimeInterval = 6,
    until done: ((ScrollOutcome) -> Bool)? = nil
) async -> SwipeRecord {
    let baseline = ScrollOutcome(inMode: 0, scrollPosition: nil, received: "")
    var last = bench.outcome(since: sent.offset)
    var landedAt: Date? = last == baseline ? nil : Date()
    var lastChange = Date()
    while Date().timeIntervalSince(sent.sentAt) < timeout {
        if let done, done(last) { break }
        let stillFor = Date().timeIntervalSince(lastChange)
        if done == nil {
            if landedAt != nil, stillFor >= settle { break }
            if sent.bytes.isEmpty, stillFor >= quiet { break }
        }
        try? await Task.sleep(for: .milliseconds(25))
        let now = bench.outcome(since: sent.offset)
        if now != last {
            last = now
            lastChange = Date()
            if landedAt == nil, now != baseline { landedAt = Date() }
        }
    }
    return SwipeRecord(side: side.name, step: step, belief: sent.belief.summary, route: sent.route,
                       row: sent.row, bytes: sent.bytes.count, outcome: last, sendError: sent.sendError,
                       history: sent.history,
                       landedAfter: landedAt.map { $0.timeIntervalSince(sent.sentAt) })
}

/// One swipe, sent and judged by tmux.
func swipe(
    _ side: SwipeSide,
    step: String,
    on bench: OracleBench,
    ticks: Int = 3,
    row requestedRow: Int? = nil,
    settle: TimeInterval = 0.5,
    timeout: TimeInterval = 6,
    until done: ((ScrollOutcome) -> Bool)? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> SwipeRecord {
    let sent = await emitSwipe(side, on: bench, ticks: ticks, row: requestedRow,
                               sourceLocation: sourceLocation)
    return await verdict(sent, side: side, step: step, on: bench, settle: settle,
                         timeout: timeout, until: done)
}

/// Out of copy mode and confirmed out, so the next swipe starts from zero. A
/// pane left in copy mode would hand the next swipe a leftover `mode=1 pos=10`
/// — the correct mouse-on outcome — so failing to leave it fails the test.
func resetScroll(_ bench: OracleBench, sourceLocation: SourceLocation = #_sourceLocation) async {
    bench.tmux.cancelCopyMode()
    let out = await poll(timeout: 3) { bench.tmux.scrollState().inMode == 0 }
    #expect(out, "copy mode would not cancel: \(bench.tmux.scrollState())", sourceLocation: sourceLocation)
}

// MARK: - The subject

/// A MeshyySession through the relay, with the belief log a+Terminal's emulator
/// would hold.
final class SubjectClient: @unchecked Sendable {
    let session: MeshyySession
    let log: BeliefLog
    private let sizeLock = Mutex(TerminalSize(cols: 80, rows: 24))

    init(size: TerminalSize = TerminalSize(cols: 80, rows: 24)) async {
        session = MeshyySession(size: size)
        log = BeliefLog()
        sizeLock.withLock { $0 = size }
        await log.attach(to: session)
    }

    var rows: Int { sizeLock.withLock { $0.rows } }

    func attach(_ daemon: TestDaemonHarness, name: String, relayPort: UInt16) async throws {
        var bootstrap = try daemon.bootstrap(session: name)
        bootstrap.port = relayPort
        try await session.attach(bootstrap: bootstrap, sshHost: "127.0.0.1")
    }

    func resize(_ size: TerminalSize) async throws {
        sizeLock.withLock { $0 = size }
        try await session.resize(to: size)
    }

    var side: SwipeSide {
        SwipeSide(name: "meshyy", belief: { self.log.belief }, rows: { self.rows },
                  deliver: { try await self.session.send($0) })
    }
}

extension SSHOracle {
    var side: SwipeSide {
        SwipeSide(name: "ssh", belief: { self.belief }, rows: { self.size.rows },
                  deliver: { try self.send($0) })
    }
}

/// Armed the way tmux arms a client that saw the attach live.
func isArmed(_ belief: EmulatorBelief, mouse: Bool) -> Bool {
    mouse ? (belief.mouseOn && belief.alt) : belief.alt
}

// MARK: - The suite

extension MeshyyKitSuite {
    @Suite("Swipe outcome: meshyy vs the SSH oracle", .serialized,
           .enabled(if: SSHOracleSupport.isAvailable, SSHOracleSupport.reason))
    struct ScrollOracleOrderingTests {

        private static let tall = TerminalSize(cols: 80, rows: 24)
        private static let short = TerminalSize(cols: 80, rows: 18)

        // MARK: Helpers that run one side of a step

        /// A fresh ssh client attached and armed, alone on the session.
        private func openOracle(_ bench: OracleBench, size: TerminalSize = tall) async throws -> SSHOracle {
            #expect(await bench.detachEveryone(), "a previous client would not detach")
            let oracle = try SSHOracle(tmux: bench.tmux, knownHosts: bench.knownHosts, size: size)
            let armed = await poll(timeout: 20) { isArmed(oracle.belief, mouse: bench.mouse) }
            #expect(armed, "the ssh oracle was never armed: \(oracle.belief.summary) — \(oracle.text.suffix(300))")
            #expect(await bench.waitForClients([size.rows]),
                    "tmux never sized to the ssh client: \(bench.tmux.clientHeights())")
            return oracle
        }

        /// Makes the subject's daemon shell attach tmux, alone on the session,
        /// with the arming seen live.
        private func attachTmux(_ subject: SubjectClient, _ bench: OracleBench) async throws {
            #expect(await bench.detachEveryone(), "a previous client would not detach")
            try await subject.session.send(Array(bench.tmux.attachExistingCommand.utf8))
            let armed = await subject.log.wait(timeout: 20) {
                isArmed(subject.log.belief, mouse: bench.mouse)
            }
            #expect(armed, "the meshyy client was never armed: \(subject.log.summary.suffix(300))")
            #expect(await bench.waitForClients([subject.rows]),
                    "tmux never sized to the meshyy client: \(bench.tmux.clientHeights())")
        }

        private func report(_ oracle: SwipeRecord, _ subject: SwipeRecord, relay: ChaosUDPProxy?,
                            note: String = "") {
            print("MEASURE scrollOracle \(subject.step): ssh \(oracle.outcome) via \(oracle.route.rawValue) | "
                  + "meshyy \(subject.outcome) via \(subject.route.rawValue) belief{\(subject.belief)} "
                  + "landed=\(subject.landedAfter.map { "\(Int($0 * 1000))ms" } ?? "never") hist=\(subject.history)"
                  + (note.isEmpty ? "" : " \(note)")
                  + (relay.map { " relay{\($0.snapshot().summary)}" } ?? ""))
        }

        /// The two assertions every step makes: the oracle did the right thing,
        /// and meshyy did the same thing.
        private func judge(_ oracle: SwipeRecord, _ subject: SwipeRecord, bench: OracleBench,
                           relay: ChaosUDPProxy?, knownIssue: String? = nil,
                           sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(bench.isCorrectScroll(oracle.outcome),
                    "the ssh ORACLE itself did not scroll as tmux should: \(oracle) (expected \(bench.correctScrollText))",
                    sourceLocation: sourceLocation)
            let differential = {
                #expect(subject.outcome.semantic == oracle.outcome.semantic, """
                    meshyy and ssh disagree on what the swipe did — \
                    oracle: \(oracle) | subject: \(subject) | \
                    relay: \(relay?.snapshot().summary ?? "-")
                    """, sourceLocation: sourceLocation)
            }
            if let knownIssue {
                withKnownIssue(Comment(rawValue: knownIssue)) { differential() }
            } else {
                differential()
            }
        }

        // MARK: The scenario

        @Test("Every swipe does over meshyy what it does over ssh",
              arguments: [true, false])
        func swipeOutcomeMatchesTheOracle(mouse: Bool) async throws {
            let bench = try OracleBench(mouse: mouse)
            defer { bench.kill() }
            try await bench.start()
            let variant = mouse ? "mouse-on" : "mouse-off"

            try await withHarness(child: .shell) { daemon in
                let relay = ChaosUDPProxy(targetHost: "127.0.0.1", targetPort: daemon.quicPort,
                                          profile: ChaosProfile(seed: 7))
                let relayPort = try relay.start()
                defer { relay.stop() }

                // 1. Attach.
                let oracle = try await openOracle(bench)
                await resetScroll(bench)
                let attachOracle = await swipe(oracle.side, step: "\(variant) attach", on: bench)
                oracle.close()

                var subject = await SubjectClient()
                try await subject.attach(daemon, name: "oracle", relayPort: relayPort)
                try await attachTmux(subject, bench)
                await resetScroll(bench)
                let attachSubject = await swipe(subject.side, step: "\(variant) attach", on: bench)
                report(attachOracle, attachSubject, relay: relay)
                judge(attachOracle, attachSubject, bench: bench, relay: relay)

                // 2. Keyboard show/hide: tmux pulses the outer mouse modes on
                // every WINCH. The swipe goes the instant tmux has applied the
                // new size — which is exactly when its disarm/re-arm pulse is in
                // flight to the client, the window a stale belief would show in.
                // (Not before: tmux takes input it reads ahead of a resize its
                // client process has not reported yet, on any transport — see
                // the file header. Swiping into that race measures tmux.)
                let keyboardOracle = try await openOracle(bench)
                var oracleCycles: [SwipeRecord] = []
                for flip in 0..<Self.keyboardFlips {
                    let size = flip % 2 == 0 ? Self.short : Self.tall
                    await resetScroll(bench)
                    try keyboardOracle.resize(to: size)
                    #expect(await Self.tmuxApplied(size, bench), "tmux never applied \(size) (ssh)")
                    oracleCycles.append(await swipe(keyboardOracle.side,
                                                    step: "\(variant) keyboard#\(flip)", on: bench))
                }
                keyboardOracle.close()

                try await attachTmux(subject, bench)
                for flip in 0..<Self.keyboardFlips {
                    let size = flip % 2 == 0 ? Self.short : Self.tall
                    await resetScroll(bench)
                    try await subject.resize(size)
                    #expect(await Self.tmuxApplied(size, bench), "tmux never applied \(size) (meshyy)")
                    let record = await swipe(subject.side, step: "\(variant) keyboard#\(flip)", on: bench)
                    report(oracleCycles[flip], record, relay: relay)
                    judge(oracleCycles[flip], record, bench: bench, relay: relay)
                }
                #expect(await bench.waitForClients([24]), "the last keyboard dismiss never reached tmux")

                // 3. Fresh client: the app relaunches; a new emulator learns its
                // modes from replay + the modes frame alone. The oracle's
                // equivalent is a fresh ssh attach — step 1's outcome.
                await subject.session.shutdown(reason: "app relaunch")
                subject = await SubjectClient()
                try await subject.attach(daemon, name: "oracle", relayPort: relayPort)
                await Self.settle(subject, mouse: mouse)
                await resetScroll(bench)
                let fresh = await swipe(subject.side, step: "\(variant) fresh-client", on: bench)
                report(attachOracle, fresh, relay: relay)
                judge(attachOracle, fresh, bench: bench, relay: relay,
                      knownIssue: mouse ? nil : Self.screenModeIssue)

                // 4. Reconnect in the middle of an output burst.
                let burst = "i=0; while [ $i -lt 120 ]; do clear; seq $i $((i+40)); "
                    + "sleep 0.01; i=$((i+1)); done; seq 1 400; " + bench.transcriber
                // Both legs drop 0.5 s into the burst and are back 0.3 s later,
                // while it is still repainting; `midBurst` proves that held.
                let burstOracle = try await openOracle(bench)
                bench.paneRun(burst)
                try await Task.sleep(for: .milliseconds(500))
                burstOracle.close()
                try await Task.sleep(for: .milliseconds(300))
                let oracleMidBurst = bench.paneCommand() != "dd"
                let reOracle = try await openOracle(bench)
                #expect(await bench.waitForTranscriber(), "the burst never finished (ssh leg)")
                await resetScroll(bench)
                let burstOracleRecord = await swipe(reOracle.side, step: "\(variant) reconnect-mid-burst", on: bench)
                reOracle.close()

                try await attachTmux(subject, bench)
                bench.paneRun(burst)
                try await Task.sleep(for: .milliseconds(500))
                await subject.session.detach(reason: "suspended mid-burst")
                try await Task.sleep(for: .milliseconds(300))
                let subjectMidBurst = bench.paneCommand() != "dd"
                try await subject.attach(daemon, name: "oracle", relayPort: relayPort)
                #expect(await bench.waitForTranscriber(), "the burst never finished (meshyy leg)")
                await Self.settle(subject, mouse: mouse)
                await resetScroll(bench)
                let burstSubject = await swipe(subject.side, step: "\(variant) reconnect-mid-burst", on: bench)
                #expect(oracleMidBurst && subjectMidBurst,
                        "a reconnect landed after the burst had finished, so this step tested an idle resume")
                report(burstOracleRecord, burstSubject, relay: relay,
                       note: "midBurst ssh=\(oracleMidBurst) meshyy=\(subjectMidBurst)")
                // Same emulator across the reconnect (the app keeps its terminal
                // view), so it keeps the alt belief it saw live: no known issue.
                judge(burstOracleRecord, burstSubject, bench: bench, relay: relay)

                // 5. Path drop: the relay goes deaf both ways and a swipe is
                // sent 0.5 s into it. ssh is the oracle (step 1's outcome):
                // over TCP a stalled path only delays bytes, in order. The
                // heartbeat declares the path dead after 3 missed 1 s probes,
                // inside the hole, so what happens to the swipe depends on who
                // acts on that verdict and whether the old path ever returns:
                //   heal          4 s hole, the library alone: nobody redials,
                //                 the connection rides out the hole;
                //   heal-redial   4 s hole, handled as a+Terminal does today:
                //                 `.failed` ends its transport and it redials
                //                 with a fresh emulator (establish() resets the
                //                 terminal) on the same path;
                //   path-change   the old path never returns (a Wi-Fi to
                //                 cellular move without connection migration):
                //                 same app handling, the redial goes out over
                //                 a second relay — the new path.
                // Each MEASURE line records whether the swipe was delivered
                // late, lost, or errored, with the PR A trace fields at the
                // instant it was sent. path-change is last: it kills `relay`.
                for leg in PathLeg.allCases {
                    let step = "\(variant) path-drop-\(leg.rawValue)"
                    try await attachTmux(subject, bench)
                    await resetScroll(bench)
                    let oldLog = subject.log
                    let failuresBefore = Self.failures(oldLog)
                    let hole = Date()
                    if leg == .pathChange {
                        relay.halfOpen(.both)
                    } else {
                        relay.blackHole(.both, for: .seconds(4))
                    }
                    try await Task.sleep(for: .milliseconds(500))
                    let inboundAge = subject.session.lastInboundFrameAt.map { Date().timeIntervalSince($0) }
                    let sent = await emitSwipe(subject.side, on: bench)

                    var redial = "none"
                    var newPath: ChaosUDPProxy?
                    if leg != .heal {
                        // Act on `.failed` the way the app's pump does, if it
                        // comes before the swipe has landed.
                        let quiet = ScrollOutcome(inMode: 0, scrollPosition: nil, received: "")
                        await poll(timeout: 8) {
                            Self.failures(oldLog) > failuresBefore || bench.outcome(since: sent.offset) != quiet
                        }
                        if Self.failures(oldLog) > failuresBefore {
                            let failedAt = Date().timeIntervalSince(hole)
                            await subject.session.shutdown(reason: "app: transport failed, redialling")
                            var dialPort = relayPort
                            if leg == .pathChange {
                                let fresh = ChaosUDPProxy(targetHost: "127.0.0.1", targetPort: daemon.quicPort,
                                                          profile: ChaosProfile(seed: 13))
                                dialPort = try fresh.start()
                                newPath = fresh
                            }
                            var attempts = 0
                            var recovered: SubjectClient?
                            while recovered == nil, Date().timeIntervalSince(hole) < 25 {
                                attempts += 1
                                let candidate = await SubjectClient()
                                do {
                                    // MeshyyTransport attaches with a 4 s timeout.
                                    var bootstrap = try daemon.bootstrap(session: "oracle")
                                    bootstrap.port = dialPort
                                    try await candidate.session.attach(bootstrap: bootstrap, sshHost: "127.0.0.1",
                                                                       timeout: .seconds(4))
                                    recovered = candidate
                                } catch {
                                    await candidate.session.shutdown()
                                }
                            }
                            #expect(recovered != nil, "\(step): the app-style redial never came back")
                            if let recovered {
                                subject = recovered
                                await Self.settle(recovered, mouse: mouse)
                            }
                            redial = "failed@\(Int(failedAt * 1000))ms redialled@"
                                + "\(Int(Date().timeIntervalSince(hole) * 1000))ms attempts=\(attempts)"
                        }
                    }

                    let dropped = await verdict(sent, side: subject.side, step: step, on: bench,
                                                timeout: 20, until: { bench.isCorrectScroll($0) })
                    let fate: String
                    if let error = dropped.sendError {
                        fate = "errored (\(error))"
                    } else if bench.isCorrectScroll(dropped.outcome), let landed = dropped.landedAfter {
                        fate = "delivered late, \(Int((landed + 0.5) * 1000))ms after the hole opened"
                    } else if dropped.landedAfter == nil {
                        fate = "lost"
                    } else {
                        fate = "garbled"
                    }
                    report(attachOracle, dropped, relay: newPath ?? relay,
                           note: "fate=\(fate) inboundAgeAtSwipe=\(inboundAge.map { "\(Int($0 * 1000))ms" } ?? "nil") "
                               + "failedEvents=\(Self.failures(oldLog) - failuresBefore) redial=\(redial) "
                               + "oldEvents{\(oldLog.summary.suffix(160))}")
                    // A swipe written into a path that never returns dies with
                    // the connection the app abandons: the deferred path-change
                    // divergence. Every other leg must match the oracle outright.
                    judge(attachOracle, dropped, bench: bench, relay: newPath ?? relay,
                          knownIssue: leg == .pathChange ? Self.pathChangeIssue : nil)
                    if leg == .heal {
                        #expect((dropped.landedAfter ?? .infinity) < 15,
                                "the swipe took \(dropped.landedAfter ?? -1)s to land after a 4s hole")
                    }
                    // Proof each leg is the leg it says: a hole the heartbeat
                    // never called dead tests a plain delay, and a redial leg
                    // that never redialled is a second `heal`.
                    #expect(Self.failures(oldLog) > failuresBefore,
                            "\(step): the hole never produced .failed, so no dead path was ridden out")
                    #expect(leg == .heal || redial != "none",
                            "\(step): .failed never fired before the swipe landed, so no redial was exercised")

                    // The next swipe, once recovered. After a redial this is a
                    // fresh emulator, so with tmux mouse off the screenMode
                    // divergence applies.
                    try await Task.sleep(for: .seconds(1))
                    await resetScroll(bench)
                    let after = await swipe(subject.side, step: "\(step)-after", on: bench)
                    report(attachOracle, after, relay: newPath ?? relay)
                    judge(attachOracle, after, bench: bench, relay: newPath ?? relay,
                          knownIssue: redial != "none" && !mouse ? Self.screenModeIssue : nil)
                    if let newPath {
                        await subject.session.shutdown()
                        newPath.stop()
                    }
                }

                await subject.session.shutdown()
            }

            // 6. Ring overrun: suspended while a paced repaint flood laps a small
            // ring. Resumed by the SAME emulator (app suspended, not killed) the
            // daemon must rebuild the screen; resumed by a FRESH one (app killed
            // while suspended) only replay + the modes frame can teach it. The
            // oracle is a fresh ssh attach.
            try await withHarness(bufferCapacity: 16_384, child: .shell) { daemon in
                let relay = ChaosUDPProxy(targetHost: "127.0.0.1", targetPort: daemon.quicPort,
                                          profile: ChaosProfile(seed: 11))
                let relayPort = try relay.start()
                defer { relay.stop() }

                let oracle = try await openOracle(bench)
                await resetScroll(bench)
                let attachOracle = await swipe(oracle.side, step: "\(variant) ring-overrun", on: bench)
                oracle.close()

                let flood = "i=0; while [ $i -lt 400 ]; do clear; seq $i $((i+23)); "
                    + "sleep 0.01; i=$((i+1)); done; seq 1 400; " + bench.transcriber

                // Same emulator.
                let subject = await SubjectClient()
                try await subject.attach(daemon, name: "overrun", relayPort: relayPort)
                try await attachTmux(subject, bench)
                await subject.session.detach(reason: "suspended")
                bench.paneRun(flood)
                #expect(await bench.waitForTranscriber(), "the overrun flood never finished")
                try await subject.attach(daemon, name: "overrun", relayPort: relayPort)
                await Self.settle(subject, mouse: mouse)
                await resetScroll(bench)
                let resumed = await swipe(subject.side, step: "\(variant) ring-overrun-resume", on: bench)
                let rebuilt = subject.log.all.contains {
                    if case .screenRebuilt = $0.event { return true } else { return false }
                }
                // Not an outcome assertion: proof the step is what it says. A
                // flood that did not lap the ring tests an ordinary resume.
                #expect(rebuilt, "the flood never lapped the ring, so this was not an overrun: \(subject.log.summary.suffix(300))")
                report(attachOracle, resumed, relay: relay, note: "rebuilt=\(rebuilt)")
                judge(attachOracle, resumed, bench: bench, relay: relay)

                // Fresh emulator.
                await subject.session.detach(reason: "suspended again")
                bench.paneRun(flood)
                #expect(await bench.waitForTranscriber(), "the second overrun flood never finished")
                await subject.session.shutdown(reason: "killed while suspended")
                let cold = await SubjectClient()
                try await cold.attach(daemon, name: "overrun", relayPort: relayPort)
                await Self.settle(cold, mouse: mouse)
                await resetScroll(bench)
                let fresh = await swipe(cold.side, step: "\(variant) ring-overrun-fresh", on: bench)
                report(attachOracle, fresh, relay: relay)
                judge(attachOracle, fresh, bench: bench, relay: relay,
                      knownIssue: mouse ? nil : Self.screenModeIssue)
                await cold.session.shutdown()
            }
        }

        /// Polls tightly until tmux reports its one client at `size`.
        private static func tmuxApplied(_ size: TerminalSize, _ bench: OracleBench) async -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if bench.tmux.clientHeights() == [size.rows] { return true }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return false
        }

        /// A resumed or fresh client swipes once it is armed, or — with the known
        /// alt-screen divergence, where it never will be — once the attach burst
        /// is over: a modes frame has arrived and nothing else for 300 ms, which
        /// is when the screen a user would swipe has been painted. Bounded at 5 s.
        private static func settle(_ subject: SubjectClient, mouse: Bool) async {
            await subject.log.wait(timeout: 5) {
                if isArmed(subject.log.belief, mouse: mouse) { return true }
                let events = subject.log.all
                guard let last = events.last,
                      events.contains(where: { if case .modes = $0.event { true } else { false } })
                else { return false }
                return Date().timeIntervalSince(last.at) > 0.3
            }
        }

        /// The deferred path-change divergence: input written into a
        /// connection the app then abandons is not carried to the redial.
        private static let pathChangeIssue = """
            a+Terminal ends its meshyy transport on .failed (heartbeat lost, \
            3 missed probes) and redials with no connection migration; a swipe \
            sent into a path that never returns dies with the old connection. \
            The oracle here is the intended outcome (the swipe scrolls), not \
            literal ssh, whose TCP connection would not survive a path change \
            at all — \
            deferred, see docs/qa/scroll-divergence-audit.md in a+Terminal
            """

        /// The path-drop legs, in the order they run (see step 5).
        enum PathLeg: String, CaseIterable {
            case heal
            case healRedial = "heal-redial"
            case pathChange = "path-change"
        }

        /// How many `.failed` events a log holds.
        private static func failures(_ log: BeliefLog) -> Int {
            log.all.filter { if case .failed = $0.event { true } else { false } }.count
        }

        /// Keyboard show/hide flips: five full cycles.
        private static let keyboardFlips = 10

        /// The deferred `.screenMode` divergence, named where it bites.
        private static let screenModeIssue = """
            a+Terminal ignores the .screenMode frame, so with tmux `mouse off` a \
            fresh emulator (app relaunched, or killed while suspended) does not know tmux is on the alt screen and \
            routes the swipe native (nothing sent) where ssh sends arrow keys — \
            deferred, see docs/qa/scroll-divergence-audit.md in a+Terminal
            """

        // MARK: The #63 step: a resize and the swipe right behind it

        /// Seeds for the row-order loop, which asserts.
        private static let seeds: [UInt64] = Array(1...20)
        /// Seeds for the through-tmux loop. Fewer: its dismiss-then-swipe half is
        /// dominated by tmux's own resize race (header) and is recorded, not
        /// compared, and each seed costs a fresh attach plus a live re-arm.
        private static let tmuxSeeds: [UInt64] = Array(1...10)

        /// The relay for the ordering loops: 30 ms each way plus up to 40 ms of
        /// independent per-datagram jitter, and half the datagrams held back
        /// until the next one overtakes them. The jitter is what matters: a
        /// held datagram is released microseconds behind the one that passed
        /// it, which no far-side reader can resolve, while jitter lets a later
        /// datagram arrive tens of milliseconds earlier.
        private static func reordering(_ seed: UInt64) -> ChaosProfile {
            ChaosProfile(delay: .milliseconds(30), jitter: .milliseconds(40), reorder: 0.5, seed: seed)
        }

        /// The gap between the keyboard-dismiss resize and the swipe, 0-10 ms,
        /// fixed per seed so a red seed replays.
        private static func reorderGap(_ seed: UInt64) -> Duration {
            .milliseconds(Int(seed % 11))
        }

        /// A far-side program that arms the mouse like any TUI and, for every
        /// wheel event it reads, logs the event's row next to the window height
        /// the PTY has AT THAT MOMENT (TIOCGWINSZ, in-process, no fork). Unlike
        /// tmux it applies a resize synchronously, so it sees exactly the order
        /// in which resize and input reached the PTY — the order #63 put on one
        /// QUIC stream. Perl because it is on every Mac and needs no build step.
        private static let rowCheckScript = #"""
            use strict; use warnings; use IO::Handle;
            open(my $log, '>>', $ARGV[0]) or die "log: $!";
            $log->autoflush(1);
            system('stty', '-icanon', '-echo', 'min', '1');
            STDOUT->autoflush(1);
            print "\e[?1000h\e[?1006h", "ROWCHECK_READY\n";
            while (sysread(STDIN, my $buffer, 4096)) {
                my $ws = "\0" x 8;
                ioctl(STDIN, 0x40087468, $ws) or next;    # TIOCGWINSZ
                my ($rows) = unpack('S', $ws);
                while ($buffer =~ /\e\[<\d+;\d+;(\d+)M/g) { print {$log} "$1/$rows\n"; }
            }
            """#

        private struct RowCheck {
            let script: String
            let log: String

            init() throws {
                let token = UUID().uuidString.prefix(8).lowercased()
                script = "/tmp/mshy-rowcheck-\(token).pl"
                log = "/tmp/mshy-rowcheck-\(token).rows"
                try rowCheckScript.write(toFile: script, atomically: true, encoding: .utf8)
            }

            var command: String { "/usr/bin/perl \(script) \(log)" }

            var lines: [String] {
                (try? String(contentsOfFile: log, encoding: .utf8))?
                    .split(separator: "\n").map(String.init) ?? []
            }

            func remove() {
                try? FileManager.default.removeItem(atPath: script)
                try? FileManager.default.removeItem(atPath: log)
            }
        }

        /// keyboard up (18 rows), then keyboard down (24) and a swipe `gap`
        /// later at row 20 — a row that exists only once the dismiss has landed.
        private static func dismissThenSwipe(
            resize: (TerminalSize) async throws -> Void,
            deliver: ([UInt8]) async throws -> Void,
            belief: EmulatorBelief,
            gap: Duration
        ) async throws -> AppScrollBridge.Route {
            try await resize(short)
            try await Task.sleep(for: .milliseconds(250))
            try await resize(tall)
            if gap > .zero { try await Task.sleep(for: gap) }
            let route = AppScrollBridge.route(belief)
            let bytes = AppScrollBridge.bytes(route, up: true, ticks: 3, col: 40, row: 20,
                                              applicationCursor: belief.applicationCursor)
            if !bytes.isEmpty { try await deliver(bytes) }
            return route
        }

        @Test("A keyboard dismiss and the swipe behind it reach the far side in that order")
        func dismissAndSwipeStayOrdered() async throws {
            let check = try RowCheck()
            defer { check.remove() }
            let knownHosts = "/tmp/mshy-rowcheck-\(UUID().uuidString.prefix(8)).known_hosts"
            defer { try? FileManager.default.removeItem(atPath: knownHosts) }

            // The oracle: ssh delivers window-change and data in one ordered
            // TCP stream, so every swipe must be seen at 24 rows.
            let pty = try PTY(
                executable: "/usr/bin/ssh",
                arguments: ["-tt", "-i", SSHOracleSupport.probeKey, "-o", "BatchMode=yes",
                            "-o", "IdentitiesOnly=yes", "-o", "UserKnownHostsFile=\(knownHosts)",
                            "-o", "StrictHostKeyChecking=accept-new", "127.0.0.1", check.command],
                environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin",
                              "TERM": "xterm-256color"],
                size: Self.tall
            )
            defer { pty.terminate() }
            var oracleText = ""
            let ready = await poll(timeout: 20) {
                if let bytes = try? pty.read(), !bytes.isEmpty {
                    oracleText += String(decoding: bytes, as: UTF8.self)
                }
                return oracleText.contains("ROWCHECK_READY")
            }
            #expect(ready, "the row checker never started over ssh: \(oracleText.suffix(300))")
            var oracleBelief = EmulatorBelief()
            oracleBelief.feed(Array(oracleText.utf8))
            var oracleSeen: [String] = []
            for seed in Self.seeds {
                let before = check.lines.count
                _ = try await Self.dismissThenSwipe(
                    resize: { try pty.resize(to: $0) },
                    deliver: { _ = try pty.writeSome($0) },
                    belief: oracleBelief, gap: Self.reorderGap(seed))
                await poll(timeout: 5) { check.lines.count >= before + 3 }
                oracleSeen += check.lines.dropFirst(before)
                _ = try? pty.read()
            }
            #expect(oracleSeen.count == 3 * Self.seeds.count && oracleSeen.allSatisfy { $0 == "20/24" },
                    "the ssh ORACLE saw a swipe before its resize: \(oracleSeen)")
            pty.terminate()

            // The subject, one fresh connection per seed through a reordering relay.
            try await withHarness(child: .shell) { daemon in
                let setup = await SubjectClient()
                let direct = ChaosUDPProxy(targetHost: "127.0.0.1", targetPort: daemon.quicPort,
                                           profile: ChaosProfile(seed: 0))
                let directPort = try direct.start()
                try await setup.attach(daemon, name: "rowcheck", relayPort: directPort)
                try await setup.session.send(Array((check.command + "\n").utf8))
                #expect(await setup.log.wait(timeout: 20) { setup.log.text.contains("ROWCHECK_READY") },
                        "the row checker never started over meshyy: \(setup.log.text.suffix(300))")
                await setup.session.shutdown()
                direct.stop()

                var misordered: [String] = []
                for seed in Self.seeds {
                    let relay = ChaosUDPProxy(targetHost: "127.0.0.1", targetPort: daemon.quicPort,
                                              profile: Self.reordering(seed))
                    let relayPort = try relay.start()
                    let subject = await SubjectClient()
                    try await subject.attach(daemon, name: "rowcheck", relayPort: relayPort)
                    await subject.log.wait(timeout: 5) { subject.log.belief.mouseOn }
                    let before = check.lines.count
                    let route = try await Self.dismissThenSwipe(
                        resize: { try await subject.resize($0) },
                        deliver: { try await subject.session.send($0) },
                        belief: subject.log.belief, gap: Self.reorderGap(seed))
                    let arrived = await poll(timeout: 10) { check.lines.count >= before + 3 }
                    let seen = Array(check.lines.dropFirst(before))
                    let stats = relay.snapshot()
                    print("MEASURE rowOrder seed=\(seed) gap=\(Self.reorderGap(seed)) route=\(route.rawValue) "
                          + "seen=\(seen) relay{\(stats.summary)}")
                    #expect(route == .sgrWheel && arrived,
                            "seed \(seed): the swipe never reached the far side (route \(route.rawValue)) — \(stats.summary)")
                    if seen.contains(where: { $0 != "20/24" }) {
                        misordered.append("seed \(seed): \(seen) — \(stats.summary)")
                    }
                    await subject.session.shutdown()
                    relay.stop()
                }
                print("MEASURE rowOrder: \(misordered.count)/\(Self.seeds.count) seeds saw the swipe before the dismiss")
                #expect(misordered.isEmpty, """
                    the swipe overtook the keyboard-dismiss resize — the far side read a \
                    row-20 wheel event while the PTY was still 18 rows: \(misordered)
                    """)
            }
        }

        /// What tmux may do with a dismiss-then-swipe, on any transport: the
        /// whole swipe taken at the new size (a correct scroll), or — tmux's own
        /// resize race, mouse on only — the whole swipe taken at the old size,
        /// where row 20 does not exist and nothing happens. Never part of one,
        /// never anything else.
        private static func isWholeSwipe(_ outcome: ScrollOutcome, _ bench: OracleBench) -> Bool {
            bench.isCorrectScroll(outcome)
                || (bench.mouse && outcome == ScrollOutcome(inMode: 0, scrollPosition: nil, received: ""))
        }

        @Test("Ordering under a reordering relay, through tmux: fresh client + keystroke, and dismiss-then-swipe",
              arguments: [true, false])
        func reorderedClientsMatchTheOracle(mouse: Bool) async throws {
            let bench = try OracleBench(mouse: mouse)
            defer { bench.kill() }
            try await bench.start()
            let variant = mouse ? "mouse-on" : "mouse-off"

            // Oracle: one fresh attach + swipe, then the dismiss-then-swipe shape
            // once per seed, with the same gaps.
            let oracle = try await openOracle(bench)
            await resetScroll(bench)
            let attachOracle = await swipe(oracle.side, step: "\(variant) oracle-attach", on: bench)
            #expect(bench.isCorrectScroll(attachOracle.outcome), "the ssh ORACLE did not scroll: \(attachOracle)")
            var oracleOutcomes: [String: Int] = [:]
            for seed in Self.tmuxSeeds {
                await resetScroll(bench)
                let offset = bench.transcriptCount
                try oracle.resize(to: Self.short)
                #expect(await Self.tmuxApplied(Self.short, bench))
                let side = oracle.side
                _ = try await Self.dismissThenSwipe(
                    resize: { try oracle.resize(to: $0) }, deliver: { try await side.deliver($0) },
                    belief: oracle.belief, gap: Self.reorderGap(seed))
                try await Task.sleep(for: .milliseconds(600))
                let outcome = bench.outcome(since: offset)
                oracleOutcomes["\(outcome)", default: 0] += 1
                #expect(Self.isWholeSwipe(outcome, bench),
                        "seed \(seed): the ssh ORACLE split or garbled a swipe: \(outcome)")
            }
            oracle.close()

            try await withHarness(child: .shell) { daemon in
                // Something has to start tmux inside the daemon session once;
                // every client after it is fresh.
                let setup = await SubjectClient()
                let direct = ChaosUDPProxy(targetHost: "127.0.0.1", targetPort: daemon.quicPort,
                                           profile: ChaosProfile(seed: 0))
                let directPort = try direct.start()
                try await setup.attach(daemon, name: "reorder", relayPort: directPort)
                try await attachTmux(setup, bench)
                await setup.session.shutdown()
                direct.stop()

                var subjectOutcomes: [String: Int] = [:]
                for seed in Self.tmuxSeeds {
                    let relay = ChaosUDPProxy(targetHost: "127.0.0.1", targetPort: daemon.quicPort,
                                              profile: Self.reordering(seed))
                    let relayPort = try relay.start()

                    // Keystroke-then-replay: a fresh emulator types the moment
                    // its attach returns, while the replay is still arriving —
                    // the first keystroke of a connection is what opened the
                    // separate pty stream before #63. Then a swipe.
                    let subject = await SubjectClient()
                    try await subject.attach(daemon, name: "reorder", relayPort: relayPort)
                    try await subject.session.send(Array("k".utf8))
                    await Self.settle(subject, mouse: mouse)
                    await resetScroll(bench)
                    let fresh = await swipe(subject.side, step: "\(variant) keystroke-replay seed=\(seed)", on: bench)
                    report(attachOracle, fresh, relay: relay)
                    judge(attachOracle, fresh, bench: bench, relay: relay,
                          knownIssue: mouse ? nil : Self.screenModeIssue)

                    // Dismiss-then-swipe, from a belief that saw the attach live.
                    try await attachTmux(subject, bench)
                    await resetScroll(bench)
                    let offset = bench.transcriptCount
                    try await subject.resize(Self.short)
                    #expect(await Self.tmuxApplied(Self.short, bench))
                    let route = try await Self.dismissThenSwipe(
                        resize: { try await subject.resize($0) },
                        deliver: { try await subject.session.send($0) },
                        belief: subject.log.belief, gap: Self.reorderGap(seed))
                    try await Task.sleep(for: .milliseconds(600))
                    let outcome = bench.outcome(since: offset)
                    subjectOutcomes["\(outcome)", default: 0] += 1
                    #expect(Self.isWholeSwipe(outcome, bench),
                            "seed \(seed): meshyy split or garbled a swipe: \(outcome) — \(relay.snapshot().summary)")
                    print("MEASURE reorderTmux \(variant) seed=\(seed) gap=\(Self.reorderGap(seed)) "
                          + "route=\(route.rawValue) outcome{\(outcome)} relay{\(relay.snapshot().summary)}")

                    await subject.session.shutdown()
                    relay.stop()
                }
                print("MEASURE reorderTmux \(variant) dismiss-then-swipe: ssh \(oracleOutcomes) | meshyy \(subjectOutcomes)")
            }
        }
    }
}
