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

    public init(
        shell: String = DaemonConfig.defaultShell,
        shellArguments: [String] = ["-l"],
        environment: [String: String] = DaemonConfig.defaultEnvironment,
        bufferCapacity: Int = RingBuffer.defaultCapacity,
        bindAllInterfaces: Bool = false
    ) {
        self.shell = shell
        self.shellArguments = shellArguments
        self.environment = environment
        self.bufferCapacity = bufferCapacity
        self.bindAllInterfaces = bindAllInterfaces
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

    public init(config: DaemonConfig = DaemonConfig()) {
        self.config = config
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
            bufferCapacity: config.bufferCapacity
        )
        await session.start()
        sessions[name] = session
        return session
    }

    public func session(named name: String) -> PTYSession? {
        sessions[name]
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
        await session.close()
    }

    public func closeAll() async {
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
            await session.close()
            sessions.removeValue(forKey: name)
        }
    }
}
