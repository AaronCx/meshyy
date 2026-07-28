// meshyy — M5 notifications (design doc §9, §10 M5).
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// Delivery is injected, so nothing here touches the network. The property that
// matters most is tested first: meshyy ships no endpoint, so notifications are off
// until the user writes one.

import Foundation
import MeshyyCore
import Testing
@testable import MeshyyDaemon

/// Records what would have been sent.
private actor RecordingDelivery: NotificationDelivering {
    private(set) var bodies: [String] = []
    private(set) var endpoints: [String] = []

    func deliver(body: String, config: NotifyConfig) async {
        bodies.append(body)
        endpoints.append(config.endpoint)
    }
}

@Suite("Agent notifications")
struct AgentNotifierTests {

    /// The §9 property. There is no default endpoint and cannot be one: a URL
    /// compiled into the binary would be a destination nobody chose, which is the
    /// definition of the telemetry meshyy forbids. `scripts/check-privacy.py`
    /// enforces the absence; this asserts the behaviour that follows from it.
    @Test("Notifications are off when the user has configured nothing")
    func offByDefault() async {
        let notifier = AgentNotifier(config: nil, delivery: RecordingDelivery())
        #expect(await !notifier.isEnabled)

        await notifier.agentStatusChanged(session: "s", kind: .waiting, agentName: "Claude Code")
        #expect(await notifier.deliveredCount == 0)
    }

    @Test("A missing config file means nil, not a crash or a default")
    func absentFileIsNil() {
        let path = "/tmp/meshyy-no-such-notify-\(UUID().uuidString).json"
        #expect(NotifyConfig.load(from: path) == nil)
    }

    @Test("Only the configured statuses notify")
    func notifiesOnlyConfiguredStatuses() async {
        let delivery = RecordingDelivery()
        // Deliberately the default: `working` fires constantly and notifying on it
        // would be worse than useless.
        let config = NotifyConfig(endpoint: "x://example/notify")
        let notifier = AgentNotifier(config: config, delivery: delivery)

        await notifier.agentStatusChanged(session: "s", kind: .working, agentName: "Claude Code")
        #expect(await delivery.bodies.isEmpty, "working must not notify by default")

        await notifier.agentStatusChanged(session: "s", kind: .idle, agentName: "Claude Code")
        #expect(await delivery.bodies.isEmpty, "idle must not notify by default")

        await notifier.agentStatusChanged(session: "s", kind: .waiting, agentName: "Claude Code")
        #expect(await delivery.bodies.count == 1, "waiting is the one that matters")
    }

    @Test("The body and deep link are rendered from the user's templates")
    func rendersTemplates() async {
        let delivery = RecordingDelivery()
        let config = NotifyConfig(
            endpoint: "x://example/notify",
            bodyTemplate: "{agent} needs you in {session} ({status}) -> {link}",
            deepLinkTemplate: "aplusterminal://session/{session}"
        )
        let notifier = AgentNotifier(config: config, delivery: delivery)

        await notifier.agentStatusChanged(
            session: "build",
            kind: .waiting,
            agentName: "Claude Code"
        )
        let body = await delivery.bodies.first
        #expect(body == "Claude Code needs you in build (waiting) -> aplusterminal://session/build")
    }

    @Test("An unnamed agent renders as Agent rather than an empty string")
    func unnamedAgentHasAFallback() async {
        let delivery = RecordingDelivery()
        let notifier = AgentNotifier(
            config: NotifyConfig(endpoint: "x://example/notify"),
            delivery: delivery
        )
        await notifier.agentStatusChanged(session: "s", kind: .waiting, agentName: nil)
        #expect(await delivery.bodies.first?.contains("Agent") == true)
    }

    /// A flapping agent must not become a notification storm on someone's phone.
    @Test("Repeat notifications for one session are rate limited")
    func rateLimited() async {
        let delivery = RecordingDelivery()
        let config = NotifyConfig(
            endpoint: "x://example/notify",
            minimumInterval: .seconds(30)
        )
        let notifier = AgentNotifier(config: config, delivery: delivery)

        for _ in 0..<5 {
            await notifier.agentStatusChanged(session: "s", kind: .waiting, agentName: "A")
        }
        #expect(await delivery.bodies.count == 1)
        #expect(await notifier.suppressedCount == 4)
    }

    @Test("The rate limit is per session, so a second session still notifies")
    func rateLimitIsPerSession() async {
        let delivery = RecordingDelivery()
        let notifier = AgentNotifier(
            config: NotifyConfig(endpoint: "x://example/notify", minimumInterval: .seconds(30)),
            delivery: delivery
        )
        await notifier.agentStatusChanged(session: "one", kind: .waiting, agentName: "A")
        await notifier.agentStatusChanged(session: "two", kind: .waiting, agentName: "A")
        #expect(await delivery.bodies.count == 2)
    }

    // MARK: - Config file

    @Test("A minimal config decodes with usable defaults")
    func minimalConfigDecodes() throws {
        let json = Data(#"{"endpoint":"x://example/hook"}"#.utf8)
        let config = try JSONDecoder().decode(NotifyConfig.self, from: json)
        #expect(config.method == "POST")
        #expect(config.notifyOn == ["waiting"])
        #expect(config.minimumInterval == .seconds(30))
        #expect(config.bodyTemplate.contains("{session}"))
        #expect(config.deepLinkTemplate.contains("{session}"))
    }

    @Test("A config with no endpoint is rejected rather than defaulted")
    func endpointIsRequired() {
        let json = Data(#"{"method":"POST"}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(NotifyConfig.self, from: json)
        }
    }

    @Test("A config round-trips, including the interval")
    func configRoundTrips() throws {
        let original = NotifyConfig(
            endpoint: "x://example/hook",
            method: "PUT",
            headers: ["Title": "meshyy", "Authorization": "Bearer redacted"],
            notifyOn: ["waiting", "idle"],
            minimumInterval: .seconds(90)
        )
        let decoded = try JSONDecoder().decode(
            NotifyConfig.self,
            from: try JSONEncoder().encode(original)
        )
        #expect(decoded == original)
    }

    @Test("Rendering does no shell interpolation, whatever the session is called")
    func renderingIsInert() async {
        let delivery = RecordingDelivery()
        let notifier = AgentNotifier(
            config: NotifyConfig(endpoint: "x://example/hook", bodyTemplate: "s={session}"),
            delivery: delivery
        )
        // A session name cannot actually contain these — SessionStore.isValidName
        // rejects them — but the renderer must be inert regardless, because it is
        // one refactor away from being handed something less controlled.
        await notifier.agentStatusChanged(
            session: "$(whoami)`id`;rm -rf /",
            kind: .waiting,
            agentName: nil
        )
        #expect(await delivery.bodies.first == "s=$(whoami)`id`;rm -rf /",
                "the template is a string replace, never a command")
    }
}
