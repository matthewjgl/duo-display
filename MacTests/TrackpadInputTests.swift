import XCTest
import CoreGraphics

final class TrackpadInputTests: XCTestCase {
    func testDelayedReadbackThroughDirectionReversalsNeverRewindsPointerOrDrag() {
        for dragging in [false, true] {
            var observed = CGPoint(x:1000,y:100)
            var emitted:[CGEvent] = [], scheduled:[(step:Int,point:CGPoint)] = []
            var step = 0, expected = observed, maxError = 0.0
            let input = InputInjector(displayID:1,cursorProvider:{observed},
                displaysProvider:{[CGRect(x:0,y:0,width:4000,height:2000)]},
                post:{event in
                    emitted.append(event)
                    if event.type == .mouseMoved || event.type == .leftMouseDragged {
                        scheduled.append((step+3,event.location))
                    }
                })
            if dragging { input.handleTrackpad(action:"dragBegan") }
            for i in 0..<200 {
                step = i
                while scheduled.first.map({$0.step <= i}) == true { observed = scheduled.removeFirst().point }
                let dx = i%12 < 6 ? 2.0 : -2.0
                expected.x += dx
                input.handleTrackpad(action:"move",dx:dx,dy:0)
                maxError = max(maxError,abs((emitted.last?.location.x ?? 0)-expected.x))
            }
            XCTAssertEqual(maxError,0,"A repeated target must not acknowledge a newer reversal before the older OS event: drag=\(dragging)")
            if dragging {
                input.handleTrackpad(action:"dragEnded")
                XCTAssertEqual(emitted.last?.type,.leftMouseUp)
                XCTAssertEqual(emitted.last?.location,expected)
            }
        }
    }

    func testRelativeMouseEventsCarryActualMappedDeltasForMovementAndDrag() {
        var pointer=CGPoint(x:95,y:50),events:[CGEvent]=[]
        let input=InputInjector(displayID:1,cursorProvider:{pointer},
            displaysProvider:{[CGRect(x:0,y:0,width:100,height:100),CGRect(x:100,y:0,width:200,height:100)]},
            post:{events.append($0);pointer=$0.location})
        input.handleTrackpad(action:"move",dx:10,dy:2)
        XCTAssertEqual(events.last?.location,CGPoint(x:105,y:52))
        XCTAssertEqual(events.last?.getIntegerValueField(.mouseEventDeltaX),10)
        XCTAssertEqual(events.last?.getIntegerValueField(.mouseEventDeltaY),2)
        input.handleTrackpad(action:"dragBegan")
        input.handleTrackpad(action:"move",dx:-8,dy:-3)
        XCTAssertEqual(events.last?.type,.leftMouseDragged)
        XCTAssertEqual(events.last?.getIntegerValueField(.mouseEventDeltaX),-8)
        XCTAssertEqual(events.last?.getIntegerValueField(.mouseEventDeltaY),-3)
        input.handleTrackpad(action:"move",dx:-500,dy:0)
        XCTAssertEqual(events.last?.location.x,0)
        XCTAssertEqual(events.last?.getIntegerValueField(.mouseEventDeltaX),-97,"Clipped edge movement, not the requested off-screen delta")
        input.releaseAll()
        XCTAssertEqual(events.last?.type,.leftMouseUp)
    }

    func testReversalsWithCoalescedReadbackNeverAcknowledgeFutureMovement() {
        for delay in [1,3,6,10] {
            for readEvery in [1,2,4] {
                var ledger=RelativePointerLedger(),observed=CGPoint(x:1000,y:100)
                var due:[(step:Int,point:CGPoint)]=[],expected=observed,maxError=0.0
                for i in 0..<240 {
                    var ready:[CGPoint]=[]
                    while due.first.map({$0.step <= i}) == true {ready.append(due.removeFirst().point)}
                    // WindowServer can coalesce observations; do not invent a
                    // readback of every target just because it was posted.
                    if i%readEvery == 0,let newest=ready.last {observed=newest}
                    let now=Double(i)/120,dx=i%12 < 6 ? 2.0 : -2.0
                    let base=ledger.base(observation:observed,now:now)
                    let target=CGPoint(x:base.x+dx,y:base.y)
                    expected.x += dx
                    maxError=max(maxError,abs(target.x-expected.x))
                    ledger.posted(target,now:now);due.append((i+delay,target))
                }
                XCTAssertEqual(maxError,0,"delay=\(delay) samples, coalesced readback every\(readEvery)")
                XCTAssertEqual(ledger.base(observation:CGPoint(x:2500,y:800),now:2.01),CGPoint(x:2500,y:800),"Independent physical mouse takes over outside our recent targets")
                XCTAssertEqual(ledger.base(observation:CGPoint(x:2500,y:800),now:3),CGPoint(x:2500,y:800),"No stale target replay after expiry")
            }
        }
    }

