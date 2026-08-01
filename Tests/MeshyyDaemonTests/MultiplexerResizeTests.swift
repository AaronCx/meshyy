// meshyy — the resize repair, proven against every multiplexer the app supports.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// TmuxResizeTests asks tmux directly what it believes. screen and zellij have no
// equally clean client-size query, so this suite uses the one probe every
// multiplexer answers the same way: `stty size` INSIDE the pane. A multiplexer
// that heard the WINCH resizes its panes; one that missed it leaves the pane at
// the old size — which on screen is the frozen drawing, and everywhere is the
// black space below.
//
// The assertion is on the DELTA, not absolute rows: each multiplexer keeps its
// own constant amount of chrome (status bars, borders), and chrome cancels out
// of a difference.

import Darwin
import Foundation
import Testing
@testable import MeshyyCore
@testable import MeshyyDaemon

/// One multiplexer's start command and external cleanup, isolated per run so the
/// tests can never touch a real session on this machine.
struct MuxSpec: CustomStringConvertible, Sendable {
    let name: String
    let executable: String
    /// Shell line that starts (or attaches) an isolated instance named `id`.
    let start: @Sendable (String) -> String
    /// Commands run OUTSIDE the session to tear the instance down.
    let cleanup: @Sendable (String) -> [[String]]

    var description: String { name }

    static let screen = MuxSpec(
        name: "screen",
        executable: "/usr/bin/screen",
        start: { id in "/usr/bin/screen -S \(id)" },
        cleanup: { id in [["/usr/bin/screen", "-S", id, "-X", "quit"]] }
    )

    static let zellij = MuxSpec(
        name: "zellij",
        executable: "/opt/homebrew/bin/zellij",
        start: { id in "/opt/homebrew/bin/zellij attach --create \(id)" },
        cleanup: { id in
            [["/opt/homebrew/bin/zellij", "kill-session", id],
             ["/opt/homebrew/bin/zellij", "delete-session", "--force", id]]
        }
    )
}

@Suite("Resize with screen and zellij", .serialized,
       .enabled(if: RealProcessTests.isEnabled, RealProcessTests.reason))
struct MultiplexerResizeTests {

    /// Strips CSI/OSC escape sequences so a marker line survives a multiplexer's
    /// redraw interleaving.
    private static func plainText(_ bytes: [UInt8]) -> String {
        let raw = String(decoding: bytes, as: UTF8.self)
        var cleaned = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character == "\u{1B}" {
                index = raw.index(after: index)
                guard index < raw.endIndex else { break }
                if raw[index] == "[" {   // CSI: skip to final byte @-~
                    index = raw.index(after: index)
                    while index < raw.endIndex,
                          !("\u{40}"..."\u{7E}").contains(raw[index]) {
                        index = raw.index(after: index)
                    }
                    if index < raw.endIndex { index = raw.index(after: index) }
                } else if raw[index] == "]" {   // OSC: skip to BEL or ST
                    while index < raw.endIndex, raw[index] != "\u{07}" {
                        index = raw.index(after: index)
                    }
                    if index < raw.endIndex { index = raw.index(after: index) }
                } else {
                    index = raw.index(after: index)
                }
                continue
            }
            cleaned.append(character)
            index = raw.index(after: index)
        }
        return cleaned
    }

    /// Runs a marker'd `stty size` inside the pane and returns the ROWS the pane
    /// believes it has. The marker is assembled by printf so the echoed command
    /// cannot satisfy the scan.
    private func paneRows(
        _ client: TestClient, marker: String, seconds: Double = 10
    ) -> Int? {
        let head = String(marker.prefix(2)), tail = String(marker.dropFirst(2))
        client.send(.pty(0, Array(
            "printf '%s%s:%s\\n' '\(head)' '\(tail)' \"$(stty size)\"\n".utf8)))
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = client.pump(timeout: 0.3) { _ in false }   // keep draining
            let text = Self.plainText(client.ptyStream)
            if let range = text.range(of: "\(marker):"),
               let match = text[range.upperBound...]
                   .split(separator: "\n").first?
                   .split(separator: " ").first,
               let rows = Int(match.trimmingCharacters(in: .whitespaces)) {
                return rows
            }
        }
        return nil
    }

    @Test("A pane inside the multiplexer tracks shrink and growth",
          arguments: [MuxSpec.screen, MuxSpec.zellij])
    func paneTracksResize(mux: MuxSpec) async throws {
        // Quiet pass where the binary is absent (CI runners lack zellij); the dev
        // Mac has both and `make check` there is the gate that matters for this.
        guard FileManager.default.isExecutableFile(atPath: mux.executable) else { return }
        // The job-control topology — the one that reproduced the phone's black
        // space; /bin/sh harnesses structurally cannot see the bug.
        try await withServer(child: .jobControlShell) { path, _ in
            let id = "mshy-\(mux.name)-\(UUID().uuidString.prefix(8).lowercased())"
            defer {
                for command in mux.cleanup(id) {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: command[0])
                    process.arguments = Array(command.dropFirst())
                    process.standardOutput = Pipe()
                    process.standardError = Pipe()
                    try? process.run()
                    process.waitUntilExit()
                }
            }

            let client = try TestClient(socketPath: path)
            defer { client.close() }
            client.send(.control(.hello(.init(
                token: "", cols: 74, rows: 64, session: "mux-\(id)"
            ))))
            #expect(client.pump { frames in frames.contains { $0.kind == .control } },
                    "no Welcome")

            client.send(.pty(0, Array("\(mux.start(id))\n".utf8)))
            // Let the multiplexer draw before asking anything of its pane, and send
            // one bare return: stock screen 4.00.03 parks on a copyright splash
            // until a key arrives (harmless to zellij).
            usleep(1_500_000)
            client.send(.pty(0, Array("\n".utf8)))
            usleep(300_000)

            guard let tall = paneRows(client, marker: "SZA") else {
                let tail = Self.plainText(client.ptyStream).suffix(400)
                let snapshot = Process()
                snapshot.executableURL = URL(fileURLWithPath: "/bin/ps")
                snapshot.arguments = ["-eo", "pid,ppid,pgid,stat,command"]
                let out = Pipe(); snapshot.standardOutput = out
                try? snapshot.run(); snapshot.waitUntilExit()
                let all = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let tree = all.split(separator: "\n").filter { $0.contains(mux.name) || $0.contains("zsh") }.joined(separator: "\n")
                Issue.record("(\(mux.name)) the pane never answered stty at 74x64; saw: \(tail.debugDescription)\nprocesses:\n\(tree)")
                return
            }

            // Keyboard up.
            client.send(.control(.resize(cols: 74, rows: 39)))
            let short = paneRows(client, marker: "SZB")
            #expect(short == tall - 25, """
                (\(mux.name)) after shrinking the terminal by 25 rows the pane went \
                \(tall) -> \(String(describing: short)) — the multiplexer missed the shrink
                """)

            // Keyboard dismissed — the black-space step.
            client.send(.control(.resize(cols: 74, rows: 64)))
            let regrown = paneRows(client, marker: "SZC")
            #expect(regrown == tall, """
                (\(mux.name)) after growing back to 64 rows the pane reports \
                \(String(describing: regrown)) instead of \(tall) — everything below is \
                the black space the user reported
                """)
        }
    }
}
