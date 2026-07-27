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
        case "serve":
            await serve(
                socketPath: socketPath,
                shell: option("shell"),
                buffer: option("buffer").flatMap(Int.init)
            )
        case "attach":
            await AttachClient(
                socketPath: socketPath,
                session: option("session") ?? "default"
            ).run()
        case "list":
            await AttachClient(socketPath: socketPath, session: "").list()
        case "version":
            print("meshyyd \(Meshyy.version) (protocol \(Meshyy.protocolVersion))")
        default:
            print("""
                meshyyd \(Meshyy.version)

                  serve   [--socket PATH] [--shell PATH] [--buffer BYTES]
                  attach  [--session NAME] [--socket PATH]
                  list    [--socket PATH]
                  version
                """)
            exit(command == "help" ? 0 : 2)
        }
    }

    private static func serve(socketPath: String, shell: String?, buffer: Int?) async {
        var config = DaemonConfig()
        if let shell { config.shell = shell }
        if let buffer { config.bufferCapacity = buffer }

        let store = SessionStore(config: config)
        let server = LocalSocketServer(path: socketPath, store: store)
        do {
            try server.start()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }

        // Design doc §9: logs are opt-in, local, and redact PTY content. These
        // lines carry no session content — a path, a shell, a buffer size.
        print("meshyyd \(Meshyy.version) listening on \(socketPath)")
        print("shell: \(config.shell) \(config.shellArguments.joined(separator: " "))")
        print("ring buffer: \(config.bufferCapacity) bytes per session")
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
