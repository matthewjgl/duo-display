import XCTest
import Network
import dnssd

@MainActor
final class PairingDiscoveryTests: XCTestCase {
    func testEmptyGuidanceDoesNotDiagnosePermissionDenial() {
        XCTAssertTrue(DiscoveryGuidance.noPairableMac.contains("1.0.3 (6)"))
        XCTAssertTrue(DiscoveryGuidance.noPairableMac.contains("Pair a phone"))
        XCTAssertTrue(DiscoveryGuidance.noPairableMac.contains("USB cable alone"))
        XCTAssertTrue(DiscoveryGuidance.noPairableMac.contains("does not prove permission was denied"))
    }
    func testOnlyPolicyDenialGetsConfirmedPermissionGuidance() {
        let denied = DiscoveryGuidance.failure(.dns(Int32(kDNSServiceErr_PolicyDenied)), on: .phone)
        XCTAssertTrue(denied.contains("iOS denied"))
        let unknown = DiscoveryGuidance.failure(.posix(.ENETDOWN), on: .phone)
        XCTAssertTrue(unknown.contains("cause is not confirmed"))
        XCTAssertFalse(unknown.contains("iOS denied"))
        XCTAssertTrue(DiscoveryGuidance.failure(.dns(Int32(kDNSServiceErr_PolicyDenied)), on: .mac).contains("macOS denied"))
    }
    func testDiagnosticsIncludesActualLocalVersionWithoutPeerSecrets() {
        XCTAssertEqual(DiscoveryGuidance.localVersion(["CFBundleShortVersionString":"1.0", "CFBundleVersion":"6"]), "1.0 (6)")
        let discovery = PairingDiscovery()
        XCTAssertTrue(discovery.diagnostics.contains("_duopair._tcp / local."))
        XCTAssertFalse(discovery.isAdvertising)
    }
    func testRetryAndStopDiscardOldBrowserCallbacks() async throws {
        let discovery = PairingDiscovery(hintDelay: 0.02)
        discovery.browse(); discovery.browse(); discovery.stop()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(discovery.browserState, "Not searching")
        XCTAssertTrue(discovery.macs.isEmpty)
        XCTAssertFalse(discovery.isAdvertising)
    }
    func testActualBonjourAdvertisementIsFoundThenRemoved() async throws {
        let mac = PairingDiscovery()
        let phone = PairingDiscovery(hintDelay: 0.02)
        defer { mac.stop(); phone.stop() }
        let name = "Duo Discovery QA " + UUID().uuidString.prefix(8)
        phone.browse()
        mac.advertise(name: name)
        XCTAssertFalse(mac.isAdvertising, "Starting a listener does not mean Bonjour registration succeeded")
        func found() -> Bool {
            phone.macs.contains { if case .service(let n, let type, let domain, _) = $0.endpoint {
                return n == name && type == PairingDiscovery.service && domain == PairingDiscovery.domain
            }; return false }
        }
        for _ in 0..<250 {
            if mac.isAdvertising && found() { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(mac.isAdvertising, mac.diagnostics + " " + mac.status)
        XCTAssertTrue(found(), phone.diagnostics + " " + phone.status)
        mac.stop()
        for _ in 0..<150 {
            if !found() { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(found(), "Discovery loss must remove the pairing row")
        XCTAssertFalse(mac.isAdvertising)
    }
    func testPairingWindowClosesWithoutLeavingAnAdvertisedListener() async throws {
        let mac = PairingDiscovery(pairingWindow: 0.1)
        defer { mac.stop() }
        mac.advertise(name: "Duo Short Window " + UUID().uuidString.prefix(6))
        for _ in 0..<250 {
            if mac.status.contains("Pairing window closed") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(mac.isAdvertising)
        XCTAssertTrue(mac.status.contains("Pairing window closed"), mac.status)
    }
}
