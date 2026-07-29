// meshyy — the daemon's set of live sessions.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.

import Darwin
import Foundation
import MeshyyCore

/// How the daemon spawns a shell and how much it remembers.
public struct DaemonConfig: Sendable {
    public var shell: String
    public var shellArguments: [String]
    public var environment: [String: String]
    public var bufferCapacity: Int
    /// Design doc §8: loopback or the Tailscale interface by default. Binding
    /// every interface takes an explicit flag and a startup warning.
    public var bindAllInterfaces: Bool
    /// Agents the daemon can recognise, and what each can answer in one tap.
    ///
    /// Design doc §4 keeps agent identity as DATA: the daemon is handed candidate
    /// profiles and never names one itself, so supporting a new agent is a profile
    /// entry rather than a code change.
    public var agentProfiles: [AgentProfile]
    /// Put the PTY in raw mode before the child starts, so the session is a
    /// transparent byte pipe. See `deterministicEcho`.
    public var rawMode: Bool

    public init(
        shell: String = DaemonConfig.defaultShell,
        shellArguments: [String] = ["-l"],
        environment: [String: String] = DaemonConfig.defaultEnvironment,
        bufferCapacity: Int = RingBuffer.defaultCapacity,
        bindAllInterfaces: Bool = false,
        agentProfiles: [AgentProfile] = DaemonConfig.defaultAgentProfiles,
        rawMode: Bool = false
    ) {
        self.shell = shell
        self.shellArguments = shellArguments
        self.environment = environment
        self.bufferCapacity = bufferCapacity
        self.bindAllInterfaces = bindAllInterfaces
        self.agentProfiles = agentProfiles
        self.rawMode = rawMode
    }

    /// A session whose child is a pure byte pipe: whatever is written to the PTY
    /// comes back byte for byte, with no prompt, no echo and no line editing.
    ///
    /// `stty raw -echo` then `exec cat`. Intended for tests whose subject is the
    /// **transport** rather than the shell. An interactive shell is the wrong
    /// instrument there for two reasons, both of which bit this project:
    ///
    ///  * Its timing is not ours. Prompt, readline and job control make "did the
    ///    bytes arrive" depend on how loaded the machine is, which turned a 13 s
    ///    local suite into four different CI failures.
    ///  * Its output is not exact. Assertions had to look for a marker *substring*,
    ///    and `docs/qa/mutation-log.md` records a duplicating mutant that slipped
    ///    past a test whose stated job was "no duplicates" because the duplication
    ///    did not overlap the marker.
    ///
    /// With a byte pipe an assertion can be `received == sent`, which is both
    /// deterministic and strictly stronger.
    ///
    /// ONE CONSTRAINT a caller must respect, measured rather than assumed:
    /// **send printable ASCII only.** Even in raw mode a PTY is not transparent to
    /// arbitrary bytes — flow-control and signal characters are consumed by the line
    /// discipline rather than delivered. A first attempt with payloads over 0…250
    /// returned 312 of 700 bytes, with a `^\` in the stream and a duplicated run.
    /// Restricting to 0x20…0x7E keeps the pipe exact.
    public static func deterministicEcho(
        bufferCapacity: Int = RingBuffer.defaultCapacity
    ) -> DaemonConfig {
        DaemonConfig(
            // `cat` directly — no shell, no `stty`, one process per session. Raw mode
            // is applied to the PTY before the child starts, so there is no cooked
            // window and no readiness handshake to wait for.
            shell: "/bin/cat",
            shellArguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            bufferCapacity: bufferCapacity,
            // No agent profiles: the burst/quiet heuristic and quick-action matching
            // have their own deterministic tests and would only add noise here.
            agentProfiles: [],
            rawMode: true
        )
    }

    /// Ships with Claude Code and a generic fallback.
    ///
    /// The markers are strings the agent puts on screen, observed as a black box.
    /// The quick actions' `matches` are deliberately narrow: §7.4 warns that a
    /// loose match offers a button at the wrong moment, which is worse than
    /// offering none, so each requires the prompt text AND its specific option.
    public static var defaultAgentProfiles: [AgentProfile] {
        [
            AgentProfile(
                id: "claude-code",
                displayName: "Claude Code",
                detectionMarkers: ["esc to interrupt", "claude code"],
                quickActions: [
                    QuickActionDefinition(
                        id: "approve-once",
                        label: "Yes",
                        matches: ["do you want", "1. yes"],
                        sends: Array("1\r".utf8)
                    ),
                    QuickActionDefinition(
                        id: "approve-always",
                        label: "Yes, always",
                        matches: ["do you want", "2. yes, and don't ask again"],
                        sends: Array("2\r".utf8)
                    ),
                    QuickActionDefinition(
                        id: "deny",
                        label: "No",
                        // The escape key is what Claude Code itself documents on
                        // screen, so this is the same keystroke a user would send.
                        matches: ["do you want", "no, and tell claude"],
                        sends: Array("\u{1B}".utf8)
                    ),
                ]
            ),
            // Empty markers: the burst/quiet heuristic runs from the start and
            // reports status for ANY agent, with no name claimed.
            AgentProfile.generic,
        ]
    }

