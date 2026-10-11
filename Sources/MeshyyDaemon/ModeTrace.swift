// meshyy — a debug-gated record of what the far-side program armed, and when.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Why this exists: every scroll bug a+Terminal shipped under meshyy was the phone's
// emulator believing something about mouse mode or the alternate screen that tmux did
// not. The phone can now record what it believed at each swipe. This is the other half:
// what the pty actually carried, stamped with wall-clock time so the two logs line up.
//
// Metadata only. An entry is a set of mode numbers, a screen flag and a byte offset —
// never pty content (design doc §9). Off unless the daemon is started with
// `--trace-modes` (or MESHYY_TRACE_MODES=1).

import Foundation

/// One observation of the tracked-mode state of a session.
public struct ModeTraceEntry: Sendable, Equatable {
    public enum Source: String, Sendable {
        /// The pty output in one drain armed or disarmed a tracked mode.
        case pty
        /// The pty output entered or left the alternate screen.
        case alt
        /// A client attached and was told this state.
        case attach
    }

    /// Wall-clock time, so it can be compared against the phone's swipe records.
    public var at: Date
    public var source: Source
    /// Every tracked mode set after this observation, sorted.
    public var modes: [Int]
    public var altScreen: Bool
    /// Absolute pty offset at the end of the drain, for lining up against a replay.
    public var offset: UInt64
    /// How many tracked set/reset escapes the drain carried. A tmux redraw pulse is
    /// eight or more; a flip of one mode is one.
    public var flips: Int
    /// Whether the drain passed through "mouse off" on the way to its final state —
    /// a disarm of 1000/1002/1003 or 1006. A drain that ends armed but did this is a
    /// pulse; split across two drains, the same pulse is a window a swipe can die in.
    public var transientMouseOff: Bool

    public init(
        at: Date,
        source: Source,
        modes: [Int],
        altScreen: Bool,
        offset: UInt64,
        flips: Int,
        transientMouseOff: Bool
    ) {
        self.at = at
        self.source = source
        self.modes = modes
        self.altScreen = altScreen
        self.offset = offset
        self.flips = flips
        self.transientMouseOff = transientMouseOff
    }

    /// The `meshyyd list --json` spelling.
    public var jsonObject: [String: Any] {
        [
            "at_ms": Int((at.timeIntervalSince1970 * 1000).rounded()),
            "src": source.rawValue,
            "modes": modes,
            "alt": altScreen,
            "offset": offset,
            "flips": flips,
            "transient_mouse_off": transientMouseOff,
        ]
    }

    /// One line for the daemon's stderr log.
    func logLine(session: String) -> String {
        let ms = Int((at.timeIntervalSince1970 * 1000).rounded())
        let list = modes.map(String.init).joined(separator: ",")
        return "meshyyd: modes \(session) at_ms=\(ms) src=\(source.rawValue) "
            + "modes=[\(list)] alt=\(altScreen) flips=\(flips) "
            + "transient_mouse_off=\(transientMouseOff) offset=\(offset)"
    }
}

/// A bounded, memory-only ring of mode observations for one session.
public struct ModeTraceLog: Sendable, Equatable {
    public static let defaultCapacity = 500

    public let capacity: Int
    public private(set) var entries: [ModeTraceEntry] = []

    public init(capacity: Int = ModeTraceLog.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ entry: ModeTraceEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }
}

/// The mouse-mode escapes whose reset turns an emulator's mouse reporting off.
/// 1006 is here because SwiftTerm resets `mouseMode` on `?1006l` too.
let mouseDisarmingModes: Set<Int> = [1000, 1002, 1003, 1006]
