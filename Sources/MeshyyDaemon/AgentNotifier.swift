// meshyy — push a notification when an agent starts waiting (design doc §10 M5).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// M5's acceptance: "a Claude Code permission prompt produces a phone notification
// in under two seconds, with a deep link back to the session."
//
// This is the one place meshyy talks to anything other than the user's own host,
// so it is worth being precise about how it stays inside design doc §9's "no third
// party endpoints".
//
// **meshyy ships no endpoint.** There is no URL anywhere in this tree — not a
// default, not a placeholder, not an example. The endpoint, method, headers and
// body template all come from a config file the user writes. A user-configured
// webhook is user-initiated traffic to a destination the user chose, which is a
// different thing from telemetry; a URL compiled into the binary would not be,
// however benign, because nobody chose it.
//
// That property is enforced rather than promised: `scripts/check-privacy.py` fails
// the build on any `https?://` outside a comment, and it would fail on a default
// endpoint here. If this file ever acquires one, CI stops the commit.

import Foundation
import MeshyyCore

/// A user-supplied webhook. Read from `~/.meshyy/notify.json`; absent means off.
///
/// Shaped to fit ntfy, Pushover, or anything else that accepts an HTTP request,
/// without meshyy knowing which. That is deliberate: a per-service integration
/// would mean a service name, a URL and an API shape in the source, and then
/// meshyy would have opinions about where a user's notifications go.
public struct NotifyConfig: Sendable, Equatable, Codable {
    /// Where to send. Required — there is no default and cannot be one.
    public var endpoint: String
    public var method: String
    /// Verbatim headers, e.g. an auth token or `Title` for ntfy.
    public var headers: [String: String]
    /// Body, with placeholders substituted:
    ///   `{session}`  session name
    ///   `{agent}`    agent display name, or "Agent"
    ///   `{status}`   waiting / working / idle
    ///   `{link}`     the deep link below
    public var bodyTemplate: String
    /// Deep link back to the session, also templated with `{session}`. A URL scheme
    /// rather than an https link, so it opens the app rather than a browser.
    public var deepLinkTemplate: String
    /// Only notify for these statuses. Defaults to `waiting` alone, because
    /// "working" fires constantly and would be worse than useless.
    public var notifyOn: [String]
    /// Minimum gap between notifications for one session, so a flapping agent
    /// cannot turn into a notification storm.
    public var minimumInterval: Duration

    enum CodingKeys: String, CodingKey {
        case endpoint, method, headers, bodyTemplate, deepLinkTemplate, notifyOn
        case minimumIntervalSeconds
    }

    public init(
        endpoint: String,
        method: String = "POST",
        headers: [String: String] = [:],
        bodyTemplate: String = "{agent} is waiting in {session} — {link}",
        deepLinkTemplate: String = "aplusterminal://session/{session}",
        notifyOn: [String] = ["waiting"],
        minimumInterval: Duration = .seconds(30)
    ) {
        self.endpoint = endpoint
        self.method = method
        self.headers = headers
        self.bodyTemplate = bodyTemplate
        self.deepLinkTemplate = deepLinkTemplate
        self.notifyOn = notifyOn
        self.minimumInterval = minimumInterval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        method = try container.decodeIfPresent(String.self, forKey: .method) ?? "POST"
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        bodyTemplate = try container.decodeIfPresent(String.self, forKey: .bodyTemplate)
            ?? "{agent} is waiting in {session} — {link}"
        deepLinkTemplate = try container.decodeIfPresent(String.self, forKey: .deepLinkTemplate)
            ?? "aplusterminal://session/{session}"
        notifyOn = try container.decodeIfPresent([String].self, forKey: .notifyOn) ?? ["waiting"]
        let seconds = try container.decodeIfPresent(Int.self, forKey: .minimumIntervalSeconds) ?? 30
        minimumInterval = .seconds(seconds)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(method, forKey: .method)
        try container.encode(headers, forKey: .headers)
        try container.encode(bodyTemplate, forKey: .bodyTemplate)
        try container.encode(deepLinkTemplate, forKey: .deepLinkTemplate)
        try container.encode(notifyOn, forKey: .notifyOn)
        try container.encode(Int(minimumInterval.milliseconds / 1000), forKey: .minimumIntervalSeconds)
    }

    public static var defaultPath: String {
        (DaemonIdentity.defaultDirectory as NSString).appendingPathComponent("notify.json")
    }

    /// Loads the config, or nil when the file is absent — which is the default
    /// state and means notifications are off.
    public static func load(from path: String = NotifyConfig.defaultPath) -> NotifyConfig? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(NotifyConfig.self, from: data)
    }

    /// Substitutes the placeholders. No shell, no eval — a straight replace.
    func render(_ template: String, session: String, agent: String, status: String) -> String {
        template
            .replacingOccurrences(of: "{session}", with: session)
            .replacingOccurrences(of: "{agent}", with: agent)
            .replacingOccurrences(of: "{status}", with: status)
            .replacingOccurrences(
                of: "{link}",
                with: deepLinkTemplate.replacingOccurrences(of: "{session}", with: session)
            )
    }
}

/// Delivers an agent-status notification somewhere. Injectable so tests never
/// touch the network.
public protocol NotificationDelivering: Sendable {
    func deliver(body: String, config: NotifyConfig) async
}

/// Sends the user's configured HTTP request.
public struct WebhookDelivery: NotificationDelivering {
    public init() {}

    public func deliver(body: String, config: NotifyConfig) async {
        guard let url = URL(string: config.endpoint) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = config.method
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 10
        for (field, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        // Failures are deliberately silent. A notification is best-effort: the
        // session must not stall, and design doc §9 forbids logging PTY content, so
        // there is nothing useful to say beyond what the user can see for
        // themselves by watching their own endpoint.
        _ = try? await URLSession.shared.data(for: request)
    }
}

/// Decides when to notify, and rate-limits per session.
public actor AgentNotifier {
    private let config: NotifyConfig?
    private let delivery: any NotificationDelivering
    private var lastSentAt: [String: ContinuousClock.Instant] = [:]
    private let clock = ContinuousClock()
    /// Counted so `meshyyd` can report whether notifications are working without
    /// logging their contents.
    public private(set) var deliveredCount = 0
    public private(set) var suppressedCount = 0

    public init(
        config: NotifyConfig? = NotifyConfig.load(),
        delivery: any NotificationDelivering = WebhookDelivery()
    ) {
        self.config = config
        self.delivery = delivery
    }

    public var isEnabled: Bool { config != nil }

    /// Called when a session's agent status changes.
    public func agentStatusChanged(
        session: String,
        kind: AgentEventKind,
        agentName: String?
    ) async {
        guard let config else { return }
        guard config.notifyOn.contains(kind.rawValue) else { return }

        if let last = lastSentAt[session], clock.now - last < config.minimumInterval {
            suppressedCount += 1
            return
        }
        lastSentAt[session] = clock.now
        deliveredCount += 1

        let body = config.render(
            config.bodyTemplate,
            session: session,
            agent: agentName ?? "Agent",
            status: kind.rawValue
        )
        await delivery.deliver(body: body, config: config)
    }
}
