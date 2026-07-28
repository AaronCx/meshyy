// meshyy — the fixed tier-1 quick-action palette (M6).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// §7 was rewritten away from predictive echo, and this is what replaced it. The goal
// was never per-keystroke prediction; it was reducing the cost of responding to an
// agent from a phone. M5 already detects that the agent is waiting — that is what
// generates the notification. M6 makes responding one tap instead of summoning a
// keyboard.
//
// TIER 1 IS DELIBERATELY STUPID. No screen parsing, no prompt patterns, no agent
// names. A fixed row of keystrokes offered whenever the agent is waiting. It cannot
// break when an agent's UI changes, because it never looked at the UI.
//
// The milestone amendment is explicit that tier 2 — labelled actions derived from
// declared prompt patterns — must not be built first: "Screen-scraping an alt-screen
// TUI to extract options is exactly the kind of work that feels tractable, demos well
// once, and then breaks silently on the next upstream release." `QuickActionDefinition`
// already carries the `matches` machinery for that, and nothing here uses it.
//
// WHY THESE EIGHT. They are terminal universals, not agent knowledge — the same
// keystrokes a user would type at any prompt in any program written in the last forty
// years. Nothing here encodes what any particular agent asks or how it phrases it,
// which is the acceptance criterion "no agent name and no prompt string is hardcoded
// anywhere in Swift". Enter and Esc accept and dismiss; Ctrl-C interrupts; y and n
// answer the question every prompt asks; 1, 2 and 3 pick from a short list, which is
// what a numbered menu offers regardless of what the options say.

public enum QuickActionPalette {
    /// The tier-1 palette, in the order it should be shown.
    ///
    /// Ordered by expected frequency rather than by keyboard layout: the two that
    /// answer a yes/no permission prompt come first, because that is the interaction
    /// this feature exists for. A row of buttons on a phone is scanned left to right
    /// and the first two are the ones reachable by thumb.
    public static let tier1: [QuickActionDefinition] = [
        action(id: "yes", label: "y", sends: [0x79]),
        action(id: "no", label: "n", sends: [0x6E]),
        action(id: "enter", label: "Enter", sends: [0x0D]),
        action(id: "escape", label: "Esc", sends: [0x1B]),
        action(id: "option-1", label: "1", sends: [0x31]),
        action(id: "option-2", label: "2", sends: [0x32]),
        action(id: "option-3", label: "3", sends: [0x33]),
        // Last, and visually separable by a client: it is the only one that
        // interrupts rather than answers, and a mis-tap costs the agent's work.
        action(id: "interrupt", label: "Ctrl-C", sends: [0x03]),
    ]

    /// Carriage return, not line feed: a PTY in canonical mode expects CR from the
    /// terminal and translates it. Sending LF here would submit nothing in some
    /// programs and a stray blank line in others.
    public static let carriageReturn: UInt8 = 0x0D

    /// `matches` is empty on every tier-1 action, which is what makes it tier 1: an
    /// action with match rules is offered only when the screen says so, and these are
    /// offered whenever the agent is waiting, full stop.
    private static func action(id: String, label: String, sends: [UInt8]) -> QuickActionDefinition {
        QuickActionDefinition(id: id, label: label, matches: [], sends: sends)
    }

    /// True if `id` is part of the fixed palette. Used by the client to tell a
    /// built-in action from a profile-declared one without consulting profiles.
    public static func isTier1(_ id: String) -> Bool {
        tier1.contains { $0.id == id }
    }
}
