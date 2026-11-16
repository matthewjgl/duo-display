import CryptoKit
import XCTest
import Network
import AVFoundation
import dnssd

@MainActor
final class BonjourRecoveryTests: XCTestCase {
    private func eventually(_ predicate: () -> Bool) async throws -> Bool {
        for _ in 0..<250 {
            if predicate() { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    func testFailedBrowserRetriesButPolicyDenialDoesNotSpinAndStopRetiresRetry() async throws {
        let browser = BonjourBrowser(type: "_duorecovery._tcp", retryDelay: 0.05, watchesPath: false)
        defer { browser.cancel() }
        browser.start()
        let ready = try await eventually { browser.diagnostic.contains("ready") }
        XCTAssertTrue(ready, browser.diagnostic)
        let first = browser.generation
        browser.retry(after: .posix(.ENETDOWN))
        let recovered = try await eventually { browser.generation > first }
        XCTAssertTrue(recovered, "Network failure must create a fresh browser")
        let now = browser.generation
        browser.retry(after: .dns(Int32(kDNSServiceErr_PolicyDenied)))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(browser.generation, now, "Denied permission needs Settings/foreground, not an aggressive prompt loop")
        browser.recover(); browser.recover(); browser.cancel()
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(browser.generation, now)
        XCTAssertEqual(browser.diagnostic, "Stopped")
        XCTAssertTrue(browser.results.isEmpty)
    }

    func testNeverReadyBrowserTimesOutAndRetriesWithoutLeavingStuckStartingUI() async throws {
        var launches = 0, timeouts = 0
        let browser = BonjourBrowser(type: "_duodeadline._tcp", retryDelay: 0.04,
            startupTimeout: 0.04, launch: { _ in launches += 1 })
        browser.onState = { state in
            if case .waiting(.posix(.ETIMEDOUT)) = state { timeouts += 1 }
        }
        browser.start()
        let retried = try await eventually { launches >= 2 && timeouts >= 1 }
        XCTAssertTrue(retried, browser.diagnostic)
        browser.cancel()
        let count = launches
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(launches, count, "A canceled startup deadline cannot recreate discovery")
        XCTAssertEqual(browser.diagnostic, "Stopped")
    }

    func testReadyEmptyBrowserIsNotReportedAsBlockedOrRestartedByStartupDeadline() async throws {
        let browser = BonjourBrowser(type: "_duoempty._tcp", startupTimeout: 1, watchesPath: false)
        defer { browser.cancel() }
        browser.start()
        let ready = try await eventually { browser.diagnostic.contains("ready") }
        XCTAssertTrue(ready, browser.diagnostic)
        let generation = browser.generation
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(browser.generation, generation)
        XCTAssertFalse(browser.diagnostic.contains("timed out"))
        XCTAssertTrue(browser.results.isEmpty)
        XCTAssertTrue(DiscoveryGuidance.noPairableMac.contains("does not mean the Mac is not advertising"))
    }

    func testPersistentQuickPairDiscoverySurvivesWindowAndRecoveryWithoutApprovalBypass() async throws {
        let mac = PairingDiscovery(pairingWindow: 0.05, watchesPath: false)
        let phone = PairingDiscovery(watchesPath: false)
        defer { mac.stop(); phone.stop() }
        let name = "Duo Persistent " + UUID().uuidString.prefix(8)
        mac.advertise(name: name, persistent: true); phone.browse()
        func found() -> Bool { phone.macs.contains { if case .service(let n,_,_,_) = $0.endpoint { return n == name }; return false } }
        let first = try await eventually { mac.isAdvertising && found() }
        XCTAssertTrue(first, mac.diagnostics)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(mac.status.contains("Pairing window closed"), mac.diagnostics)
        let sustained = try await eventually { mac.isAdvertising && found() }
        XCTAssertTrue(sustained, "Persistent pairing must recover rather than expire: " + mac.diagnostics)
        XCTAssertNil(PairingApprovalCoordinator.shared.prompt, "Discovery alone cannot authorize or prompt pairing")
        mac.recover(); phone.recover()
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let restored = try await eventually { mac.isAdvertising && found() }
        XCTAssertTrue(restored, mac.diagnostics)
        XCTAssertEqual(phone.macs.filter { if case .service(let n,_,_,_) = $0.endpoint { return n == name }; return false }.count, 1)
        mac.stop()
        let removed = try await eventually { !found() }
        XCTAssertTrue(removed, phone.diagnostics + " " + phone.status + " endpoints=" + phone.macs.map { String(describing: $0.endpoint) }.joined(separator: ","))
    }

    func testReceiverAdvertisementRecoversWithoutClosingExistingTCPStream() async throws {
        let receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(), deviceKind: "iPhone", fallbackServiceName: "Recovery QA")
        let name = "Duo Receiver " + UUID().uuidString.prefix(8)
        receiver.setInitialName(name, source: nil)
        let browser = BonjourBrowser(type: "_opensidecar._tcp", watchesPath: false)
        defer { browser.cancel(); receiver.stop() }
        browser.start(); receiver.start(port: ReceiverRobustnessTests.freePort())
        func found() -> Bool { browser.results.contains { if case .service(let n,_,_,_) = $0.endpoint { return n == name }; return false } }
        let advertised = try await eventually { found() && receiver.discoveryDiagnostic.contains("registered") }
        XCTAssertTrue(advertised, receiver.discoveryDiagnostic)
        // A phone now rejects all unauthenticated LAN streams. Exercise the
        // surviving stream through the same paired TLS admission as the app,
        // while independently checking real Bonjour registration/recovery.
        let key = SymmetricKey(size: .bits256)
        let secureReady = expectation(description: "paired receiver ready")
        var securePort: NWEndpoint.Port?
        try receiver.startPairedStream(key: key, identity: name, onReady: { securePort = $0; secureReady.fulfill() })
        await fulfillment(of: [secureReady], timeout: 5)
        let c = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(securePort), using: PairedTransport.parameters(key: key, identity: name))
        defer { c.cancel() }
        let hello = expectation(description: "real receiver hello before re-registration")
        c.stateUpdateHandler = { state in
            if case .ready = state { c.receive(minimumIncompleteLength: 4, maximumLength: 65536) { data,_,_,_ in if data != nil { hello.fulfill() } } }
        }
        c.start(queue: .main)
        await fulfillment(of: [hello], timeout: 5)
        receiver.retryDiscovery(); browser.recover()
        try await Task.sleep(nanoseconds: 700_000_000)
        let restored = try await eventually { found() && receiver.discoveryDiagnostic.contains("registered") }
        XCTAssertTrue(restored, receiver.discoveryDiagnostic)
        if case .ready = c.state {} else { XCTFail("Discovery retry must preserve existing streaming socket") }
        let stopped = expectation(description: "receiver stop")
        receiver.stop { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 5)
        receiver.enterSleep()
        receiver.ensureListening()
        let foreground = try await eventually { found() && receiver.discoveryDiagnostic.contains("registered") }
        XCTAssertTrue(foreground, "Foreground must restore a closed listener")
    }

    /// Spurious identical path updates must not restart discovery (build14/15
    /// preflight flakes, and the pairing advertiser withdrawal they caused).
    nonisolated func testPathFilterIgnoresIdenticalUpdatesButReportsRealChanges() {
        let filter = PathChangeFilter()
        let wifi = PathSignature(satisfied: true, interfaces: ["en0:wifi", "lo0:loopback"], gateways: ["192.168.1.1:0"])
        XCTAssertFalse(filter.changed(wifi), "first update is the baseline")
        XCTAssertFalse(filter.changed(wifi))
        XCTAssertFalse(filter.changed(PathSignature(satisfied: true, interfaces: ["lo0:loopback", "en0:wifi"], gateways: ["192.168.1.1:0"])),
                       "interface order is not a change")
        XCTAssertTrue(filter.changed(PathSignature(satisfied: true, interfaces: ["en0:wifi", "lo0:loopback", "utun4:other"], gateways: ["192.168.1.1:0"])))
        XCTAssertTrue(filter.changed(PathSignature(satisfied: true, interfaces: ["en0:wifi", "lo0:loopback", "utun4:other"], gateways: ["10.0.0.1:0"])),
                      "roaming to another network changes the gateway")
        XCTAssertTrue(filter.changed(PathSignature(satisfied: false, interfaces: [], gateways: [])))
        XCTAssertTrue(filter.changed(wifi))
    }
}
