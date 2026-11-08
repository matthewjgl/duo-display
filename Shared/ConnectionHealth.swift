import Foundation
import Network
import dnssd

/// Facts and suggestions stay separate. No network probes, log uploads or
/// device identifiers are needed to present these explanations.
struct ConnectionGuidance: Equatable {
    let finding: String
    let action: String

    enum DiscoveryPlatform { case mac, phone }
    static func discoveryError(_ error: NWError, on platform: DiscoveryPlatform) -> Self {
        guard case .dns(let code) = error, code == kDNSServiceErr_PolicyDenied else {
            return .discoveryUnavailable
        }
        switch platform {
        case .mac: return .localNetworkDenied
        case .phone: return Self(
            finding: "iOS denied local-network discovery.",
            action: "Enable Local Network for Duo Display in Settings, then reopen it. USB may still work. This does not indicate an account or sign-in problem.")
        }
    }

    static let newerSettings = Self(
        finding: "This device has settings from a newer app version.",
        action: "The saved record was left unchanged. Update Duo Display before editing this device’s setup.")
    static let noDevices = Self(
        finding: "No receiver is currently discovered. This does not prove a permission problem.",
        action: "Open Duo Display on the iPhone. For Wi-Fi, use the same trusted network and check Local Network access on both devices. Guest networks or VPNs may block discovery. USB: unlock the phone, use a data cable and accept Trust if prompted.")
    static let localNetworkDenied = Self(
        finding: "macOS denied local-network discovery.",
        action: "Enable Duo Display in System Settings → Privacy & Security → Local Network, then reopen the app. USB may still be available.")
    static let discoveryUnavailable = Self(
        finding: "Network discovery is temporarily unavailable; the cause is not confirmed.",
        action: "Check your network connection and try again. If it persists, check Local Network access. A VPN or guest-network isolation is a possible cause, not a confirmed one.")
    static let disconnected = Self(
        finding: "The connection ended before it could recover.",
        action: "Keep Duo Display open and the phone unlocked. Reconnect USB, or check that the approved Wi-Fi receiver is still available, then choose Connect again. Your saved setup is kept.")
    static let waitingForWiFi = Self(
        finding: "USB is unavailable. A unique approved Wi-Fi route is not currently available.",
        action: "Reconnect the data cable, or open the receiver on the same trusted Wi-Fi network. Connect over Wi-Fi once, or allow wireless handoff for this device. The display is held briefly, then safely removed if recovery fails.")
    static let identityMismatch = Self(
        finding: "The receiver identity changed. Streaming was stopped for this connection.",
        action: "Confirm the correct device and connect manually. A renamed device is fine; reinstalling the receiver creates a new identity. Do not approve an unfamiliar receiver.")
    static let slow = Self(
        finding: "Several consecutive reports measured elevated display latency.",
        action: "Try Balanced or Fast quality, or USB. Wi-Fi congestion, decoding load or thermal throttling are possible causes; these measurements do not identify which one.")
    static let noMeasurements = Self(
        finding: "Recent performance measurements are unavailable.",
        action: "This alone does not mean the connection failed. Keep the receiver open; older versions may not report performance. Low frame rate on a static desktop is normal.")
}

struct PerformanceHealth {
    private var highLatencySamples = 0
    private var firstHighAt: Date?
    private var lastAt: Date?
    private(set) var elevated = false

    mutating func receive(_ stats: LiveStats, at now: Date) {
        if let lastAt, now.timeIntervalSince(lastAt) > LiveStats.staleAfter || now < lastAt {
            highLatencySamples = 0; firstHighAt = nil; elevated = false
        }
        lastAt = now
        // FPS alone cannot distinguish static content from dropped frames.
        guard let latency = stats.latencyMs, latency.isFinite, latency >= 120 else {
            highLatencySamples = 0; firstHighAt = nil; elevated = false; return
        }
        if firstHighAt == nil { firstHighAt = now }
        highLatencySamples = min(highLatencySamples + 1, 5)
        elevated = highLatencySamples >= 5 && now.timeIntervalSince(firstHighAt!) >= 4
    }
}
