// meshyy — CLI front end for the chaos proxies.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Usage:
//   meshyy-chaos tcp --target 127.0.0.1:22 --rtt 80 [--listen 0] [--jitter 0]
//                    [--sever 300]
//   meshyy-chaos udp --target 127.0.0.1:4433 --rtt 80 [--listen 0] [--jitter 0]
//                    [--loss 0.05] [--reorder 0.02] [--seed N] [--sever 300]
//
// Prints the bound port on the first line of stdout, then runs until killed.
// The benchmark script reads that line to know where to point ssh.
//
// TCP and UDP both, deliberately. The brief for 1d-bis says to replace the TCP shim
// with a UDP relay, and for impairing QUIC that is exactly right — but the §1
// benchmark measures SSH, and SSH does not run over a UDP relay. Deleting the TCP
// proxy would destroy the reproduction of the one measurement the whole project is
// justified by. So: UDP for QUIC, TCP for the SSH baseline it is compared against.

import Foundation
import MeshyyChaos

@main
enum ChaosCLI {
    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())

        guard let mode = arguments.first, mode == "tcp" || mode == "udp" else {
            die("""
                usage: meshyy-chaos tcp --target HOST:PORT --rtt MS \
                [--listen PORT] [--jitter MS] [--sever SECONDS]
                       meshyy-chaos udp --target HOST:PORT --rtt MS \
                [--listen PORT] [--jitter MS] [--loss 0..1] [--reorder 0..1] \
                [--seed N] [--sever SECONDS]
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

        let listenPort = UInt16(intOption("listen", default: 0))
        let host = String(pieces[0])

        let bound: UInt16
        do {
            if mode == "udp" {
                // Loss and reordering are datagram operations. Dropping bytes out of a
                // TCP stream would corrupt it rather than emulate a lossy network, which
                // is why these are UDP-only rather than merely unimplemented for TCP.
                profile.loss = doubleOption("loss", default: 0)
                profile.reorder = doubleOption("reorder", default: 0)
                if let seed = option("seed").flatMap(UInt64.init) { profile.seed = seed }
                let proxy = ChaosUDPProxy(
                    listenPort: listenPort, targetHost: host,
                    targetPort: targetPort, profile: profile
                )
                bound = try proxy.start()
                held = proxy
            } else {
                let proxy = ChaosTCPProxy(
                    listenPort: listenPort, targetHost: host,
                    targetPort: targetPort, profile: profile
                )
                bound = try proxy.start()
                held = proxy
            }
            print(bound)
            fflush(stdout)
        } catch {
            die("\(error)")
        }

        // Dispatch sources rather than `signal(SIGINT) { _ in exit(0) }`. Calling
        // `exit` from a C signal handler runs the process's atexit handlers on an
        // interrupt context, and the Swift runtime traps: both modes exited -5 (SIGTRAP)
        // on a plain SIGTERM. Harmless while a human is killing it by hand, and not
        // harmless at all for a script that checks the exit status.
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)   // or the default disposition kills us first
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { exit(0) }
            source.resume()
            signalSources.append(source)
        }
        dispatchMain()
    }

    /// Keeps the running proxy alive for the process's lifetime. Without a strong
    /// reference the relay is deallocated the moment `main` stops using it, and the
    /// process sits in `dispatchMain()` forwarding nothing.
    nonisolated(unsafe) private static var held: AnyObject?

    /// Signal sources must outlive `main`, or they are cancelled on deallocation and
    /// the process becomes unkillable by anything but SIGKILL.
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    static func doubleOption(_ name: String, default defaultValue: Double) -> Double {
        guard let index = CommandLine.arguments.firstIndex(of: "--\(name)"),
              index + 1 < CommandLine.arguments.count
        else { return defaultValue }
        guard let parsed = Double(CommandLine.arguments[index + 1]) else {
            die("--\(name) must be a number, got \(CommandLine.arguments[index + 1])")
        }
        return parsed
    }

    static func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data("meshyy-chaos: \(message)\n".utf8))
        exit(2)
    }
}
