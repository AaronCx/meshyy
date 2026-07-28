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
    public func attachOrCreate(
        name: String,
        size: TerminalSize
    ) async throws -> PTYSession {
        guard Self.isValidName(name) else { throw StoreError.nameRejected(name) }

        if let existing = sessions[name] {
            if await existing.isAlive { return existing }
            // The child died while nobody was attached. Replace it rather than
            // handing back a corpse — but only after its buffer has been read by
            // anyone still listening, which `close` handles.
            await existing.close()
            sessions.removeValue(forKey: name)
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
            let (_, events, _) = await session.attach(resumeFrom: session.info.bufferedTo)
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
        guard let session = sessions.removeValue(forKey: name) else {
            throw StoreError.noSuchSession(name)
        }
        notifyTasks.removeValue(forKey: name)?.cancel()
        await session.close()
    }

    public func closeAll() async {
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