    public static var defaultShell: String {
        // The user's login shell, or sh. Read from the password database rather
        // than $SHELL, because a daemon under launchd has no useful environment.
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            return String(cString: shell)
        }
        return "/bin/sh"
    }

    /// A deliberately small environment. The daemon does not inherit launchd's,
    /// and TERM must be something a modern emulator recognises or full-screen
    /// programs degrade silently.
    public static var defaultEnvironment: [String: String] {
        var environment: [String: String] = [
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "MESHYY": Meshyy.version,
        ]
        if let entry = getpwuid(getuid()), let name = entry.pointee.pw_name {
            environment["USER"] = String(cString: name)
            environment["LOGNAME"] = String(cString: name)
        }
        return environment
    }
}

/// Named sessions, created on demand.
public actor SessionStore {
    public enum StoreError: Error, CustomStringConvertible {
        case nameRejected(String)
        case noSuchSession(String)

        public var description: String {
            switch self {
            case .nameRejected(let name):
                "meshyyd: session name \(name.debugDescription) is not allowed"
            case .noSuchSession(let name):
                "meshyyd: no session named \(name.debugDescription)"
            }
        }
    }

    private var sessions: [String: PTYSession] = [:]
    private let config: DaemonConfig
    private let notifier: AgentNotifier?
    /// One watcher per session, translating agent events into notifications.
    private var notifyTasks: [String: Task<Void, Never>] = [:]
    /// Names an in-flight group allocation has claimed but not yet created.
    ///
    /// `attachOrCreate` awaits (child spawn, notifier attach), and an actor is
    /// re-entrant across awaits — so two concurrent allocations could both read the
    /// same table, both conclude slot 2 is free, and one would silently ATTACH to the
    /// other's brand-new session, which is precisely the bug group allocation exists
    /// to end. The claim happens synchronously, before any await, so it cannot race.
    private var reservedNames: Set<String> = []
    /// Creations in flight, by name. The claim `attachOrCreate` itself takes: the
    /// nil-check and the table insert sit on opposite sides of the child-spawn
    /// suspension, so without this two concurrent attaches to one fresh name both
    /// passed the check and both spawned — eight racing callers produced eight
    /// shells for one name, seven of them orphaned outside the table where list,
    /// kill and the reaper could never reach them. Losers now await the winner.
    private var creating: [String: Task<PTYSession, Error>] = [:]

    public init(config: DaemonConfig = DaemonConfig(), notifier: AgentNotifier? = nil) {
        self.config = config
        self.notifier = notifier
    }

    /// Session names reach log lines and, on a Linux port, could reach a path.
    /// Restricting them here rather than at every use site means there is one
    /// place to be right.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty
            && name.count <= 64
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
            && name != "." && name != ".."
    }

    /// Returns the named session, creating it if absent. This is what `attach`
    /// wants: a user who attaches to a name they have not used before expects a
    /// shell, not an error.
    ///
    /// Concurrent callers for one name get ONE session: the first becomes the
    /// claimant (see `creating`), the rest await its outcome. Two clients
    /// attaching to the same name sharing a shell is the two-clients-one-session
    /// feature working; two shells for one name is the orphan factory this
    /// structure exists to close.
    public func attachOrCreate(
        name: String,
        size: TerminalSize
    ) async throws -> PTYSession {
        guard Self.isValidName(name) else { throw StoreError.nameRejected(name) }

        while true {
            if let inFlight = creating[name] {
                // A claimant is mid-creation. Await it; on its failure, loop and
                // try to become the claimant ourselves (bounded: each pass either
                // returns, claims, or awaits a task that is already running).
                if let session = try? await inFlight.value { return session }
                continue
            }
            if let existing = sessions[name] {
                if await existing.isAlive { return existing }
                // The child died. Fall through to the claimed replace-and-create;
                // the corpse is dealt with inside the claim so that its close —
                // an await — cannot open a second replacement window.
            }
            break
        }

        let task = Task { try await self.replaceAndCreate(name: name, size: size) }
        creating[name] = task
        defer { creating[name] = nil }
        return try await task.value
    }

    /// The creation itself, only ever reached through a `creating` claim.
    private func replaceAndCreate(
        name: String,
        size: TerminalSize
    ) async throws -> PTYSession {
        if let corpse = sessions.removeValue(forKey: name) {
            // Removed from the table BEFORE the awaited close, so no interleaved
            // reader can return the corpse; `close` still drains its buffer to
            // anyone listening.
            notifyTasks.removeValue(forKey: name)?.cancel()
            await corpse.close()
        }

        let session = try PTYSession(
            name: name,
            executable: config.shell,
            arguments: config.shellArguments,
            environment: config.environment,
            size: size,
            bufferCapacity: config.bufferCapacity,
            agentProfiles: config.agentProfiles,
            rawMode: config.rawMode
        )
        await session.start()
        sessions[name] = session

        // M5: watch this session's agent status so a permission prompt can reach the
        // phone. A separate subscription rather than piggybacking on a client's,
        // because the whole point is to fire when NO client is attached.
        if let notifier {
            // An OBSERVER, not a client: this subscription lives as long as the session
            // does, and counting it would make every session read as attached forever —
            // exactly the truth `SessionInfo.attachedClients` exists to report.
            let (_, events, _) = await session.attach(
                resumeFrom: session.info.bufferedTo,
                observer: true
            )
            notifyTasks[name] = Task { [name] in
                for await event in events {
                    guard case .agent(let kind, _, let detail) = event else { continue }
                    await notifier.agentStatusChanged(
                        session: name,
                        kind: kind,
                        agentName: detail
                    )
                }
            }
        }
        return session
    }

    public func session(named name: String) -> PTYSession? {
        sessions[name]
    }

    /// Creates the lowest-numbered free session in a numeric group — `prefix0`,
    /// `prefix1`, … — and returns it. THE daemon-side answer to "give me a NEW
    /// session on this server": the table consulted and the slot claimed are the
    /// same table, in the same isolation, so two racing clients get two sessions
    /// and nobody is ever handed a shell that already belonged to someone.
    ///
    /// Gaps are reused (0 and 2 alive → 1), matching how a user thinks about tab
    /// positions rather than growing forever.
    public func createLowestFree(
        inGroup prefix: String,
        size: TerminalSize
    ) async throws -> PTYSession {
        // Synchronous from read to claim — see `reservedNames`. `creating` counts
        // as taken too: a NAMED attach mid-creation owns its slot just as surely
        // as a finished one.
        var slot = 0
        var name = prefix + String(slot)
        while sessions[name] != nil || reservedNames.contains(name) || creating[name] != nil {
            slot += 1
            name = prefix + String(slot)
        }
        guard Self.isValidName(name) else { throw StoreError.nameRejected(name) }
        reservedNames.insert(name)
        defer { reservedNames.remove(name) }
        return try await attachOrCreate(name: name, size: size)
    }

    /// Looks a session up by its 128-bit id rather than its name.
    ///
    /// This is what the QUIC path uses: design doc §5.1 binds the bootstrap token
    /// to a session *id*, so the id is what the daemon is entitled to act on. A
    /// name-based lookup there would let any valid token reach any session.
    public func session(withID sessionID: String) async -> PTYSession? {
        for session in sessions.values where session.sessionID == sessionID {
            return session
        }
        return nil
    }

    public func list() async -> [SessionInfo] {
        var infos: [SessionInfo] = []
        for session in sessions.values {
            infos.append(await session.info)
        }
        return infos.sorted { $0.name < $1.name }
    }

    public func close(name: String) async throws {
        // A creation in flight for this name finishes first, so the close acts on
        // the session it produced instead of missing it by a few milliseconds.
        if let inFlight = creating[name] { _ = try? await inFlight.value }
        guard let session = sessions.removeValue(forKey: name) else {
            throw StoreError.noSuchSession(name)
        }
        notifyTasks.removeValue(forKey: name)?.cancel()
        await session.close()
    }

    public func closeAll() async {
        // Same reasoning as `close(name:)`: let in-flight creations land in the
        // table so this sweep actually sweeps them.
        for task in creating.values { _ = try? await task.value }
        for task in notifyTasks.values { task.cancel() }
        notifyTasks.removeAll()
        for session in sessions.values { await session.close() }
        sessions.removeAll()
    }

    /// Drops sessions whose child has exited and which nobody is attached to.
    /// Called on a timer so a daemon left running for weeks does not accumulate
    /// dead sessions holding their ring buffers.
    public func reapDead() async {
        // `where` clauses cannot await, so the check is inside the body.
        for (name, session) in sessions {
            guard await !session.isAlive else { continue }
            notifyTasks.removeValue(forKey: name)?.cancel()
            await session.close()
            sessions.removeValue(forKey: name)
        }
    }
}
