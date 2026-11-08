// Compiled into the iOS and Mac receiver targets and into MacTests.
// Foundation-only and clock-injected: the state logic is unit-testable
// without a phone, a cable or a network.

import Foundation

/// How the live stream actually reaches this receiver. Decided from the
/// socket the receiver adopted as its session, never from whether a cable is
/// plugged in or Wi-Fi is up: a charging cable carries no stream.
///
/// - `usb`: the session arrived over loopback, which on iOS is only ever
///   usbmuxd tunnelling the Mac's TCP connection through the USB cable. That
///   is a point-to-point link with no network in between, so "USB Direct" is
///   accurate.
/// - `wifi`: a network connection whose path uses the Wi-Fi interface.
/// - `wired`: a network connection over anything else (Ethernet, Thunderbolt
///   Bridge). It may be routed through a switch, so it is not called "Direct".
enum StreamTransport: String, Equatable {
    case usb, wifi, wired

    /// From the receiver's internal label ("USB", "WiFi", "Cable").
    init?(receiverLabel: String) {
        switch receiverLabel {
        case "USB": self = .usb
        case "WiFi": self = .wifi
        case "Cable": self = .wired
        default: return nil
        }
    }

    /// Compact stats and short notices.
    var shortLabel: String {
        switch self {
        case .usb: return "USB"
        case .wifi: return "Wi-Fi"
        case .wired: return "Wired"
        }
    }

    /// Detailed stats and Settings.
    var fullLabel: String {
        switch self {
        case .usb: return "USB Direct"
        case .wifi: return "Wi-Fi"
        case .wired: return "Wired network"
        }
    }

    /// SF Symbol, the same on every surface (and on the Mac's device list).
    var symbol: String {
        switch self {
        case .usb: return "cable.connector"
        case .wifi: return "wifi"
        case .wired: return "network"
        }
    }
}

/// The connection as every surface shows it: Compact and Detailed stats, the
/// Settings status and the centered notice all read this one value.
enum ConnectionPhase: Equatable {
    /// No Mac.
    case disconnected
    /// A link is up but has not shown a frame yet (first connect).
    case connecting(StreamTransport)
    /// Frames are arriving over this transport.
    case streaming(StreamTransport)
    /// A handoff is in progress toward this transport.
    case switching(to: StreamTransport)
    /// The link died mid-stream and no replacement is up yet.
    case reconnecting(after: StreamTransport?)

    var transport: StreamTransport? {
        if case .streaming(let t) = self { return t }
        return nil
    }

    var isStreaming: Bool { transport != nil }

    /// A handoff or recovery is on screen (the last frame is dimmed).
    var isInTransition: Bool {
        switch self {
        case .switching, .reconnecting: return true
        default: return false
        }
    }

    var symbol: String {
        switch self {
        case .disconnected: return "antenna.radiowaves.left.and.right"
        case .connecting(let t), .streaming(let t), .switching(to: let t): return t.symbol
        case .reconnecting: return "arrow.triangle.2.circlepath"
        }
    }

    /// Settings uses a horizontal cable glyph so USB is distinct from a chain link.
    var settingsSymbol: String {
        switch self {
        case .connecting(.usb), .streaming(.usb), .switching(to: .usb):
            return "cable.connector.horizontal"
        default:
            return symbol
        }
    }

    /// Compact stats: a word or two.
    var shortLabel: String {
        switch self {
        case .disconnected: return "Offline"
        case .connecting: return "Connecting"
        case .streaming(let t): return t.shortLabel
        case .switching: return "Switching"
        case .reconnecting: return "Reconnecting"
        }
    }

