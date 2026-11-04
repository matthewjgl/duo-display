import Foundation

/// The Mac's decision when a USB session's cable may be gone (Duo Display
/// failover). Pure, so it is unit-tested without usbmuxd or Bonjour.
///
/// Unplugging keeps the virtual display, capture and encoder alive and redials
/// the SAME device over its Bonjour (`_opensidecar._tcp`) service. If the
/// service is not visible yet, the session waits for it inside the normal 10 s
/// disconnect grace (the sender ends the session itself when that runs out).
enum TransportFailover {
    enum Action: Equatable {
        /// Nothing to do: not a cabled session, or its cable is still attached.
        case none
        /// The cable is gone but the device's Wi-Fi service is not visible (yet).
        case waitForWiFi
        /// The cable is gone and the Wi-Fi service is visible: hand the session over.
        case switchToWiFi
    }

    static func decide(autoConnectEnabled: Bool,
                       sessionOnUSB: Bool,
                       sessionUDID: String?,
                       attachedUDIDs: Set<String>,
                       wifiServiceVisible: Bool) -> Action {
        // `-autostart NO` disables every automatic transport move.
        guard autoConnectEnabled, sessionOnUSB,
              // A manual host/port session has no cable identity to lose.
              let udid = sessionUDID,
              !attachedUDIDs.contains(udid) else { return .none }
        return wifiServiceVisible ? .switchToWiFi : .waitForWiFi
    }

    /// Row status text on the Mac while a switch is in flight.
    static let statusToWiFi = "Cable unplugged — switching to Wi-Fi…"
    static let statusToUSB = "Cable connected — switching to USB…"
}
