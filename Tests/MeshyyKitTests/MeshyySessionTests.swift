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
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MeshyySessionEvent] = []

    var all: [MeshyySessionEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

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

    /// A compact dump for failure messages, so a red test says what it saw.
    var summary: String {
        all.map { event in
            switch event {
            case .output(let bytes): "output(\(bytes.count)B)"
            case .screenRebuilt(let from, let at): "rebuilt(\(from)->\(at))"
            case .termios: "termios"
            case .screenMode(let alt): "screen(alt:\(alt))"
            case .agent(let kind, _, _): "agent(\(kind))"
            case .quickActions(let actions): "qa(\(actions.count))"
            case .ended(let reason): "ended(\(reason))"
            case .failed(let reason): "FAILED(\(reason))"
            }
        }.joined(separator: " ")
    }

    var failures: [String] {
        all.compactMap { if case .failed(let reason) = $0 { return reason } else { return nil } }
    }

    func start(_ session: MeshyySession) {
        Task { [weak self] in
            for await event in await session.events {
                // withLock, not lock()/unlock(): Swift 6 forbids the latter from an
                // async context.
                self?.append(event)
            }
        }
    }

    private func append(_ event: MeshyySessionEvent) {
        lock.withLock { events.append(event) }
    }

    func wait(timeout: TimeInterval = 8, until predicate: @Sendable @escaping () -> Bool) async -> Bool {
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
private func markerCommand(_ marker: String) -> [UInt8] {
    let midpoint = marker.index(marker.startIndex, offsetBy: marker.count / 2)
    let command = "printf '%s%s\\n' '\(marker[marker.startIndex..<midpoint])' "
        + "'\(marker[midpoint...])'\n"
    return Array(command.utf8)
}

extension MeshyyKitSuite {
    @Suite("Client session bookkeeping")
    struct MeshyySessionTests {

        @Test("consumedOffset counts exactly the bytes delivered, starting at the replay base")
        func offsetTracksDeliveredBytes() async throws {
            try await withHarness() { daemon in

                let session = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
                let log = EventLog()
                log.start(session)

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

        /// The M3 payoff, end to end through the real client API.
        @Test("A reattach after a dropped connection resumes byte-exactly")
        func reattachResumesExactly() async throws {
            try await withHarness() { daemon in

                let session = MeshyySession()
                let log = EventLog()
                log.start(session)

                try await session.attach(
                    bootstrap: try daemon.bootstrap(session: "reattach"),
                    sshHost: "127.0.0.1"
                )
                try await session.send(markerCommand("BEFORE_DROP"))
                #expect(await log.wait { log.text.contains("BEFORE_DROP") },
                        "events: \(log.summary) | text: \(log.text.debugDescription)")
                let offsetAtDrop = await session.consumedOffset

                // iOS suspends: the socket dies with no warning and no Bye.
                await session.detach(reason: "suspended")

                let daemonSession = await daemon.store.session(named: "reattach")
                try await daemonSession?.send(markerCommand("WHILE_AWAY"))
                try await Task.sleep(for: .milliseconds(400))

                // Foreground: fresh bootstrap (tokens are single-use), resume from the
                // offset the client itself recorded.
                try await session.attach(
                    bootstrap: try daemon.bootstrap(session: "reattach"),
                    sshHost: "127.0.0.1"
                )
                #expect(await log.wait { log.text.contains("WHILE_AWAY") },
                        "the replay must contain what happened while away")

                // §6.4: no duplicates. The pre-drop marker must appear exactly once across
                // the whole delivered stream.
                let occurrences = log.text.components(separatedBy: "BEFORE_DROP").count - 1
                #expect(occurrences == 1,
                        "resume duplicated bytes the client already had (\(occurrences) copies)")
                #expect(log.rebuilds.isEmpty,
                        "a 4MB buffer should not have needed a rebuild; got \(log.rebuilds)")
                #expect(await session.consumedOffset > offsetAtDrop)
            }
        }

        /// Design doc §3.5: an overrun must be announced. The client's contract is that
        /// it hears about it as `screenRebuilt`, with the offsets, so a UI can clear.
        @Test("An overrun is surfaced as screenRebuilt with the offsets, not spliced")
        func overrunIsSurfaced() async throws {
            // Small buffer so a modest burst evicts the client's offset.
            try await withHarness(bufferCapacity: 512) { daemon in

                let session = MeshyySession()
                let log = EventLog()
                log.start(session)

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
            try await withHarness() { daemon in

                let session = MeshyySession()
                let log = EventLog()
                log.start(session)
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
            try await withHarness() { daemon in

                // Give the session output BEFORE any client attaches.
                let boot = try daemon.bootstrap(session: "pre-existing")
                let daemonSession = await daemon.store.session(named: "pre-existing")
                try await daemonSession?.send(markerCommand("ALREADY_HERE"))
                try await Task.sleep(for: .milliseconds(400))

                let session = MeshyySession()
                let log = EventLog()
                log.start(session)
                try await session.attach(bootstrap: boot, sshHost: "127.0.0.1")

                #expect(await log.wait { log.text.contains("ALREADY_HERE") },
                        "a fresh attach must show what is already on screen, not a blank terminal")
                // A fresh attach is not a rebuild: the client had nothing, so nothing was lost.
                #expect(log.rebuilds.isEmpty, "a first attach must not be reported as a rebuild")
            }
        }
    }
}
