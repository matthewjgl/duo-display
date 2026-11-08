import XCTest
import CoreGraphics
import Network
import dnssd

final class DuoPeerContinuityTests: XCTestCase {
    func testPinnedPeerRejectsMissingChangedAndInvalidIdentities() {
        var gate = PeerIdentityGate(expected: "phone-A")
        XCTAssertTrue(gate.accept("phone-A"))
        XCTAssertFalse(gate.accept("phone-B"))
        XCTAssertFalse(gate.accept(nil))
        XCTAssertFalse(gate.accept(" phone-A"))
        XCTAssertTrue(gate.accept("phone-A"))
    }
    func testLegacyManualConnectionDoesNotAuthorizeWireless() {
        var gate = PeerIdentityGate()
        XCTAssertTrue(gate.accept(nil))
        XCTAssertNil(AutomaticHandoff.wirelessIndex(expectedID: nil, advertisedIDs: ["iPhone"], allowed: true))
    }
    func testLearningAnIDPinsLaterConnections() {
        var gate = PeerIdentityGate()
        XCTAssertTrue(gate.accept("A"))
        for _ in 0..<100 {
            XCTAssertTrue(gate.accept("A"))
            XCTAssertFalse(gate.accept("B"))
        }
    }
    func testWirelessRequiresOptInStrongUniqueIdentity() {
        XCTAssertNil(AutomaticHandoff.wirelessIndex(expectedID: "A", advertisedIDs: ["A"], allowed: false))
        XCTAssertNil(AutomaticHandoff.wirelessIndex(expectedID: "A", advertisedIDs: [nil, "B"], allowed: true))
        XCTAssertNil(AutomaticHandoff.wirelessIndex(expectedID: "A", advertisedIDs: ["A", "A"], allowed: true))
        XCTAssertEqual(AutomaticHandoff.wirelessIndex(expectedID: "A", advertisedIDs: [nil, "B", "A"], allowed: true), 2)
    }
    func testRepeatedTransitionsKeepIdentityAndStopAtMissingRoute() {
        var gate = PeerIdentityGate(expected: "A")
        for index in 0..<100 {
            let attached: Set<String> = index.isMultiple(of: 2) ? [] : ["USB-A"]
            let wifiIndex = AutomaticHandoff.wirelessIndex(expectedID: gate.pinnedID,
                advertisedIDs: ["B", "A"], allowed: true)
            let action = TransportFailover.decide(autoConnectEnabled: true, sessionOnUSB: true,
                sessionUDID: "USB-A", attachedUDIDs: attached, wifiServiceVisible: wifiIndex != nil)
            XCTAssertEqual(action, attached.isEmpty ? .switchToWiFi : .none)
            XCTAssertTrue(gate.accept("A"))
        }
        XCTAssertEqual(TransportFailover.decide(autoConnectEnabled: true, sessionOnUSB: true,
            sessionUDID: "USB-A", attachedUDIDs: [], wifiServiceVisible: false), .waitForWiFi)
    }
    func testExplicitUSBAnnouncementSurvivesRetiringSocketClose() {
        let t = Date(timeIntervalSince1970: 100)
        var tracker = TransportSwitchTracker()
        tracker.announced(to: .usb, now: t)
        tracker.linkLost(lastTransport: "USB", hadFrames: true, now: t.addingTimeInterval(0.1))
        XCTAssertEqual(tracker.target, .usb)
        tracker.streamResumed(now: t.addingTimeInterval(0.3))
        XCTAssertTrue(tracker.tick(now: t.addingTimeInterval(1.5)))
    }
    func testBothLoopbackFamiliesClassifyWithoutTrustingNamesOrLANAddresses() {
        let port = NWEndpoint.Port(rawValue: 9000)!
        XCTAssertTrue(DirectCable.isLoopback(.hostPort(host: .ipv4(.loopback), port: port)))
        XCTAssertTrue(DirectCable.isLoopback(.hostPort(host: .ipv6(.loopback), port: port)))
        XCTAssertFalse(DirectCable.isLoopback(.hostPort(host: "192.168.1.2", port: port)))
        XCTAssertFalse(DirectCable.isLoopback(.service(name: "localhost", type: "_opensidecar._tcp", domain: "local.", interface: nil)))
    }
    func testUnannouncedUnplugSaysDisconnectedUntilMacAnnouncesWiFi() {
        let t = Date(timeIntervalSince1970: 100)
        var tracker = TransportSwitchTracker()
        tracker.linkLost(lastTransport: "USB", hadFrames: true, now: t)
        XCTAssertEqual(tracker.target?.label, "USB disconnected · waiting to reconnect")
        tracker.connectionAdopted()
        tracker.announced(to: .wifi, now: t.addingTimeInterval(1))
        XCTAssertEqual(tracker.target?.label, "Switching to Wi-Fi · wireless mode")
        XCTAssertNil(TransportSwitchTracker.Target(rawValue: "WiFi"), "wire values stay lowercase")
    }
    func testReversalGetsNewOverlayDeadlineButDuplicateDoesNot() {
        let t = Date(timeIntervalSince1970: 100)
        var tracker = TransportSwitchTracker()
        tracker.announced(to: .wifi, now: t)
        tracker.announced(to: .usb, now: t.addingTimeInterval(10))
        XCTAssertFalse(tracker.tick(now: t.addingTimeInterval(13)))
        tracker.announced(to: .usb, now: t.addingTimeInterval(19))
        XCTAssertTrue(tracker.tick(now: t.addingTimeInterval(22)))
    }
}

