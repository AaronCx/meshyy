// meshyy — CLI front end for the chaos proxies.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Usage:
//   meshyy-chaos tcp --target 127.0.0.1:22 --rtt 80 [--listen 0] [--jitter 0]
//                    [--sever 300]
//
// Prints the bound port on the first line of stdout, then runs until killed.
// The benchmark script reads that line to know where to point ssh.

import Foundation
import MeshyyChaos

@main
enum ChaosCLI {
    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())

        guard arguments.first == "tcp" else {
            die("""
                usage: meshyy-chaos tcp --target HOST:PORT --rtt MS \
                [--listen PORT] [--jitter MS] [--sever SECONDS]
                """)
        }
        arguments.removeFirst()

        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: "--\(name)"),
                  index + 1 < arguments.count
            else { return nil }
            return arguments[index + 1]
        }

        func intOption(_ name: String, default defaultValue: Int) -> Int {
            guard let raw = option(name) else { return defaultValue }
            guard let parsed = Int(raw) else {
                die("--\(name) must be an integer, got \(raw)")
            }
            return parsed
        }

        guard let target = option("target") else { die("--target HOST:PORT is required") }
        let pieces = target.split(separator: ":")
        guard pieces.count == 2, let targetPort = UInt16(pieces[1]) else {
            die("--target must be HOST:PORT, got \(target)")
        }

        var profile = ChaosProfile.rtt(intOption("rtt", default: 0))
        profile.jitter = .milliseconds(intOption("jitter", default: 0))
        if let sever = option("sever").flatMap(Double.init) {
            profile.severAfter = .milliseconds(Int(sever * 1000))
        }

        let proxy = ChaosTCPProxy(
            listenPort: UInt16(intOption("listen", default: 0)),
            targetHost: String(pieces[0]),
            targetPort: targetPort,
            profile: profile
        )

        do {
            print(try proxy.start())
            fflush(stdout)
        } catch {
            die("\(error)")
        }

        signal(SIGINT) { _ in exit(0) }
        signal(SIGTERM) { _ in exit(0) }
        dispatchMain()
    }

    static func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data("meshyy-chaos: \(message)\n".utf8))
        exit(2)
    }
}
