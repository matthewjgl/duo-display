import XCTest

final class ConnectionIndicatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// A session streaming over `transport`, the way the receiver reports it.
    private func streaming(_ transport: StreamTransport, at time: TimeInterval = 0) -> ConnectionIndicator {
        var i = ConnectionIndicator()
        // Loopback is known at adoption; a network socket only once ready.
        i.linkAdopted(transport == .usb ? .usb : nil, now: at(time))
        i.linkReady(transport, now: at(time))
        i.firstFrame(now: at(time))
        return i
    }

    // MARK: Transports and labels

    func testUSBStreamIsUSBDirectEverywhere() {
        let i = streaming(.usb)
        XCTAssertEqual(i.phase, .streaming(.usb))
        XCTAssertEqual(i.phase.shortLabel, "USB")
        XCTAssertEqual(i.phase.fullLabel, "USB Direct")
        XCTAssertEqual(i.phase.symbol, "cable.connector")
        XCTAssertEqual(i.phase.settingsTitle, "Connected to your Mac")
        XCTAssertTrue(i.phase.accessibilityLabel.contains("USB Direct"))
        XCTAssertNil(i.notice, "a first connection is not a handoff: no notice")
    }

    func testWiFiStreamIsWiFiEverywhere() {
        var i = ConnectionIndicator()
        i.linkAdopted(nil, now: at(0))
        XCTAssertEqual(i.phase, .disconnected, "not labelled before the path is known")
        i.linkReady(.wifi, now: at(0.1))
        XCTAssertEqual(i.phase, .connecting(.wifi))
        i.firstFrame(now: at(0.2))
        XCTAssertEqual(i.phase, .streaming(.wifi))
        XCTAssertEqual(i.phase.shortLabel, "Wi-Fi")
        XCTAssertEqual(i.phase.fullLabel, "Wi-Fi")
        XCTAssertEqual(i.phase.symbol, "wifi")
        XCTAssertTrue(i.phase.accessibilityLabel.contains("Wi-Fi"))
        XCTAssertNil(i.notice)
    }

    func testOnlyTheAdoptedSocketDecidesTheTransport() {
        // The receiver's labels come from the socket: loopback (usbmuxd) is
        // USB; a network path is Wi-Fi or wired. A charging cable produces no
        // socket at all, so a Wi-Fi stream stays Wi-Fi.
        XCTAssertEqual(StreamTransport(receiverLabel: "USB"), .usb)
        XCTAssertEqual(StreamTransport(receiverLabel: "WiFi"), .wifi)
        XCTAssertEqual(StreamTransport(receiverLabel: "Cable"), .wired)
        XCTAssertNil(StreamTransport(receiverLabel: "—"))
        XCTAssertFalse(StreamTransport.wired.fullLabel.contains("Direct"),
                       "a routed Ethernet path is not called Direct")
        XCTAssertEqual(streaming(.wifi).phase, .streaming(.wifi))
    }

    func testDisconnectedIsSaidPlainly() {
        let i = ConnectionIndicator()
        XCTAssertEqual(i.phase, .disconnected)
        XCTAssertEqual(i.phase.settingsTitle, "Waiting for your Mac")
        XCTAssertEqual(i.phase.shortLabel, "Offline")
        XCTAssertEqual(i.phase.accessibilityLabel, "Not connected to a Mac")
    }

    // MARK: Unplug -> Wi-Fi

    func testUnplugFallsBackToWiFiAndConfirmsOnlyAfterFrames() {
        var i = streaming(.usb)
        i.linkLost(hadFrames: true, deliberate: false, now: at(10))
        XCTAssertEqual(i.phase, .reconnecting(after: .usb))
        XCTAssertEqual(i.notice?.title, "USB disconnected")
        XCTAssertEqual(i.notice?.kind, .progress)
        XCTAssertNotEqual(i.phase.transport, .usb, "no stale USB label once the link is gone")

        i.linkAdopted(nil, now: at(11))
        XCTAssertEqual(i.phase, .reconnecting(after: .usb))
        i.linkReady(.wifi, now: at(11.2))
        XCTAssertEqual(i.phase, .switching(to: .wifi))
        XCTAssertEqual(i.notice?.title, "Switching to Wi-Fi…")
        XCTAssertEqual(i.notice?.symbol, "wifi")
        XCTAssertNil(i.notice?.detail)

        i.firstFrame(now: at(11.5))
        XCTAssertEqual(i.phase, .streaming(.wifi))
        XCTAssertEqual(i.notice, TransitionNotice(kind: .success, symbol: "wifi", title: "Connected via Wi-Fi"))

        i.tick(now: at(13.4))
        XCTAssertNotNil(i.notice, "still readable")
        i.tick(now: at(13.6))
        XCTAssertNil(i.notice, "fades after a short interval")
        XCTAssertEqual(i.phase, .streaming(.wifi))
        XCTAssertNil(i.nextWake(now: at(14)) , "idle once settled")
    }

    // MARK: Plug in -> USB

    func testPlugInReturnsToUSB() {
        var i = streaming(.wifi)
        i.announced(.usb, now: at(20))
        XCTAssertEqual(i.phase, .switching(to: .usb), "the announcing Wi-Fi socket is retiring")
        XCTAssertEqual(i.notice?.title, "Switching to USB…")
        XCTAssertEqual(i.notice?.symbol, "cable.connector")

        i.linkLost(hadFrames: true, deliberate: false, now: at(20.3))   // Mac closes Wi-Fi
        XCTAssertEqual(i.phase, .switching(to: .usb))
        i.linkAdopted(.usb, now: at(20.5))
        i.linkReady(.usb, now: at(20.5))
        XCTAssertEqual(i.phase, .switching(to: .usb), "not connected until frames arrive")
        XCTAssertNotEqual(i.notice?.kind, .success)

        i.firstFrame(now: at(20.7))
        XCTAssertEqual(i.phase, .streaming(.usb))
        XCTAssertEqual(i.notice?.title, "Connected via USB")
        XCTAssertEqual(i.notice?.symbol, "cable.connector")
    }

    // MARK: Failures

    func testFailedUSBSetupReturnsToWiFiHonestly() {
        var i = streaming(.wifi)
        i.announced(.usb, now: at(0))
        i.linkLost(hadFrames: true, deliberate: false, now: at(0.3))
        // USB never answers; the Mac returns to approved Wi-Fi.
        i.linkAdopted(nil, now: at(5.5))
        i.linkReady(.wifi, now: at(5.6))
        XCTAssertEqual(i.phase, .switching(to: .wifi))
        XCTAssertEqual(i.notice?.title, "Switching to Wi-Fi…")
        XCTAssertEqual(i.notice?.detail, "USB didn’t respond. Returning to Wi-Fi.")
        i.firstFrame(now: at(5.8))
        XCTAssertEqual(i.phase, .streaming(.wifi))
        XCTAssertEqual(i.notice?.title, "Connected via Wi-Fi", "never Connected via USB")
    }

    func testUnplugWithNoWiFiEndsInDisconnectedNotSuccess() {
        var i = streaming(.usb)
        i.linkLost(hadFrames: true, deliberate: false, now: at(0))
        for s in stride(from: 0.5, to: 12, by: 0.5) {
            i.tick(now: at(s))
            XCTAssertNotEqual(i.notice?.kind, .success)
            XCTAssertEqual(i.phase, .reconnecting(after: .usb))
        }
        i.tick(now: at(TransportSwitchTracker.giveUpAfter))
        XCTAssertEqual(i.phase, .disconnected)
        XCTAssertEqual(i.notice?.kind, .failure)
        XCTAssertEqual(i.notice?.title, "Disconnected")
        XCTAssertNotNil(i.notice?.detail, "recovery guidance")
        i.tick(now: at(TransportSwitchTracker.giveUpAfter + ConnectionIndicator.failureVisible))
        XCTAssertNil(i.notice)
    }

    func testReplacementLinkThatNeverStreamsIsAFailure() {
        var i = streaming(.usb)
        i.linkLost(hadFrames: true, deliberate: false, now: at(0))
        i.linkAdopted(nil, now: at(1))
        i.linkReady(.wifi, now: at(1))
        i.tick(now: at(TransportSwitchTracker.giveUpAfter))
        XCTAssertEqual(i.notice?.kind, .failure)
        XCTAssertEqual(i.phase, .connecting(.wifi), "the link is up, but nothing is claimed as streaming")
    }

    func testFreshConnectionAfterFailureClearsTheFailure() {
        var i = streaming(.usb)
        i.linkLost(hadFrames: true, deliberate: false, now: at(0))
        i.tick(now: at(12))
        XCTAssertEqual(i.notice?.kind, .failure)
        i.linkAdopted(.usb, now: at(13))
        i.linkReady(.usb, now: at(13))
        i.firstFrame(now: at(13.1))
        XCTAssertNil(i.notice)
        XCTAssertEqual(i.phase, .streaming(.usb))
    }

    // MARK: Non-handoffs

    func testWiFiDropIsADisconnectNotASwitch() {
        var i = streaming(.wifi)
        i.linkLost(hadFrames: true, deliberate: false, now: at(0))
        XCTAssertEqual(i.phase, .disconnected)
        XCTAssertNil(i.notice)
    }

    func testDeliberateCloseAndSessionEndShowNoNotice() {
        var sleeping = streaming(.usb)
        sleeping.linkLost(hadFrames: true, deliberate: true, now: at(0))
        XCTAssertEqual(sleeping.phase, .disconnected)
        XCTAssertNil(sleeping.notice)

        var ended = streaming(.usb)
        ended.sessionEnded(now: at(0))
        ended.linkLost(hadFrames: true, deliberate: false, now: at(0.1))
        XCTAssertEqual(ended.phase, .disconnected)
        XCTAssertNil(ended.notice, "Disconnect on the Mac is not an unplug")

        var midSwitch = streaming(.wifi)
        midSwitch.announced(.usb, now: at(0))
        midSwitch.sessionEnded(now: at(0.1))
        XCTAssertNil(midSwitch.notice)
        XCTAssertEqual(midSwitch.phase, .disconnected)
    }

    // MARK: Rapid changes

    func testRepeatedAnnouncementsAreDeduplicated() {
        var i = streaming(.wifi)
        i.announced(.usb, now: at(0))
        let first = i.notice
        i.announced(.usb, now: at(0.2))
        i.announced(.usb, now: at(0.4))
        XCTAssertEqual(i.notice, first)
    }

    func testRapidCableChangesKeepOneTruthfulNotice() {
        var i = streaming(.usb)
        // Unplug, Wi-Fi comes up...
        i.linkLost(hadFrames: true, deliberate: false, now: at(0))
        i.linkAdopted(nil, now: at(0.8))
        i.linkReady(.wifi, now: at(0.8))
        XCTAssertEqual(i.notice?.title, "Switching to Wi-Fi…")
        // ...cable back in before Wi-Fi streamed: the Mac announces USB on the
        // Wi-Fi socket and moves again.
        i.announced(.usb, now: at(1.0))
        XCTAssertEqual(i.phase, .switching(to: .usb))
        XCTAssertEqual(i.notice?.title, "Switching to USB…")
        i.linkLost(hadFrames: false, deliberate: false, now: at(1.2))
        i.linkAdopted(.usb, now: at(1.4))
        i.linkReady(.usb, now: at(1.4))
        XCTAssertNotEqual(i.notice?.kind, .success)
        i.firstFrame(now: at(1.6))
        XCTAssertEqual(i.notice?.title, "Connected via USB")
        // Unplugged again during the success notice: the notice is replaced,
        // never stacked, and never keeps saying "Connected".
        i.linkLost(hadFrames: true, deliberate: false, now: at(2.0))
        XCTAssertEqual(i.notice?.title, "USB disconnected")
        XCTAssertEqual(i.phase, .reconnecting(after: .usb))
        i.linkAdopted(nil, now: at(2.5))
        i.linkReady(.wifi, now: at(2.5))
        i.firstFrame(now: at(2.7))
        XCTAssertEqual(i.notice?.title, "Connected via Wi-Fi")
        XCTAssertEqual(i.phase, .streaming(.wifi))
    }

    func testEveryPhaseHasAnIconLabelAndAccessibleName() {
        let phases: [ConnectionPhase] = [
            .disconnected, .connecting(.usb), .connecting(.wifi), .streaming(.usb), .streaming(.wifi),
            .streaming(.wired), .switching(to: .usb), .switching(to: .wifi), .reconnecting(after: .usb),
            .reconnecting(after: nil),
        ]
        for phase in phases {
            XCTAssertFalse(phase.symbol.isEmpty)
            XCTAssertFalse(phase.shortLabel.isEmpty)
            XCTAssertLessThanOrEqual(phase.shortLabel.count, 12, "Compact stays short: \(phase)")
            XCTAssertFalse(phase.accessibilityLabel.isEmpty)
        }
        XCTAssertEqual(ConnectionPhase.switching(to: .usb).symbol, StreamTransport.usb.symbol,
                       "same icon for the transport on every surface")
    }
}