final class DuoDeviceSetupTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() {
        suite = "DuoLocalTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }
    func testPerDeviceQualitySurvivesRenameAndTransportChangeWithoutChangingGlobal() {
        defaults.set("balanced", forKey: "quality")
        DeviceSetupStore.update("install-A", in: defaults) { $0.quality = "fast" }
        XCTAssertEqual(DeviceSetupStore.quality("install-A", fallback: .balanced, from: defaults), .fast)
        XCTAssertEqual(DeviceSetupStore.quality("install-B", fallback: .balanced, from: defaults), .balanced)
        XCTAssertEqual(defaults.string(forKey: "quality"), "balanced")
        XCTAssertEqual(DeviceSetupStore.quality(nil, fallback: .best, from: defaults), .best)
    }
    func testInvalidAndFutureRecordsUseCurrentSafeDefaults() {
        defaults.set(Data("broken".utf8), forKey: DeviceSetupStore.key("A"))
        XCTAssertEqual(DeviceSetupStore.load("A", from: defaults), .init())
        DeviceSetupStore.update("A", in: defaults) { $0.schema = 999; $0.wirelessAllowed = true }
        XCTAssertFalse(DeviceSetupStore.load("A", from: defaults).wirelessAllowed)
        let future = defaults.data(forKey: DeviceSetupStore.key("A"))
        DeviceSetupStore.update("A", in: defaults) { $0.quality = "fast" }
        XCTAssertEqual(defaults.data(forKey: DeviceSetupStore.key("A")), future, "a downgrade must preserve newer settings")
        DeviceSetupStore.update("B", in: defaults) { $0.quality = "unavailable-preset" }
        XCTAssertEqual(DeviceSetupStore.quality("B", fallback: .balanced, from: defaults), .balanced)
    }
    func testRecordPresenceGatesTheOneTimeWiFiMigration() {
        XCTAssertFalse(DeviceSetupStore.hasRecord("A", in: defaults))
        XCTAssertFalse(DeviceSetupStore.hasRecord(nil, in: defaults))
        DeviceSetupStore.update("A", in: defaults) { $0.reconnectAtLaunch = false }
        XCTAssertTrue(DeviceSetupStore.hasRecord("A", in: defaults),
                      "a Disconnect leaves a record, so migration never re-enables it")
    }
    func testAuthorizationIsExplicitAndDisconnectOptOutPreservesSetup() {
        XCTAssertFalse(DeviceSetupStore.load("A", from: defaults).wirelessAllowed)
        DeviceSetupStore.update("A", in: defaults) {
            $0.wirelessAllowed = true; $0.reconnectAtLaunch = true; $0.quality = "fast"
        }
        DeviceSetupStore.update("A", in: defaults) { $0.reconnectAtLaunch = false }
        let restored = DeviceSetupStore.load("A", from: defaults)
        XCTAssertTrue(restored.wirelessAllowed)
        XCTAssertFalse(restored.reconnectAtLaunch)
        XCTAssertEqual(restored.quality, "fast")
    }
    func testOrientationPersistenceAndInvalidPreferenceFallback() {
        XCTAssertEqual(ReceiverOrientation.load(from: defaults), .automatic)
        defaults.set("landscape", forKey: ReceiverOrientation.defaultsKey)
        XCTAssertEqual(ReceiverOrientation.load(from: defaults), .landscape)
        defaults.set("corrupt", forKey: ReceiverOrientation.defaultsKey)
        XCTAssertEqual(ReceiverOrientation.load(from: defaults), .automatic)
    }
}

