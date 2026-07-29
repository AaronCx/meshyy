// meshyy — §8's QUIC peer policy.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.

import Network
import Testing
@testable import MeshyyDaemon

/// §8's peer policy, checked against the addresses that actually turn up.
///
/// Written after a real failure: the policy used to be expressed as
/// `prohibitedInterfaceTypes = [.wifi, …]`, which silently refused every Tailscale
/// client because a tailnet rides on wifi. An address is a fact; an interface type was
/// a guess, and the guess was wrong for the product's main use case.
@Suite("QUIC peer policy")
struct PeerPolicyTests {
    private func endpoint(_ address: String, _ port: UInt16 = 51234) -> NWEndpoint {
        .hostPort(host: .init(address), port: .init(rawValue: port)!)
    }

    @Test("A tailnet peer is admitted", arguments: [
        "100.99.230.99",   // the iPhone that reported this broken
        "100.79.92.82",    // this Mac's own tailnet address
        "100.64.0.1",      // bottom of 100.64.0.0/10
        "100.127.255.254", // top of it
    ])
    func tailnetIsAdmitted(address: String) {
        #expect(QUICServer.isPermittedPeer(endpoint(address)),
                "\(address) is inside 100.64.0.0/10 and must be admitted")
    }

    @Test("Loopback is admitted")
    func loopbackIsAdmitted() {
        #expect(QUICServer.isPermittedPeer(endpoint("127.0.0.1")))
    }

    /// The LAN is what §8 is actually defending against, and it is one octet away from
    /// the tailnet range in places — so the boundary is asserted rather than assumed.
    @Test("The LAN is refused", arguments: [
        "192.168.1.151",   // this Mac's LAN address
        "10.0.0.5",
        "100.63.255.255",  // one below the range
        "100.128.0.0",     // one above it
        "8.8.8.8",
    ])
    func lanIsRefused(address: String) {
        #expect(!QUICServer.isPermittedPeer(endpoint(address)),
                "\(address) is outside 100.64.0.0/10 and must be refused")
    }
}