    func testReadbackHistoryExpiryResetAndAmbiguityAreBounded() {
        var ledger=RelativePointerLedger()
        _=ledger.base(observation:.zero,now:0)
        ledger.posted(CGPoint(x:10,y:0),now:0)
        ledger.posted(CGPoint(x:20,y:0),now:0.01)
        ledger.posted(CGPoint(x:10,y:0),now:0.02)
        XCTAssertEqual(ledger.base(observation:CGPoint(x:10,y:0),now:0.05),CGPoint(x:10,y:0))
        ledger.posted(CGPoint(x:12,y:0),now:0.06)
        XCTAssertEqual(ledger.base(observation:CGPoint(x:20,y:0),now:0.08),CGPoint(x:12,y:0),"Late self observation cannot rewind newer movement")
        XCTAssertGreaterThan(ledger.metricsSnapshot().ambiguousReadbacks,0)
        // Beyond150ms we intentionally yield to actual OS readback rather
        // than indefinitely replay a target or mask a physical-mouse move.
        for lag in [0.17,0.3] {
            var delayed=RelativePointerLedger()
            _=delayed.base(observation:.zero,now:0);delayed.posted(CGPoint(x:50,y:0),now:0)
            XCTAssertEqual(delayed.base(observation:CGPoint(x:7,y:0),now:lag),CGPoint(x:7,y:0))
            XCTAssertEqual(delayed.metricsSnapshot().expiredTargets,1)
            delayed.reset()
            XCTAssertEqual(delayed.base(observation:CGPoint(x:200,y:0),now:lag+0.01),CGPoint(x:200,y:0))
        }
        let count=ledger.metricsSnapshot(reset:true).ambiguousReadbacks
        XCTAssertGreaterThan(count,0);XCTAssertEqual(ledger.metricsSnapshot().ambiguousReadbacks,0)
    }

    func testStoppedMotionAndRoundedDisplayEdgeReleaseAtLatestValidPosition() {
        for dragging in [false,true] {
            var observed=CGPoint(x:95,y:50),events:[CGEvent]=[]
            let input=InputInjector(displayID:1,cursorProvider:{observed},
                displaysProvider:{[CGRect(x:0,y:0,width:100,height:100)]},post:{events.append($0)})
            if dragging {input.handleTrackpad(action:"dragBegan")}
            input.handleTrackpad(action:"move",dx:10,dy:0)
            XCTAssertEqual(events.last?.location.x ?? 0,99.99,accuracy:0.001)
            observed=CGPoint(x:99,y:50) // Public OS readback clamps to its pixel grid.
            input.handleTrackpad(action:"move",dx:-5,dy:0)
            XCTAssertEqual(events.last?.location,CGPoint(x:94,y:50))
            input.handleTrackpad(action:"move",dx:2,dy:0)
            input.handleTrackpad(action:"move",dx:2,dy:0)
            observed=CGPoint(x:94,y:50) // Delayed acknowledgment after motion stopped.
            if dragging {
                input.handleTrackpad(action:"dragEnded")
                XCTAssertEqual(events.last?.type,.leftMouseUp)
                XCTAssertEqual(events.last?.location,CGPoint(x:98,y:50))
            } else {
                input.handleTrackpad(action:"click")
                XCTAssertEqual(events.last?.location,CGPoint(x:98,y:50))
            }
            let count=events.count;input.releaseAll();XCTAssertEqual(events.count,count)
        }
    }

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
