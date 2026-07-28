// meshyy — the tier-1 quick-action palette and its gate (M6).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// M6's acceptance has four clauses. Three are assertions about this code and are
// tested here; the fourth ("a tappable palette in the app") belongs to a+Terminal and
// is not claimed by this suite.
//
// The clause that carries the risk is "actions are unavailable when status is not
// `waiting`. No stray sends." A hidden button is not a guarantee — a stale view, a tap
// queued behind a status change, or a keyboard shortcut all reach the API with the
// button gone from the screen — so the gate is asserted at the API, where it holds
// regardless of what the UI believed.

import Foundation
import MeshyyCore
import Testing
@testable import MeshyyKit

@Suite("Quick actions, tier 1 (M6)")
struct QuickActionTests {

    /// Drives a session's status the way the daemon would, so the gate is exercised
    /// through the real frame path rather than by poking a property.
    private static func session(status: AgentEventKind?) async -> MeshyySession {
        let session = MeshyySession()
        await session.resetForAttach(resumeFrom: nil)
        _ = await session.handle(.control(.replayBase(ptyID: 0, offset: 0)))
        if let status {
            _ = await session.handle(
                .control(.agentEvent(kind: status, agentID: nil, detail: nil))
            )
        }
        return session
    }

    // MARK: - The palette itself

    /// The acceptance criterion: "no agent name and no prompt string is hardcoded
    /// anywhere in Swift."
    ///
    /// Tier 1 satisfies it by construction — it sends keystrokes, and a keystroke is
    /// not knowledge about any agent. This asserts that construction holds, so a
    /// later "helpful" addition like an action labelled for a specific tool has to
    /// argue with a test rather than slip in.
    @Test("The palette encodes no agent knowledge and no prompt text")
    func paletteIsAgentAgnostic() {
        for action in QuickActionPalette.tier1 {
            // Every action is a single keystroke. A multi-byte send would mean a
            // canned phrase, which is a prompt string by another name.
            #expect(action.sends.count == 1,
                    "\(action.id) sends \(action.sends.count) bytes — tier 1 is keystrokes, not phrases")
            // No match rules: that is precisely what separates tier 1 from tier 2.
            #expect(action.matches.isEmpty,
                    "\(action.id) has match rules, which makes it a tier-2 action offered by screen content")
            // Labels are the key, not a description of what any agent will do with it.
            #expect(action.label.count <= 6, "\(action.id) has a prose label: \(action.label)")
        }

        let labels = QuickActionPalette.tier1.map(\.label).joined(separator: " ").lowercased()
        for word in ["claude", "codex", "copilot", "agent", "approve", "permission", "allow"] {
            #expect(!labels.contains(word),
                    "the palette names \(word.debugDescription), so an upstream rename breaks it")
        }
    }

    /// The keystrokes have to be the bytes a real terminal sends, or a tap does
    /// something subtly different from typing — which is worse than not offering it.
    @Test("Each action sends exactly what the key itself would send")
    func keystrokesAreFaithful() {
        func sends(_ id: String) -> [UInt8]? {
            QuickActionPalette.tier1.first { $0.id == id }?.sends
        }
        #expect(sends("yes") == [0x79])          // 'y'
        #expect(sends("no") == [0x6E])           // 'n'
        #expect(sends("option-1") == [0x31])     // '1'
        #expect(sends("option-2") == [0x32])
        #expect(sends("option-3") == [0x33])
        #expect(sends("escape") == [0x1B])       // ESC
        #expect(sends("interrupt") == [0x03])    // ETX, what Ctrl-C sends

        // CR, not LF. A PTY in canonical mode expects carriage return from the
        // terminal and translates it; sending 0x0A submits nothing in some programs
        // and a stray blank line in others.
        #expect(sends("enter") == [0x0D], "Enter must send CR (0x0D), not LF (0x0A)")
    }

    @Test("Action ids are unique, or a tap is ambiguous")
    func idsAreUnique() {
        let ids = QuickActionPalette.tier1.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate ids in \(ids)")
        #expect(QuickActionPalette.isTier1("yes"))
        #expect(!QuickActionPalette.isTier1("some-profile-action"))
    }

    // MARK: - The gate

    @Test("The palette is offered while the agent is waiting")
    func offeredWhenWaiting() async {
        let session = await Self.session(status: .waiting)
        #expect(await session.availableQuickActions.count == QuickActionPalette.tier1.count)
        #expect(await session.isAwaitingInput)
    }

    /// The acceptance criterion, at the API rather than in the UI.
    @Test("No actions are offered in any other status", arguments: [
        AgentEventKind.working, .idle,
    ])
    func notOfferedOtherwise(status: AgentEventKind) async {
        let session = await Self.session(status: status)
        #expect(await session.availableQuickActions.isEmpty,
                "actions offered while \(status.rawValue)")
        #expect(await session.isAwaitingInput == false)
    }

    @Test("Nothing is offered before the daemon has said anything")
    func notOfferedBeforeAnyStatus() async {
        let session = await Self.session(status: nil)
        #expect(await session.availableQuickActions.isEmpty,
                "the palette appeared on an unknown status — 'we do not know' is not 'waiting'")
    }

    /// A tap that arrives after the agent has moved on must fail rather than land.
    ///
    /// This is the case a hidden button does not cover: the view was right when the
    /// user tapped, and wrong by the time the tap arrived.
    @Test("A late tap is refused rather than injected into a working agent")
    func lateTapIsRefused() async throws {
        let session = await Self.session(status: .waiting)
        // The agent stops waiting — the user's thumb is already moving.
        _ = await session.handle(
            .control(.agentEvent(kind: .working, agentID: nil, detail: nil))
        )

        await #expect(throws: MeshyySession.QuickActionError.notAwaitingInput(status: "working")) {
            try await session.performTier1Action(id: "yes")
        }
    }

    @Test("An unknown action id is refused, not guessed")
    func unknownActionRefused() async throws {
        let session = await Self.session(status: .waiting)
        await #expect(throws: MeshyySession.QuickActionError.unknownAction(id: "rm-rf")) {
            try await session.performTier1Action(id: "rm-rf")
        }
    }

    /// Profile-declared actions are no less a one-tap send into a live PTY, so they
    /// carry the same gate. Tested separately because they take a different path.
    @Test("A profile-declared action is gated too")
    func profileActionIsGated() async throws {
        let profile = AgentProfile(
            id: "test", displayName: "Test", detectionMarkers: [],
            quickActions: [
                QuickActionDefinition(id: "custom", label: "C", matches: [], sends: [0x63]),
            ]
        )
        let session = await Self.session(status: .working)
        await #expect(throws: MeshyySession.QuickActionError.notAwaitingInput(status: "working")) {
            try await session.performQuickAction(id: "custom", from: [profile])
        }
    }

    /// A status from before a disconnect is a guess: the agent may have finished while
    /// the client was away. Hiding the palette costs a keyboard tap; showing a stale
    /// one sends a keystroke into a running agent.
    @Test("Reattaching clears a stale waiting status")
    func attachClearsStaleStatus() async {
        let session = await Self.session(status: .waiting)
        #expect(await session.isAwaitingInput)

        await session.resetForAttach(resumeFrom: nil)
        #expect(await session.availableQuickActions.isEmpty,
                "the palette survived a reattach on a status the daemon has not re-stated")
    }
}