    /// Detailed stats and the Settings transport line.
    var fullLabel: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting(let t): return "Connecting over \(t.fullLabel)…"
        case .streaming(let t): return t.fullLabel
        case .switching(let t): return "Switching to \(t.shortLabel)…"
        case .reconnecting(let after):
            return after == .usb ? "USB disconnected · Reconnecting…" : "Reconnecting…"
        }
    }

    /// Settings > Connection headline.
    var settingsTitle: String {
        switch self {
        case .disconnected: return "Waiting for your Mac"
        case .connecting: return "Connecting to your Mac"
        case .streaming: return "Connected to your Mac"
        case .switching, .reconnecting: return "Reconnecting to your Mac"
        }
    }

    /// Spoken by VoiceOver: always names the active transport, or says
    /// plainly that none is active.
    var accessibilityLabel: String {
        switch self {
        case .disconnected: return "Not connected to a Mac"
        case .connecting(let t): return "Connecting to your Mac over \(t.fullLabel)"
        case .streaming(let t): return "Streaming from your Mac over \(t.fullLabel)"
        case .switching(let t): return "Switching the stream to \(t.fullLabel)"
        case .reconnecting(let after):
            return after == .usb ? "USB disconnected. Reconnecting to your Mac"
                                 : "Connection lost. Reconnecting to your Mac"
        }
    }
}

/// The brief centered notice. One at a time: a new one replaces the current
/// one in place, so rapid cable changes never stack notices.
struct TransitionNotice: Equatable {
    enum Kind: Equatable { case progress, success, failure }
    let kind: Kind
    let symbol: String
    let title: String
    var detail: String? = nil

    var accessibilityLabel: String { [title, detail].compactMap { $0 }.joined(separator: ". ") }
}

/// The receiver's single source of truth for the active connection. Owns the
/// dim/hold logic (`TransportSwitchTracker`, unchanged) and adds what it does
/// not know: which transport the current socket really uses and whether it
/// has streamed yet. Main thread only.
struct ConnectionIndicator: Equatable {
    /// How long "Connected via …" stays before it fades.
    static let successVisible: TimeInterval = 2.0
    /// How long a failed handoff's notice stays (the idle screen follows).
    static let failureVisible: TimeInterval = 5.0

    private(set) var tracker = TransportSwitchTracker()
    /// Transport of the adopted socket (nil = none).
    private(set) var linkTransport: StreamTransport?
    /// The adopted socket is ready.
    private(set) var linkUp = false
    /// The adopted socket has shown its first frame.
    private(set) var streamingOnLink = false
    private(set) var notice: TransitionNotice?
    private var noticeExpires: Date?

    var phase: ConnectionPhase {
        if linkUp, streamingOnLink, let t = linkTransport { return .streaming(t) }
        if tracker.isActive {
            // A replacement link is up: that IS where the stream is going,
            // whatever was announced (a failed USB setup returns to Wi-Fi).
            if linkUp, let t = linkTransport { return .switching(to: t) }
            switch tracker.target {
            case .wifi?: return .switching(to: .wifi)
            case .usb?: return .switching(to: .usb)
            case .usbLost?, nil: return .reconnecting(after: .usb)
            }
        }
        if linkUp, let t = linkTransport { return .connecting(t) }
        return .disconnected
    }

    // MARK: Events (the receiver reports what really happened)

    /// A socket became the session. Its transport is known from where it came
    /// from; `linkReady` may refine it once the path is known.
    mutating func linkAdopted(_ transport: StreamTransport?, now: Date) {
        tracker.connectionAdopted()
        linkTransport = transport
        linkUp = false
        streamingOnLink = false
        refreshNotice(now: now)
    }

    mutating func linkReady(_ transport: StreamTransport?, now: Date) {
        linkTransport = transport ?? linkTransport
        linkUp = true
        refreshNotice(now: now)
    }

    /// The current socket delivered its first frame.
    mutating func firstFrame(now: Date) {
        let wasHandingOff = tracker.isActive
        streamingOnLink = true
        // The handoff is over the moment the new link streams: the success
        // notice replaces the dim's minimum time, and a stale announcement
        // must not relabel the next unplug as "Switching to USB".
        tracker.clear()
        if wasHandingOff, let t = linkTransport {
            show(TransitionNotice(kind: .success, symbol: t.symbol,
                                  title: "Connected via \(t.shortLabel)"),
                 until: now.addingTimeInterval(Self.successVisible))
        } else {
            // A fresh connection after a failed handoff: the failure is over.
            if notice?.kind == .failure { clearNotice() }
            refreshNotice(now: now)
        }
    }

