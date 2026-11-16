import CoreGraphics
import XCTest

final class CaptureSourceCheckTests: XCTestCase {
    private let iMac = CGRect(x: -198, y: -1_152, width: 2_048, height: 1_152)
    private let pixel = CGRect(x: -1_080, y: 0, width: 1_080, height: 2_424)
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func testOwnDisplayNeverTrips() {
        var check = CaptureSourceCheck()
        for second in 0..<10 {
            XCTAssertFalse(check.frame(screenRect: iMac, expected: iMac, now: t0 + Double(second)))
        }
    }

    /// #391: after sleep the iMac's stream kept delivering the Pixel's display.
    func testSustainedOtherDisplayTripsOnce() {
        var check = CaptureSourceCheck()

        XCTAssertFalse(check.frame(screenRect: pixel, expected: iMac, now: t0))
        XCTAssertFalse(check.frame(screenRect: pixel, expected: iMac, now: t0 + 1))
        XCTAssertTrue(check.frame(screenRect: pixel, expected: iMac, now: t0 + 2))
        // Re-armed: the next trip needs another sustained stretch.
        XCTAssertFalse(check.frame(screenRect: pixel, expected: iMac, now: t0 + 2.1))
    }

    func testResizeTransientDoesNotTrip() {
        var check = CaptureSourceCheck()
        let resized = CGRect(x: -198, y: -900, width: 1_600, height: 900)

        // Frames still carry the old size for a moment after a mode change.
        XCTAssertFalse(check.frame(screenRect: iMac, expected: resized, now: t0))
        XCTAssertFalse(check.frame(screenRect: iMac, expected: resized, now: t0 + 0.5))
        XCTAssertFalse(check.frame(screenRect: resized, expected: resized, now: t0 + 0.6))
        XCTAssertFalse(check.frame(screenRect: iMac, expected: resized, now: t0 + 2))
    }

    func testEmptyRectsAreIgnored() {
        var check = CaptureSourceCheck()

        XCTAssertFalse(check.frame(screenRect: .zero, expected: iMac, now: t0))
        XCTAssertFalse(check.frame(screenRect: .zero, expected: iMac, now: t0 + 5))
    }
    func testLoggedScaledNegativeOriginRoundoffNeverRestartsLiveCapture() {
        let expected = CGRect(x:514,y:-938,width:1334,height:938)
        let actual = CGRect(x:514,y:-938,width:1334,height:937.9999999999999)
        var check = CaptureSourceCheck()
        var falseRestarts = 0
        for frame in 0..<900 {
            if check.frame(screenRect:actual,expected:expected,now:t0+Double(frame)/60) { falseRestarts += 1 }
        }
        XCTAssertEqual(falseRestarts,0, "Build17 repeatedly stopped capture for equivalent scaled bounds")
    }

    func testPrecisionTolerancePreservesRealMismatchAndClearsTransientHistory() {
        let original = CGRect(x:-1334,y:514,width:938,height:1334)
        let rounded = CGRect(x:-1334+1e-10,y:514,width:938,height:1334-1e-10)
        let wrong = original.offsetBy(dx:1,dy:0)
        var check = CaptureSourceCheck()
        XCTAssertFalse(check.frame(screenRect:wrong,expected:original,now:t0))
        XCTAssertFalse(check.frame(screenRect:rounded,expected:original,now:t0+1))
        XCTAssertFalse(check.frame(screenRect:wrong,expected:original,now:t0+2))
        XCTAssertFalse(check.frame(screenRect:wrong,expected:original,now:t0+3))
        XCTAssertTrue(check.frame(screenRect:wrong,expected:original,now:t0+4))
        for dimension in [0,1,2,3] {
            var values:[CGFloat] = [-1334,514,938,1334];values[dimension] += 0.01
            XCTAssertFalse(CaptureSourceCheck.sameDisplayRect(original,CGRect(x:values[0],y:values[1],width:values[2],height:values[3])))
        }
    }

}
