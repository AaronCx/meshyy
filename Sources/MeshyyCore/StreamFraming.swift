// meshyy — channel framing for transports without native multiplexing.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// QUIC gives multiplexing for free and design doc §5.2 uses it. A unix socket
// and a TCP+TLS fallback do not, so they carry the same channels over one byte
// stream with this envelope. Design doc §3.3: the transport is replaceable, the
// protocol is the core — so the channel model must not be QUIC-shaped.
//
// Header, 7 bytes, big-endian:
//   u8  channel kind
//   u16 channel id
//   u32 payload length

import Foundation

/// Which of design doc §5.2's channels a frame belongs to.
public enum ChannelKind: UInt8, Sendable, Equatable, CaseIterable {
    /// Handshake, resize, termios, screen mode, agent events, errors.
    case control = 0
    /// Raw PTY bytes for session N.
    case pty = 1
    /// File and image attachments, client to server.
    case blob = 2

    /// The QUIC stream a frame of this kind travels on.
    ///
    /// Control and PTY share ONE stream, deliberately. QUIC guarantees order
    /// within a stream and none across streams, and the protocol's ordering
    /// promises span the two kinds in both directions: a `modes`/`termios`
    /// frame corrects the output around it (a frame that arrives before the
    /// stale bytes it corrects is overtaken and the correction is silently
    /// undone), and an inbound `resize` is ordered against keystrokes (the
    /// daemon's work queue serialises them — which only means something if
    /// the wire did not already reorder them). Splitting the kinds across
    /// streams made every one of those an ordering bug waiting on packet
    /// loss; a client under flow-control stall could even see NEW pty bytes
    /// overtake OLD ones when the daemon switched output streams mid-session.
    ///
    /// Blobs keep their own stream: §5.2's point is that a bulk upload must
    /// not head-of-line block the terminal, and nothing orders blobs against
    /// pty bytes.
    public var wireLane: ChannelKind {
        self == .blob ? .blob : .control
    }
}

/// One framed chunk on a byte-stream transport.
public struct FrameEnvelope: Sendable, Equatable {
    public var kind: ChannelKind
    public var channel: UInt16
    public var payload: [UInt8]

    public init(kind: ChannelKind, channel: UInt16 = 0, payload: [UInt8]) {
        self.kind = kind
        self.channel = channel
        self.payload = payload
    }

    public static let headerSize = 7

    /// A payload larger than this is refused rather than buffered. PTY reads are
    /// 64 KiB and control frames are tens of bytes, so 1 MiB is generous; the
    /// point is that a hostile length field cannot make the daemon allocate.
    public static let maximumPayload = 1 << 20

    public var encoded: [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(Self.headerSize + payload.count)
        bytes.append(kind.rawValue)
        bytes.append(UInt8(channel >> 8))
        bytes.append(UInt8(channel & 0xFF))
        let length = UInt32(payload.count)
        bytes.append(UInt8((length >> 24) & 0xFF))
        bytes.append(UInt8((length >> 16) & 0xFF))
        bytes.append(UInt8((length >> 8) & 0xFF))
        bytes.append(UInt8(length & 0xFF))
        bytes.append(contentsOf: payload)
        return bytes
    }

    /// Convenience for the common case: a control frame on channel 0.
    public static func control(_ frame: ControlFrame) -> FrameEnvelope {
        FrameEnvelope(kind: .control, channel: 0, payload: frame.encoded)
    }

    public static func pty(_ channel: UInt16, _ bytes: [UInt8]) -> FrameEnvelope {
        FrameEnvelope(kind: .pty, channel: channel, payload: bytes)
    }
}

/// Incremental decoder. Feed it whatever arrives; it yields whole frames.
///
/// A stream transport splits wherever it likes, so partial headers and partial
/// payloads are the normal case, not an edge case.
public struct FrameDecoder: Sendable {
    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case unknownChannelKind(UInt8)
        case payloadTooLarge(Int)

        public var description: String {
            switch self {
            case .unknownChannelKind(let raw):
                "framing: unknown channel kind \(raw)"
            case .payloadTooLarge(let length):
                "framing: payload of \(length) exceeds \(FrameEnvelope.maximumPayload)"
            }
        }
    }

    private var pending: [UInt8] = []

    public init() {}

    /// Bytes held back waiting for the rest of a frame. Exposed so a caller can
    /// assert it stays bounded.
    public var bufferedByteCount: Int { pending.count }

    /// Appends `bytes` and returns every complete frame now available.
    ///
    /// Throws on a malformed header. A caller that catches this must close the
    /// connection: the stream is desynchronised and there is no resynchronising
    /// a length-prefixed protocol.
    public mutating func push(_ bytes: [UInt8]) throws -> [FrameEnvelope] {
        pending += bytes
        var frames: [FrameEnvelope] = []

        while pending.count >= FrameEnvelope.headerSize {
            let rawKind = pending[0]
            guard let kind = ChannelKind(rawValue: rawKind) else {
                throw DecodeError.unknownChannelKind(rawKind)
            }
            let channel = UInt16(pending[1]) << 8 | UInt16(pending[2])
            let length = Int(pending[3]) << 24
                | Int(pending[4]) << 16
                | Int(pending[5]) << 8
                | Int(pending[6])
            guard length <= FrameEnvelope.maximumPayload else {
                throw DecodeError.payloadTooLarge(length)
            }

            let total = FrameEnvelope.headerSize + length
            guard pending.count >= total else { break } // wait for the rest

            let payload = Array(pending[FrameEnvelope.headerSize..<total])
            frames.append(FrameEnvelope(kind: kind, channel: channel, payload: payload))
            pending.removeFirst(total)
        }

        return frames
    }
}
