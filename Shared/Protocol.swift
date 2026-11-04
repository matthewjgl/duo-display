// Compiled into BOTH the Mac and iOS targets (see project.yml `sources`).
// Keep this Foundation-only so it stays platform-neutral.

import Foundation

/// The wire-protocol contract between the two apps, decoupled from the app's
/// marketing version. See COMPATIBILITY.md.
///
/// Bumped only when the wire changes, not every release, so UI-only releases
/// never trigger a compatibility event. A peer that advertises no version is
/// protocol 1 — that's every install in the field that predates the handshake.
enum WireProtocol {
    /// The protocol version this build speaks.
    static let version = 3

    /// Protocol version that introduced Apple Pencil / proximity wire messages.
    /// Peers below this get pencil input as legacy `touch` events.
    static let pencilWireVersion = 3

    /// Oldest peer protocol version this build still supports. Stays at 1
    /// (support everything) until a deliberate two-phase breaking change
    /// raises it — raising this is what turns "peer too old" into a hard gate.
    static let minSupportedPeer = 1

    /// A peer that advertises no `pv` is defined as protocol 1.
    static let assumedWhenAbsent = 1
}

/// Control-message `type` strings introduced with the handshake. The pre-
/// existing types (`hello`, `ping`, `pong`, `touch`, …) stay inline for now to
/// keep this change additive and low-risk; unify later if we do a wider pass.
enum WireMessage {
    static let welcome = "welcome"                  // Mac -> phone: Mac's pv + min supported
    static let updateRequired = "updateRequired"    // Mac -> phone: peer is below the Mac's floor
    static let sleeping = "sleeping"                // phone -> Mac: device locked, reconnect on wake
    static let closing = "closing"                  // phone -> Mac: app quit, end the session for good
    static let streamConfig = "streamConfig"        // Mac -> receiver: selected video operating point
    static let power = "power"                      // Mac -> receiver: shut down (PROTOCOL.md 6.6)
    static let live = "live"                        // receiver -> Mac: ~1 Hz latency + FPS (PROTOCOL.md 6.1)
    static let transportSwitch = "transportSwitch"  // Mac -> receiver: moving to USB/Wi-Fi now (PROTOCOL.md 6.8)
    static let sessionEnd = "sessionEnd"            // Mac -> receiver: deliberate end, no switch coming (PROTOCOL.md 6.8)
}

/// Live latency + frame rate as measured ON THE RECEIVER and reported to the
/// sender about once a second in a `live` control message (PROTOCOL.md 6.1).
/// The Mac shows it in its menu bar. Pure data + parsing so both ends and the
/// unit tests share one definition. Every field is optional on the wire; a
/// sender that never receives one (older receiver) simply shows "—".
struct LiveStats: Equatable {
    /// Where on the receiver the latency sample was taken.
    enum Kind: String {
        /// Capture on the Mac -> the frame actually presented on glass (Metal renderer).
        case glass
        /// Capture on the Mac -> the frame handed to the system video layer
        /// (excludes the last display refresh hop, so reads a little low).
        case handoff
        /// Receiver did not say.
        case unknown
    }

    /// Frames received and handed to the display per second (nil = not reported).
    var fps: Int?
    /// Median capture-to-display latency over the last second, ms
    /// (nil = no sample: clock sync not established yet, or no frames).
    var latencyMs: Double?
    /// 95th percentile over the same second, ms.
    var p95Ms: Double?
    var kind: Kind

    /// A reading older than this is shown as "—" rather than as current.
    static let staleAfter: TimeInterval = 4

    /// Parses a decoded control message. Returns nil when it is not a `live`
    /// message or carries neither number. Out-of-range values are dropped
    /// individually rather than trusted.
    static func parse(_ obj: [String: Any]) -> LiveStats? {
        guard (obj["type"] as? String) == WireMessage.live else { return nil }
        func number(_ key: String) -> Double? {
            guard let n = obj[key] as? NSNumber else { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        var fps: Int?
        if let f = number("fps"), f >= 0, f <= 1000 { fps = Int(f.rounded()) }
        var ms: Double?
        if let m = number("ms"), m >= 0, m < 10_000 { ms = m }
        var p95: Double?
        if ms != nil, let p = number("p95"), p >= 0, p < 10_000 { p95 = p }
        guard fps != nil || ms != nil else { return nil }
        let kind = (obj["kind"] as? String).flatMap(Kind.init(rawValue:)) ?? .unknown
        return LiveStats(fps: fps, latencyMs: ms, p95Ms: p95, kind: kind)
    }

    /// "18 ms", or "— ms" with no reading.
    static func latencyText(_ stats: LiveStats?, fresh: Bool = true) -> String {
        guard fresh, let ms = stats?.latencyMs else { return "— ms" }
        return String(format: "%.0f ms", ms)
    }

    /// "60 fps", or "— fps" with no reading.
    static func fpsText(_ stats: LiveStats?, fresh: Bool = true) -> String {
        guard fresh, let fps = stats?.fps else { return "— fps" }
        return "\(fps) fps"
    }

    /// One line for a menu row or tooltip: "18 ms · 60 fps".
    static func summary(_ stats: LiveStats?, fresh: Bool = true) -> String {
        "\(latencyText(stats, fresh: fresh)) · \(fpsText(stats, fresh: fresh))"
    }

    /// What the latency number measures, in a few words.
    static func measurementLabel(_ stats: LiveStats?, fresh: Bool = true) -> String {
        guard fresh, stats?.latencyMs != nil else { return "no reading yet" }
        switch stats?.kind ?? .unknown {
        case .glass: return "Mac capture → shown on screen"
        case .handoff: return "Mac capture → handed to display"
        case .unknown: return "Mac capture → phone"
        }
    }
}

/// What a `power` message asks the receiver to do (PROTOCOL.md 6.6). The
/// wire says what, each receiver platform decides how.
enum PowerAction: String, CaseIterable {
    case shutdown
}

/// One receiver-supported operating envelope. Every non-nil limit in an
/// entry applies together; multiple entries for the same codec are alternatives.
/// Codec names stay strings so older builds can ignore future codecs.
struct VideoCapability: Codable, Equatable {
    let codec: String
    let maxWidth: Int?
    let maxHeight: Int?
    let maxFrameRate: Int?
    let maxPixelsPerSecond: Int?

    init(codec: String, maxWidth: Int? = nil, maxHeight: Int? = nil,
         maxFrameRate: Int? = nil, maxPixelsPerSecond: Int? = nil) {
        self.codec = codec
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxFrameRate = maxFrameRate
        self.maxPixelsPerSecond = maxPixelsPerSecond
    }
}
