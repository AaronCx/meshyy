// meshyy — meshyyd entry point.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
//   meshyyd serve [--socket PATH] [--shell PATH] [--buffer BYTES]
//   meshyyd attach [--session NAME] [--socket PATH]
//   meshyyd list [--socket PATH]
//   meshyyd version
//
// `attach` is a client, not a server: it connects to a running `serve` over the
// unix socket. That is design doc M1's acceptance criterion — `meshyyd attach`
// gives a working local shell — and it exercises the real framing and the real
// control frames rather than a shortcut.

import Darwin
import Foundation
import MeshyyCore
import MeshyyDaemon

@main
enum MeshyydCLI {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "help"
        if !arguments.isEmpty { arguments.removeFirst() }

        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: "--\(name)"),
                  index + 1 < arguments.count
            else { return nil }
            return arguments[index + 1]
        }
        let socketPath = option("socket") ?? LocalSocketServer.defaultSocketPath

        switch command {
        case "bootstrap":
            // What the SSH exec channel runs: `meshyyd attach --session X --json`
            // is routed here by the `--json` flag below. Kept as a separate verb
            // too so it can be exercised directly.
            await Bootstrap.run(socketPath: socketPath, session: option("session") ?? "default")
        case "serve":
            await serve(
                socketPath: socketPath,
                shell: option("shell"),
                buffer: option("buffer").flatMap(Int.init),
                allInterfaces: arguments.contains("--all-interfaces")
            )
        case "attach":
            // Design doc §5.1 step 2: the client runs
            // `meshyyd attach --session <name> --json` over an SSH exec channel and
            // expects the bootstrap JSON on stdout. Without --json it is the
            // interactive local attach from M1.
            if arguments.contains("--json") {
                await Bootstrap.run(
                    socketPath: socketPath,
                    session: option("session") ?? "default"
                )
            } else {
                await AttachClient(
                    socketPath: socketPath,
                    session: option("session") ?? "default"
                ).run()
            }
        case "list":
            await AttachClient(socketPath: socketPath, session: "").list()
        case "kill":
            // `meshyyd kill NAME` — end a session and the shell behind it. Without
            // this, a session a client stops attaching to runs forever, and orphans
            // accumulate into a pile that degrades the live ones: a multiplexer sizes
            // itself to its smallest attached client, so one stale attachment clamps
            // the terminal for every other.
            // `arguments` has already had the verb removed (line 24), so the name is
            // the first remaining non-flag — dropping another element ate it.
            let names = arguments.filter { !$0.hasPrefix("--") }
            guard let name = names.first else {
                FileHandle.standardError.write(Data("usage: meshyyd kill NAME\n".utf8))
                exit(2)
            }
            await AttachClient(socketPath: socketPath, session: name).kill()
        case "version":
            print("meshyyd \(Meshyy.version) (protocol \(Meshyy.protocolVersion))")
        default:
            print("""
                meshyyd \(Meshyy.version)

                  serve     [--socket PATH] [--shell PATH] [--buffer BYTES] [--all-interfaces]
                  attach    [--session NAME] [--socket PATH] [--json]
                  bootstrap [--session NAME] [--socket PATH]
                  list      [--socket PATH]
                  kill      NAME [--socket PATH]
                  version

                `attach --json` and `bootstrap` are what an SSH exec channel runs:
                they print the design doc §5.1 handshake and exit.
                """)
            exit(command == "help" ? 0 : 2)
        }
    }

    private static func serve(
        socketPath: String,
        shell: String?,
        buffer: Int?,
        allInterfaces: Bool
    ) async {
        var config = DaemonConfig()
        if let shell { config.shell = shell }
        if let buffer { config.bufferCapacity = buffer }
        config.bindAllInterfaces = allInterfaces

        // Design doc §9: meshyy ships NO endpoint. Notifications exist only if the
        // user wrote ~/.meshyy/notify.json.
        let notifyConfig = NotifyConfig.load()
        let notifier = notifyConfig.map { _ in AgentNotifier() }
        let store = SessionStore(config: config, notifier: notifier)
        let tokens = TokenActor()
        let server = LocalSocketServer(path: socketPath, store: store, tokens: tokens)
        do {
            try server.start()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }

        // QUIC listener (design doc §5.2). Failing to start it is not fatal: the
        // local socket still works, and saying so beats refusing to run at all.
        var quicPort: UInt16 = 0
        var quicFingerprint = ""
        do {
            let identity = try DaemonIdentity.loadOrCreate()
            let quic = QUICServer(
                identity: identity,
                store: store,
                tokens: tokens,
                bindAllInterfaces: config.bindAllInterfaces
            )
            quicPort = try quic.start()
            quicFingerprint = identity.fingerprint
            server.attachQUIC(quic, fingerprint: identity.fingerprint)
        } catch {
            FileHandle.standardError.write(Data(
                "meshyyd: QUIC listener unavailable (\(error)); local socket only\n".utf8
            ))
        }

        // Design doc §9: logs are opt-in, local, and redact PTY content. These
        // lines carry no session content — a path, a shell, a buffer size.
        print("meshyyd \(Meshyy.version) listening on \(socketPath)")
        print("shell: \(config.shell) \(config.shellArguments.joined(separator: " "))")
        print("ring buffer: \(config.bufferCapacity) bytes per session")
        print("agents: \(config.agentProfiles.map(\.id).joined(separator: ", "))")
        // The endpoint itself is never printed: it may carry a token in its path or
        // headers, and design doc §9 keeps secrets out of logs.
        print("notifications: \(notifyConfig == nil ? "off (no ~/.meshyy/notify.json)" : "configured")")
        if quicPort != 0 {
            print("quic: port \(quicPort) cert-sha256 \(quicFingerprint)")
            if config.bindAllInterfaces {
                // Design doc §8 requires an explicit flag AND a startup warning.
                print("WARNING: bound to all interfaces. Anyone who can reach this "
                    + "port can attempt a handshake; only a valid single-use token "
                    + "gets a session, but prefer loopback or Tailscale.")
            }
        }
        fflush(stdout)

        // A dead session still holds its ring buffer, so sweep periodically or a
        // daemon left running for weeks accumulates them.
        Task {
            while true {
                try? await Task.sleep(for: .seconds(60))
                await store.reapDead()
            }
        }

        // SIGTERM from launchd must tear sessions down rather than orphaning the
        // shells they spawned.
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler {
            Task {
                await store.closeAll()
                server.stop()
                exit(0)
            }
        }
        termination.resume()
        signal(SIGTERM, SIG_IGN)

        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler {
            Task {
                await store.closeAll()
                server.stop()
                exit(0)
            }
        }
        interrupt.resume()
        signal(SIGINT, SIG_IGN)

        // Park forever; every path above is event-driven.
        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }
}
