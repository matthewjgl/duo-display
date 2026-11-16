import CoreGraphics
import Foundation

/// Watches that a running capture still delivers its own display (#391).
///
/// After a sleep with two receivers, a stream started on one virtual display
/// kept running but delivered the other display's picture, aspect-fit into
/// its own output size. Nothing on our side errors when that happens, so the
/// only witness is SCK's per-frame `screenRect`: the global desktop rect the
/// frame was captured from. Brief disagreement is normal while a display is
/// resized or dragged (the frame and `CGDisplayBounds` update a moment
/// apart); only a mismatch that outlasts `tolerance` counts.
struct CaptureSourceCheck {
    static let tolerance: TimeInterval = 1.5
    // SCK converts pixel/scale coordinates back to logical desktop points.
    // Numerically identical edges can differ by a few floating-point ULPs
    // (observed938 versus937.9999999999999). That must never tear down capture.
    // One millionth of a point admits rounding noise, not a different pixel,
    // display arrangement or resolution. Keep sustained real mismatch recovery.
    static let rectPrecisionTolerance: CGFloat = 0.000_001
    static func sameDisplayRect(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        zip([lhs.minX, lhs.minY, lhs.width, lhs.height],
            [rhs.minX, rhs.minY, rhs.width, rhs.height]).allSatisfy {
            $0.isFinite && $1.isFinite && abs($0 - $1) <= rectPrecisionTolerance
        }
    }

    private var mismatchSince: Date?

    /// Feed one complete frame. Returns true once, when the stream has been
    /// delivering some other rect for longer than `tolerance`; the caller
    /// then re-attaches capture and should start a fresh check.
    mutating func frame(screenRect: CGRect, expected: CGRect, now: Date = Date()) -> Bool {
        guard !screenRect.isEmpty, !expected.isEmpty, !Self.sameDisplayRect(screenRect, expected) else {
            mismatchSince = nil
            return false
        }
        guard let since = mismatchSince else {
            mismatchSince = now
            return false
        }
        guard now.timeIntervalSince(since) >= Self.tolerance else { return false }
        mismatchSince = nil
        return true
    }
}