final class DuoSafeArrangementTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let size = CGSize(width: 700, height: 500)
    func testMissingMonitorAndOccupiedSavedOriginAreRepairedOnInitialConnect() {
        let others = [main, CGRect(x: 1440, y: 0, width: 800, height: 900)]
        for origin in [CGPoint(x: -8000, y: 9000), CGPoint(x: 1500, y: 100), CGPoint(x: 0, y: 0)] {
            let point = DisplayArrangement.origin(for: size, saved: CGRect(origin: origin, size: size),
                side: nil, main: main, others: others, current: nil)
            XCTAssertTrue(DisplayArrangement.fits(CGRect(origin: point, size: size), among: others))
        }
    }
    func testValidUserPositionIsPreserved() {
        let origin = CGPoint(x: -700, y: 30)
        XCTAssertEqual(DisplayArrangement.safeOrigin(candidate: origin, size: size,
            main: main, others: [main], current: nil), origin)
    }
    func testInvalidOriginAndChangingCapabilitiesGetReachableFallback() {
        let point = DisplayArrangement.safeOrigin(candidate: CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
            size: size, main: main, others: [main], current: nil)
        XCTAssertTrue(point.x.isFinite && point.y.isFinite)
        XCTAssertTrue(DisplayArrangement.fits(CGRect(origin: point, size: size), among: [main]))
        for n in 1...200 {
            let newSize = CGSize(width: 300 + n, height: 1000 - n)
            let origin = DisplayArrangement.origin(for: newSize,
                saved: CGRect(x: -2000, y: 3000, width: 500, height: 700), side: .right,
                main: main, others: [main], current: nil)
            XCTAssertTrue(DisplayArrangement.fits(CGRect(origin: origin, size: newSize), among: [main]))
        }
    }
}

final class DuoConnectionHealthTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 100)
    func stats(_ ms: Double?, fps: Int = 1) -> LiveStats {
        .init(fps: fps, latencyMs: ms, p95Ms: nil, kind: .glass)
    }
    func testPolicyDenialIsConfirmedButOtherNetworkErrorsAreNotMisdiagnosed() {
        XCTAssertEqual(ConnectionGuidance.discoveryError(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)), on: .mac), .localNetworkDenied)
        XCTAssertEqual(ConnectionGuidance.discoveryError(.posix(.EPERM), on: .mac), .discoveryUnavailable)
        XCTAssertEqual(ConnectionGuidance.discoveryError(.posix(.ENETDOWN), on: .phone), .discoveryUnavailable)
        XCTAssertTrue(ConnectionGuidance.discoveryError(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)), on: .phone).finding.hasPrefix("iOS denied"))
    }
    func testStaticDesktopAndSingleSpikeDoNotDiagnoseSlowNetwork() {
        var health = PerformanceHealth()
        for n in 0..<10 { health.receive(stats(20, fps: 0), at: start.addingTimeInterval(Double(n))) }
        XCTAssertFalse(health.elevated)
        health.receive(stats(900), at: start.addingTimeInterval(10))
        XCTAssertFalse(health.elevated)
    }
    func testSustainedMeasuredLatencyClearsOnRecoveryAndStaleGap() {
        var health = PerformanceHealth()
        for n in 0..<5 { health.receive(stats(150), at: start.addingTimeInterval(Double(n))) }
        XCTAssertTrue(health.elevated)
        health.receive(stats(30), at: start.addingTimeInterval(5))
        XCTAssertFalse(health.elevated)
        for n in 6..<11 { health.receive(stats(150), at: start.addingTimeInterval(Double(n))) }
        XCTAssertTrue(health.elevated)
        health.receive(stats(150), at: start.addingTimeInterval(20))
        XCTAssertFalse(health.elevated)
    }
    func testMissingOrInvalidMeasurementsCannotEstablishCause() {
        var health = PerformanceHealth()
        for n in 0..<6 { health.receive(stats(nil), at: start.addingTimeInterval(Double(n))) }
        XCTAssertFalse(health.elevated)
        health.receive(stats(.nan), at: start.addingTimeInterval(6))
        XCTAssertFalse(health.elevated)
        XCTAssertTrue(ConnectionGuidance.discoveryUnavailable.action.contains("not a confirmed"))
        XCTAssertTrue(ConnectionGuidance.slow.action.contains("possible causes"))
    }
}

