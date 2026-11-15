import XCTest
import CoreGraphics

final class TrackpadInputTests: XCTestCase {
    func testRelativeMovementClutchAndNoAbsoluteJump() {
        var g = TrackpadGestureState()
        XCTAssertEqual(g.update(points: [CGPoint(x: 100, y: 100)], time: 0), [])
        XCTAssertEqual(g.update(points: [CGPoint(x: 110, y: 104)], time: 0.1), [.move(10, 4)])
        XCTAssertEqual(g.update(points: [], time: 0.2), [])
        XCTAssertEqual(g.update(points: [CGPoint(x: 20, y: 30)], time: 1), [])
        XCTAssertEqual(g.update(points: [CGPoint(x: 25, y: 30)], time: 1.1), [.move(5, 0)])
    }
    func testTapDoubleTapAndHoldDragCleanup() {
        var g = TrackpadGestureState()
        _ = g.update(points: [.zero], time: 0)
        XCTAssertEqual(g.update(points: [], time: 0.1), [.click(1)])
        _ = g.update(points: [.zero], time: 0.2)
        XCTAssertEqual(g.update(points: [], time: 0.3), [.click(2)])
        _ = g.update(points: [.zero], time: 1)
        XCTAssertEqual(g.advance(time: 1.41), [.dragBegan])
        XCTAssertEqual(g.update(points: [CGPoint(x: 8, y: 0)], time: 1.5), [.move(8, 0)])
        XCTAssertEqual(g.cancel(), [.dragEnded])
        XCTAssertEqual(g.cancel(), [])
    }
    func testTwoFingerScrollCannotTurnIntoClickOrPointer() {
        var g = TrackpadGestureState()
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 20, y: 0)
        _ = g.update(points: [a,b], time: 0)
        XCTAssertEqual(g.update(points: [CGPoint(x: 0,y: 10),CGPoint(x: 20,y: 10)], time: 0.1), [.scroll(0,10)])
        XCTAssertEqual(g.update(points: [a], time: 0.2), [])
        XCTAssertEqual(g.update(points: [], time: 0.25), [])
        _ = g.update(points: [a,b], time: 1)
        XCTAssertEqual(g.update(points: [], time: 1.1), [.secondaryClick])
    }
    func testExtraFingersAndInvalidDataCancelWithoutClick() {
        var g = TrackpadGestureState()
        _ = g.update(points: [.zero], time: 0)
        _ = g.advance(time: 0.5)
        XCTAssertEqual(g.update(points: [.zero,.zero,.zero], time: 0.6), [.dragEnded])
        XCTAssertEqual(g.update(points: [], time: 0.7), [])
        XCTAssertEqual(g.update(points: [CGPoint(x: Double.nan,y:0)], time: 1), [])
    }
    func testGlobalPointerCrossesArrangedBoundaryAndRespectsOtherMouseMovement() {
        let screens = [CGRect(x: -500,y: 0,width:500,height:400), CGRect(x:0,y:0,width:1000,height:800)]
        XCTAssertEqual(PointerMapping.relative(from: CGPoint(x: -2,y:200), dx:10,dy:0,displays:screens), CGPoint(x:8,y:200))
        XCTAssertEqual(PointerMapping.relative(from: CGPoint(x: 500,y:300), dx:10,dy:0,displays:screens), CGPoint(x:510,y:300))
        XCTAssertNil(PointerMapping.relative(from:.zero,dx:.infinity,dy:0,displays:screens))
        XCTAssertEqual(PointerMapping.relative(from:.zero,dx:-1000,dy:0,displays:screens)?.x, -500)
    }
    func testEventInjectionUsesCurrentPointerAndReleasesOnlyOwnedButtons() {
        var pointer = CGPoint(x: 95,y:50)
        var events: [CGEvent] = []
        let input = InputInjector(displayID: CGMainDisplayID(), cursorProvider: { pointer },
            displaysProvider: { [CGRect(x:0,y:0,width:100,height:100),CGRect(x:100,y:0,width:200,height:100)] },
            post: { events.append($0); pointer = $0.location })
        input.handleTrackpad(action:"move",dx:10,dy:0)
        XCTAssertEqual(events.last?.location, CGPoint(x:105,y:50))
        pointer = CGPoint(x:200,y:20) // The Mac's physical mouse moved independently.
        input.handleTrackpad(action:"move",dx:5,dy:2)
        XCTAssertEqual(events.last?.location, CGPoint(x:205,y:22))
        input.handleTrackpad(action:"dragBegan")
        input.handleTrackpad(action:"move",dx:1,dy:0)
        XCTAssertEqual(events.last?.type, .leftMouseDragged)
        input.releaseAll()
        XCTAssertEqual(events.last?.type, .leftMouseUp)
        let count = events.count; input.releaseAll()
        XCTAssertEqual(events.count,count)
        input.handleTrackpad(action:"secondaryClick")
        XCTAssertEqual(events.suffix(2).map(\.type), [.rightMouseDown,.rightMouseUp])
    }
    func testScrollPreservesSubpixelMotionAndNeverWarpsPointer() {
        var events: [CGEvent] = []
        let input = InputInjector(displayID:CGMainDisplayID(), cursorProvider:{ CGPoint(x:70,y:20) }, post:{events.append($0)})
        input.handleTrackpad(action:"scroll",dx:0,dy:0.3)
        XCTAssertTrue(events.isEmpty)
        input.handleTrackpad(action:"scroll",dx:0,dy:0.3)
        XCTAssertEqual(events.count,1)
        XCTAssertEqual(events.first?.type,.scrollWheel)
        input.handleTrackpad(action:"move",dx:.nan,dy:0)
        input.handleTrackpad(action:"scroll",dx:0,dy:.infinity)
        XCTAssertEqual(events.count,1)
    }
    func testDragIsReleasedBeforeMultitouchAndCannotCreateStrayClick() {
        var g = TrackpadGestureState()
        _ = g.update(points:[.zero],time:0)
        _ = g.advance(time:0.5)
        XCTAssertEqual(g.update(points:[.zero,CGPoint(x:20,y:0)],time:0.6),[.dragEnded])
        XCTAssertEqual(g.update(points:[],time:0.7),[])
        _ = g.update(points:[.zero],time:1)
        _ = g.cancel()
        XCTAssertEqual(g.update(points:[],time:1.1),[])
    }

    func testDirectTouchStillTargetsReceiverBoundsAndClickCountsArePreserved() {
        var events: [CGEvent] = []
        let display = CGMainDisplayID(), bounds = CGDisplayBounds(CGMainDisplayID())
        let input = InputInjector(displayID:display,post:{events.append($0)})
        input.handleTouch(phase:"began",x:0.25,y:0.5)
        XCTAssertEqual(events.last?.type,.leftMouseDown)
        XCTAssertEqual(events.last?.location,CGPoint(x:bounds.minX+bounds.width*0.25,y:bounds.minY+bounds.height*0.5))
        input.handleTouch(phase:"cancelled",x:0.25,y:0.5)
        XCTAssertEqual(events.last?.type,.leftMouseUp)
        XCTAssertEqual(events.last?.getIntegerValueField(.mouseEventClickState),0)
        input.handleTrackpad(action:"click",count:2)
        XCTAssertEqual(events.last?.getIntegerValueField(.mouseEventClickState),2)
    }

}