    /// The Mac announced a switch (`transportSwitch`).
    mutating func announced(_ target: TransportSwitchTracker.Target, now: Date) {
        tracker.announced(to: target, now: now)
        // The Mac closes the announcing socket right after this message: it
        // no longer carries the stream, so no surface may keep naming it.
        if tracker.isActive {
            linkUp = false
            streamingOnLink = false
        }
        refreshNotice(now: now)
    }

    /// The session's socket died. `deliberate`: this side closed it (sleep,
    /// quit) — never a handoff.
    mutating func linkLost(hadFrames: Bool, deliberate: Bool, now: Date) {
        let lost = linkTransport
        linkUp = false
        streamingOnLink = false
        if deliberate {
            tracker.clear()
        } else {
            tracker.linkLost(lastTransport: lost.map(Self.receiverLabel) ?? "—",
                             hadFrames: hadFrames, now: now)
        }
        refreshNotice(now: now)
    }

    /// The Mac ended the session on purpose: no handoff follows.
    mutating func sessionEnded(now: Date) {
        tracker.sessionEnded()
        if notice?.kind == .progress { clearNotice() }
        refreshNotice(now: now)
    }

    /// Advance the clock: the dim's minimum time, the give-up, notice fades.
    mutating func tick(now: Date) {
        let wasHandingOff = tracker.isActive
        tracker.tick(now: now)
        if wasHandingOff, !tracker.isActive, !(linkUp && streamingOnLink) {
            // Gave up: no replacement link streamed. Say so, never "Connected".
            show(TransitionNotice(kind: .failure, symbol: "exclamationmark.triangle",
                                  title: "Disconnected",
                                  detail: "Reconnect the USB cable, or put both devices on the same Wi-Fi network. Then open Duo Display on your Mac."),
                 until: now.addingTimeInterval(Self.failureVisible))
        }
        if let noticeExpires, now >= noticeExpires { clearNotice() }
        refreshNotice(now: now)
    }

    /// Seconds until `tick` could change anything, or nil when idle.
    func nextWake(now: Date) -> TimeInterval? {
        let fade = noticeExpires.map { max($0.timeIntervalSince(now), 0.05) }
        let hold = tracker.nextWake(now: now)
        switch (fade, hold) {
        case let (a?, b?): return min(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    // MARK: Notice

    /// The progress notice follows the phase while a handoff is on screen.
    /// A success or failure notice keeps its own timer unless a new handoff
    /// starts, which replaces it.
    private mutating func refreshNotice(now: Date) {
        let progress: TransitionNotice?
        switch phase {
        case .switching(let t):
            let returning = tracker.target == .usb && t != .usb
            progress = TransitionNotice(kind: .progress, symbol: t.symbol,
                                        title: "Switching to \(t.shortLabel)…",
                                        detail: returning ? "USB didn’t respond. Returning to \(t.shortLabel)." : nil)
        case .reconnecting(let after):
            progress = TransitionNotice(kind: .progress, symbol: after?.symbol ?? "arrow.triangle.2.circlepath",
                                        title: after == .usb ? "USB disconnected" : "Connection lost",
                                        detail: "Reconnecting…")
        default:
            progress = nil
        }
        if let progress {
            show(progress, until: nil)
        } else if notice?.kind == .progress {
            clearNotice()
        }
    }

    private mutating func show(_ new: TransitionNotice, until: Date?) {
        if notice != new { notice = new }
        noticeExpires = until
    }

    private mutating func clearNotice() {
        notice = nil
        noticeExpires = nil
    }

    private static func receiverLabel(_ t: StreamTransport) -> String {
        switch t {
        case .usb: return "USB"
        case .wifi: return "WiFi"
        case .wired: return "Cable"
        }
    }
}

/// What the receiver publishes for the UI: one value, so every surface moves
/// together.
struct ConnectionStatus: Equatable {
    var phase: ConnectionPhase = .disconnected
    var notice: TransitionNotice?
}
