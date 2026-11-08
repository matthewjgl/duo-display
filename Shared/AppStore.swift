// Compiled into BOTH targets. The iOS App Store listing — the numeric ID
// otherwise lives only in the landing page (`src/App.tsx`). Centralized here so
// the iOS app can deep-link to its own update page AND the Mac can hand the
// same link to the phone in an `updateRequired` message.

import Foundation

enum AppStore {
    static let iOSAppID = "6830472572"
    /// Duo Display is currently distributed through TestFlight, not a public listing.
    static let isPubliclyAvailable = false
    /// Public TestFlight invite for the beta group (see TESTFLIGHT.md). It
    /// opens TestFlight, which offers the newest build to install.
    static let testFlightURL = URL(string: "https://testflight.apple.com/join/JkWMAuVD")!
    /// Where an outdated iOS app is sent to update: the App Store listing once
    /// public, TestFlight until then (the listing does not exist yet).
    static let updateURL = isPubliclyAvailable
        ? URL(string: "itms-apps://apps.apple.com/app/id\(iOSAppID)")!
        : testFlightURL
    /// How update prompts name that place.
    static let updateSourceName = isPubliclyAvailable ? "the App Store" : "TestFlight"
    /// Web fallback for anywhere the itms-apps scheme can't be handled.
    static let webURL = URL(string: "https://apps.apple.com/app/id\(iOSAppID)")!
    /// The listing's "Write a Review" sheet: opens in the App Store app on
    /// device, and in Safari where nothing handles App Store links.
    static let reviewURL = URL(string: "https://apps.apple.com/app/id\(iOSAppID)?action=write-review")!
}
