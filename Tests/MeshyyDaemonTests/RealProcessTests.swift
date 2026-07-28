// meshyy — which suites need a real process or a real socket.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.

import Foundation
import Testing

/// Gate for suites that spawn a real shell, own a real PTY, or bind a real socket.
///
/// Set by `make test`; unset in CI. The reason is worth stating rather than hiding
/// behind a flag.
///
/// These suites assert on a real shell echoing through a real PTY. That is what
/// makes them worth having — they caught the ENOTTY-before-slave-open behaviour, the
/// inherited SIG_IGN that leaked processes, the discarded output at child exit, the
/// SIGPIPE that would have killed the daemon, and the unordered writes that could
/// scramble input. None of those were reachable without a real process.
///
/// It is also what makes them unusable as a CI gate on a shared two-core runner.
/// Across several runs a different test timed out each time, while the same suites
/// passed repeatedly here in 13 s. Raising ceilings to 30 s, reordering the event
/// consumer (which made CI hang outright), and serialising the suites each moved the
/// failure rather than removing it. The next step would have been loosening
/// assertions until CI agreed, which weakens the tests precisely where their value
/// is.
///
/// So CI gates the deterministic suites — the §6.4 property test over 200 seeded
/// scenarios, CBOR, control frames and golden fixtures, the screen scanner, agent
/// activity and quick-action matching, the notifier, DER/X.509 — and `make check`
/// covers these before a push.
///
/// Recorded as debt in docs/qa/known-debt.md, with a self-hosted runner as the fix:
/// the tests are stable on this machine, so the runner is the variable.
enum RealProcessTests {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MESHYY_INTEGRATION_TESTS"] == "1"
    }

    static let reason: Comment =
        "set MESHYY_INTEGRATION_TESTS=1 (make test does) — spawns a real shell/PTY/socket"
}
