// meshyy — the line-discipline facts prediction is gated on (design doc §7.1).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.

import Foundation

/// What the kernel's line discipline is doing on the PTY, as read by the daemon
/// with `tcgetattr` rather than inferred from the output stream.
///
/// This is the whole point of owning both ends. The client does not guess
/// whether a keystroke will be echoed; it is told.
public struct TermiosState: Sendable, Equatable {
    /// `ECHO` in `c_lflag`. The kernel will echo the character, so predicting it
    /// is safe.
    public var echo: Bool
    /// `ICANON` in `c_lflag`. Input is line-buffered, so the cursor advances
    /// predictably.
    public var icanon: Bool
    /// Neither `ECHO` nor `ICANON`: the application owns input. Prediction is
    /// unsafe. Stored rather than derived so a future daemon can report raw for
    /// a reason the client's flag pair cannot express.
    public var raw: Bool

    public init(echo: Bool, icanon: Bool, raw: Bool) {
        self.echo = echo
        self.icanon = icanon
        self.raw = raw
    }

    /// A freshly opened PTY: cooked mode, echo on. What a shell sees at a prompt.
    public static let cooked = TermiosState(echo: true, icanon: true, raw: false)
    /// What an agent TUI sets. Design doc §7.3: this is the common case, and
    /// prediction is correctly off here.
    public static let rawMode = TermiosState(echo: false, icanon: false, raw: true)
}

/// Everything the client needs to decide whether predicting a keystroke is safe.
///
/// Design doc §7.2 requires *all* of: echo, icanon, not alt-screen, and an RTT
/// above the threshold. Keeping the decision in one place in `MeshyyCore` means
/// the daemon and the client cannot drift on what "safe" means.
public struct PredictionGate: Sendable, Equatable {
    public var termios: TermiosState
    public var altScreen: Bool
    /// Smoothed round-trip time. Below the threshold prediction is invisible and
    /// only adds risk (design doc §7.2).
    public var smoothedRTT: Duration
    public var threshold: Duration

    public init(
        termios: TermiosState = .cooked,
        altScreen: Bool = false,
        smoothedRTT: Duration = .zero,
        threshold: Duration = .milliseconds(120)
    ) {
        self.termios = termios
        self.altScreen = altScreen
        self.smoothedRTT = smoothedRTT
        self.threshold = threshold
    }

    public var shouldPredict: Bool {
        termios.echo && termios.icanon && !termios.raw && !altScreen && smoothedRTT > threshold
    }

    /// Why prediction is off, for the "fail visible" requirement in design doc
    /// §3.5 — a user asking "why is there no local echo" gets an answer.
    public var reasonPredictionIsOff: String? {
        if !termios.echo { return "remote echo is off" }
        if !termios.icanon { return "the application is reading raw input" }
        if termios.raw { return "the terminal is in raw mode" }
        if altScreen { return "an alternate-screen application is running" }
        if smoothedRTT <= threshold {
            return "round-trip time \(smoothedRTT.milliseconds)ms is below the "
                + "\(threshold.milliseconds)ms threshold"
        }
        return nil
    }
}

extension Duration {
    /// Whole milliseconds, for log lines and user-facing explanations.
    public var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }

    /// Seconds as a `TimeInterval`, for the Dispatch and Foundation APIs that
    /// still take one.
    ///
    /// Deliberately not named `seconds`: that collides with the static
    /// `Duration.seconds(_:)` factory and the compiler rejects the member on an
    /// instance with a confusing message.
    public var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
