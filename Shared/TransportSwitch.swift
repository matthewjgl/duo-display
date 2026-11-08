// Compiled into the Mac, iOS and Mac receiver targets (see project.yml `sources`),
// and into MacTests. Foundation-only and clock-injected so the state logic is
// unit-testable without a phone, a cable or a network.

import Foundation

/// What the receiver shows while the session moves between USB and Wi-Fi
/// (Sidecar-style mode transition). The phone keeps its last frame on screen,
/// dims it, and says what is happening, instead of dropping to the idle screen.
///
/// Two things start it:
///  - The Mac announces a switch it is about to make (`transportSwitch`,
///    PROTOCOL.md 6.2), e.g. a cable was plugged in -> "Switching to USB mode".
///  - The receiver notices a USB link die with no goodbye: that is an unplug,
///    and the Mac is already redialing over Wi-Fi -> "Switching to Wi-Fi".
///
/// It ends when the new link streams its first frame (after a minimum on-screen
/// time, so a fast switch is still readable), when the Mac says the session is
/// over (`sessionEnd`), or after `giveUpAfter` with no new link. The last case
/// mirrors the Mac's own 10 s disconnect grace: past it the Mac tears the
/// session down, so the receiver goes back to its idle screen as before.
struct TransportSwitchTracker: Equatable {
    enum Target: String, Equatable {
        /// The Mac announced it is moving the session to Wi-Fi.
        case wifi
        /// The Mac announced it is moving the session to USB.
        case usb
        /// Inferred locally: the USB link died with no announcement. The Mac
        /// never sends this value; it only distinguishes the on-screen copy.
        case usbLost

        /// The exact on-screen strings.
        var label: String {
            switch self {
            case .wifi: return "Switching to Wi-Fi · wireless mode"
            case .usb: return "Switching to USB mode"
            case .usbLost: return "USB disconnected · waiting to reconnect"
            }
        }
    }

    /// The overlay is up for at least this long once shown, even if the new
    /// link is streaming sooner.
    static let minVisible: TimeInterval = 1.5
    /// No new link by now: stop pretending, show the idle screen.
    static let giveUpAfter: TimeInterval = 12

    /// Non-nil while the overlay should be on screen.
    private(set) var target: Target?
    private var shownAt: Date?
    private var resumedAt: Date?
    /// The Mac said this session is over on the current connection, so its
    /// close is deliberate (Disconnect, quit, restart), never an unplug.
    private(set) var peerEndedSession = false

    var isActive: Bool { target != nil }

    /// The Mac announced it is moving this session to another transport.
    mutating func announced(to newTarget: Target, now: Date) {
        guard !peerEndedSession else { return }
        begin(newTarget, now: now)
    }

    /// The connection just died. `lastTransport` is the receiver's label for
    /// the link that died ("USB", "WiFi", "Cable"); `hadFrames` is whether it
    /// ever showed a frame. Returns whether the overlay is now up.
    @discardableResult
    mutating func linkLost(lastTransport: String, hadFrames: Bool, now: Date) -> Bool {
        defer { peerEndedSession = false }
        guard !peerEndedSession, hadFrames else { return isActive }
        // Only a dead USB link is read as an unplug. A Wi-Fi drop is a network
        // blip or a Mac that went away: no promise of a switch to make.
        // A deliberate announcement outranks inference from the retiring
        // socket. Otherwise an old USB close can overwrite a USB handoff
        // (or a late close can dismiss a new recovery too early).
        if let target { begin(target, now: now) }
        else if lastTransport == "USB" { begin(.usbLost, now: now) }
        return isActive
    }

    /// The Mac ended this session on purpose: no switch is coming.
    mutating func sessionEnded() {
        peerEndedSession = true
        clear()
    }

    /// A fresh connection became the session (the old flag no longer applies).
    mutating func connectionAdopted() {
        peerEndedSession = false
    }

    /// The (new) link delivered its first frame.
    mutating func streamResumed(now: Date) {
        guard isActive, resumedAt == nil else { return }
        resumedAt = now
    }

    /// Advance the clock. Returns true when the overlay was just cleared.
    @discardableResult
    mutating func tick(now: Date) -> Bool {
        guard let shownAt, target != nil else { return false }
        if let resumedAt, now.timeIntervalSince(shownAt) >= Self.minVisible,
           now >= resumedAt {
            clear()
            return true
        }
        if now.timeIntervalSince(shownAt) >= Self.giveUpAfter {
            clear()
            return true
        }
        return false
    }

    /// Seconds until `tick` could change anything, or nil when idle.
    func nextWake(now: Date) -> TimeInterval? {
        guard let shownAt, target != nil else { return nil }
        let giveUp = Self.giveUpAfter - now.timeIntervalSince(shownAt)
        guard resumedAt != nil else { return max(giveUp, 0.05) }
        let minimum = Self.minVisible - now.timeIntervalSince(shownAt)
        return max(min(minimum, giveUp), 0.05)
    }

    mutating func clear() {
        target = nil
        shownAt = nil
        resumedAt = nil
    }

    private mutating func begin(_ newTarget: Target, now: Date) {
        if target == nil || target != newTarget { shownAt = now }
        // A new announcement for a different target (or a second one for the
        // same switch) re-arms the wait for the new link; the overlay stays up.
        target = newTarget
        resumedAt = nil
    }
}
