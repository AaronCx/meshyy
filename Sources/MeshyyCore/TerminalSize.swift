// meshyy — terminal dimensions.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.

import Foundation

/// Columns and rows. Clamped on construction because a zero or absurd dimension
/// reaches an ioctl and then a full-screen program, and neither handles it well.
public struct TerminalSize: Sendable, Equatable {
    public let cols: Int
    public let rows: Int

    /// Upper bound is generous rather than principled: it exists so a malformed
    /// Resize frame cannot ask the kernel for a 4-billion-column window.
    public static let maximumDimension = 10_000

    public init(cols: Int, rows: Int) {
        self.cols = min(max(cols, 1), Self.maximumDimension)
        self.rows = min(max(rows, 1), Self.maximumDimension)
    }

    /// VT100 default. Used only when a client connects without stating a size.
    public static let `default` = TerminalSize(cols: 80, rows: 24)
}