final class DuoUSBMetadataProbeTests: XCTestCase {
    private let queue = DispatchQueue(label: "DuoUSBProbeTests")
    func testHelloProbeReadsIdentityWithoutSendingWelcomeOrVideo() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let listening = expectation(description: "loopback server ready")
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        let readOnly = expectation(description: "probe closes without transmitting app data")
        var accepted: NWConnection?
        listener.newConnectionHandler = { connection in
            accepted = connection
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                let hello = Data("{\"type\":\"hello\",\"pixelsWide\":640,\"pixelsHigh\":360,\"scale\":2,\"id\":\"phone-A\"}".utf8)
                var length = UInt32(hello.count).bigEndian
                var frame = Data(bytes: &length, count: 4); frame.append(hello)
                connection.send(content: frame, completion: .contentProcessed { _ in })
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, _, _ in
                    XCTAssertTrue(data?.isEmpty ?? true, "metadata probe must not take over the active receiver")
                    readOnly.fulfill()
                }
            }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
        defer { accepted?.cancel(); listener.cancel() }
        await fulfillment(of: [listening], timeout: 3)
        let client = NWConnection(host: "::1", port: try XCTUnwrap(listener.port), using: .tcp)
        let ready = expectation(description: "probe socket ready")
        client.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        client.start(queue: queue)
        defer { client.cancel() }
        await fulfillment(of: [ready], timeout: 3)
        let id = try await USBPeerProbe.readInstallID(on: client, queue: queue)
        XCTAssertEqual(id, "phone-A")
        client.cancel()
        await fulfillment(of: [readOnly], timeout: 3)
    }
    func testProbeHelloParserRejectsOtherMessagesAndAbsentIdentity() {
        XCTAssertNil(DeviceIdentity.helloID(Data("{\"type\":\"welcome\",\"id\":\"A\"}".utf8)))
        XCTAssertNil(DeviceIdentity.helloID(Data("{\"type\":\"hello\",\"pixelsWide\":640,\"pixelsHigh\":360,\"scale\":2}".utf8)))
        XCTAssertNil(DeviceIdentity.helloID(Data("not json".utf8)))
    }
}

extension DuoUSBMetadataProbeTests {
    func testUnresponsiveReceiverMetadataProbeTimesOut() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let listening = expectation(description: "silent loopback server ready")
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        var accepted: NWConnection?
        listener.newConnectionHandler = { connection in
            accepted = connection
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
        defer { accepted?.cancel(); listener.cancel() }
        await fulfillment(of: [listening], timeout: 3)
        let client = NWConnection(host: "::1", port: try XCTUnwrap(listener.port), using: .tcp)
        let ready = expectation(description: "silent probe socket ready")
        client.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        client.start(queue: queue)
        defer { client.cancel() }
        await fulfillment(of: [ready], timeout: 3)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await USBPeerProbe.readInstallID(on: client, queue: queue, timeout: 0.05)
            XCTFail("silent receiver must not keep a probe alive")
        } catch {
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        }
    }
}
