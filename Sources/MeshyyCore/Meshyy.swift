// meshyy — protocol identity and version constants.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.

import Foundation

public enum Meshyy {
    /// Wire protocol version, sent in `Hello`/`Welcome` and checked on both
    /// ends. Bumped only for a breaking framing change; additive control frames
    /// do not bump it (design doc §5.3: unknown frames are ignored).
    public static let protocolVersion = 1

    /// ALPN identifier for the QUIC connection. Deliberately not anything a
    /// mosh implementation would negotiate — design doc §2, incompatibility is
    /// a feature.
    public static let alpn = "meshyy/1"

    /// Human-readable build identity, reported in `Hello`/`Welcome`.
    public static let version = "0.1.11"
}
