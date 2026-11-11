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
        let browser = BonjourBrowser(type: "_duorecovery._tcp", retryDelay: 0.05)
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

    func testPersistentQuickPairDiscoverySurvivesWindowAndRecoveryWithoutApprovalBypass() async throws {
        let mac = PairingDiscovery(pairingWindow: 0.05)
        let phone = PairingDiscovery()
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
        let browser = BonjourBrowser(type: "_opensidecar._tcp")
        defer { browser.cancel(); receiver.stop() }
        browser.start(); receiver.start(port: UInt16.random(in: 49000...55000))
        func found() -> Bool { browser.results.contains { if case .service(let n,_,_,_) = $0.endpoint { return n == name }; return false } }
        let advertised = try await eventually { found() && receiver.discoveryDiagnostic.contains("registered") }
        XCTAssertTrue(advertised, receiver.discoveryDiagnostic)
        let result = try XCTUnwrap(browser.results.first { if case .service(let n,_,_,_) = $0.endpoint { return n == name }; return false })
        let c = NWConnection(to: result.endpoint, using: .tcp)
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
}
