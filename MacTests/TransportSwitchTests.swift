import XCTest

/// The phone's "Switching to Wi-Fi · wireless mode" / "Switching to USB mode"
/// overlay state (Shared/TransportSwitch.swift), driven with an injected clock.
final class TransportSwitchTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testExactStrings() {
        XCTAssertEqual(TransportSwitchTracker.Target.wifi.label, "Switching to Wi-Fi · wireless mode")
        XCTAssertEqual(TransportSwitchTracker.Target.usb.label, "Switching to USB mode")
    }

    func testUnplugOfStreamingUSBLinkShowsWiFiOverlay() {
        var tracker = TransportSwitchTracker()
        XCTAssertTrue(tracker.linkLost(lastTransport: "USB", hadFrames: true, now: t0))
        XCTAssertEqual(tracker.target, .wifi)
    }

    func testWiFiDropOrNeverStreamedShowsNothing() {
        var tracker = TransportSwitchTracker()
        XCTAssertFalse(tracker.linkLost(lastTransport: "WiFi", hadFrames: true, now: t0))
        XCTAssertFalse(tracker.linkLost(lastTransport: "Cable", hadFrames: true, now: t0))
        // A USB link that never showed a frame (app just opened) is not a switch.
        XCTAssertFalse(tracker.linkLost(lastTransport: "USB", hadFrames: false, now: t0))
        XCTAssertNil(tracker.target)
    }

    func testDeliberateEndNeverReadsAsUnplug() {
        var tracker = TransportSwitchTracker()
        tracker.sessionEnded()                         // Mac: Disconnect / quit
        XCTAssertFalse(tracker.linkLost(lastTransport: "USB", hadFrames: true, now: t0))
        XCTAssertNil(tracker.target)
        // ...and the next, unrelated unplug counts again.
        XCTAssertTrue(tracker.linkLost(lastTransport: "USB", hadFrames: true, now: at(60)))
    }

    func testSessionEndClearsAnOverlayAlreadyUp() {
        var tracker = TransportSwitchTracker()
        tracker.announced(to: .usb, now: t0)
        tracker.sessionEnded()
        XCTAssertNil(tracker.target)
        // A late announcement on the same dying connection is ignored.
        tracker.announced(to: .wifi, now: at(0.1))
        XCTAssertNil(tracker.target)
        tracker.connectionAdopted()
        tracker.announced(to: .wifi, now: at(1))
        XCTAssertEqual(tracker.target, .wifi)
    }

    func testMacAnnouncementShowsUSBOverlay() {
        var tracker = TransportSwitchTracker()
        tracker.announced(to: .usb, now: t0)
        XCTAssertEqual(tracker.target, .usb)
    }

    func testFastSwitchStillStaysUpForMinimumTime() {
        var tracker = TransportSwitchTracker()
        tracker.linkLost(lastTransport: "USB", hadFrames: true, now: t0)
        tracker.streamResumed(now: at(0.3))            // Wi-Fi streamed already
        XCTAssertFalse(tracker.tick(now: at(0.4)))
        XCTAssertEqual(tracker.target, .wifi)
        XCTAssertFalse(tracker.tick(now: at(1.4)))
        XCTAssertTrue(tracker.tick(now: at(1.5)))
        XCTAssertNil(tracker.target)
    }

    func testSlowSwitchClearsWhenNewLinkStreams() {
        var tracker = TransportSwitchTracker()
        tracker.linkLost(lastTransport: "USB", hadFrames: true, now: t0)
        XCTAssertFalse(tracker.tick(now: at(4)))       // still waiting: no frame yet
        tracker.streamResumed(now: at(4.2))
        XCTAssertTrue(tracker.tick(now: at(4.2)))      // past the minimum already
        XCTAssertNil(tracker.target)
    }

    func testNoNewLinkGivesUpAndReturnsToIdle() {
        var tracker = TransportSwitchTracker()
        tracker.linkLost(lastTransport: "USB", hadFrames: true, now: t0)
        XCTAssertFalse(tracker.tick(now: at(11.9)))
        XCTAssertEqual(tracker.target, .wifi)
        XCTAssertTrue(tracker.tick(now: at(12)))
        XCTAssertNil(tracker.target)
    }

    func testResumeBeforeAnyOverlayIsIgnored() {
        var tracker = TransportSwitchTracker()
        tracker.streamResumed(now: t0)                 // ordinary first connect
        tracker.linkLost(lastTransport: "USB", hadFrames: true, now: at(10))
        XCTAssertEqual(tracker.target, .wifi)
        XCTAssertFalse(tracker.tick(now: at(20)) && tracker.target != nil)
    }

    func testRepeatedLossDoesNotRestartTheClock() {
        var tracker = TransportSwitchTracker()
        tracker.linkLost(lastTransport: "USB", hadFrames: true, now: t0)
        tracker.linkLost(lastTransport: "USB", hadFrames: true, now: at(5))
        XCTAssertTrue(tracker.tick(now: at(12)))       // measured from the first loss
    }

    func testNextWake() {
        var tracker = TransportSwitchTracker()
        XCTAssertNil(tracker.nextWake(now: t0))
        tracker.announced(to: .usb, now: t0)
        XCTAssertEqual(tracker.nextWake(now: at(2)) ?? 0, 10, accuracy: 0.001)
        tracker.streamResumed(now: at(2))
        XCTAssertEqual(tracker.nextWake(now: at(0.5)) ?? 0, 1.0, accuracy: 0.001)
    }

    func testWireMessageNames() {
        XCTAssertEqual(WireMessage.transportSwitch, "transportSwitch")
        XCTAssertEqual(WireMessage.sessionEnd, "sessionEnd")
        XCTAssertEqual(TransportSwitchTracker.Target(rawValue: "wifi"), .wifi)
        XCTAssertEqual(TransportSwitchTracker.Target(rawValue: "usb"), .usb)
        XCTAssertNil(TransportSwitchTracker.Target(rawValue: "bluetooth"))
    }
}

/// Which way the Mac moves a session when its cable may be gone.
final class TransportFailoverTests: XCTestCase {
    private func decide(auto: Bool = true, onUSB: Bool = true, udid: String? = "U1",
                        attached: Set<String> = [], wifi: Bool) -> TransportFailover.Action {
        TransportFailover.decide(autoConnectEnabled: auto, sessionOnUSB: onUSB,
                                 sessionUDID: udid, attachedUDIDs: attached,
                                 wifiServiceVisible: wifi)
    }

    func testUnpluggedWithWiFiServiceSwitches() {
        XCTAssertEqual(decide(wifi: true), .switchToWiFi)
    }

    func testUnpluggedWithoutServiceWaitsInsideTheGrace() {
        XCTAssertEqual(decide(wifi: false), .waitForWiFi)
    }

    func testCableStillAttachedDoesNothing() {
        XCTAssertEqual(decide(attached: ["U1"], wifi: true), .none)
        XCTAssertEqual(decide(attached: ["U1", "U2"], wifi: false), .none)
    }

    func testOtherDevicesCableDoesNotKeepThisSessionOnUSB() {
        XCTAssertEqual(decide(attached: ["U2"], wifi: true), .switchToWiFi)
    }

    func testWiFiSessionAndManualHostNeverFailOver() {
        XCTAssertEqual(decide(onUSB: false, wifi: true), .none)
        XCTAssertEqual(decide(udid: nil, wifi: true), .none)
    }

    func testAutostartOffDisablesFailover() {
        XCTAssertEqual(decide(auto: false, wifi: true), .none)
    }
}
