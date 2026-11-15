import XCTest
import CoreGraphics

final class MultiFingerTests:XCTestCase {
    private func points(_ n:Int,_ x:Double = 0,_ y:Double = 0) -> [CGPoint] { (0..<n).map{CGPoint(x:x+Double($0)*20,y:y)} }
    func testThreeAndFourFingerDirectionsFireOnceOnlyAfterSwipeFinishes() {
        for n in [3,4] {
            for (direction,dx,dy) in [(TrackpadSwipeDirection.left,-80.0,0.0),(.right,80,0),(.up,0,-80),(.down,0,80)] {
                var g = TrackpadGestureState()
                XCTAssertEqual(g.update(points:points(n),time:0),[])
                XCTAssertEqual(g.update(points:points(n,dx,dy),time:0.2),[])
                XCTAssertEqual(g.update(points:points(n,dx,dy),time:0.3),[])
                XCTAssertEqual(g.update(points:points(n-1,dx,dy),time:0.4),[.swipe(n,direction)])
                XCTAssertEqual(g.update(points:points(1,dx+50,dy),time:0.5),[])
                XCTAssertEqual(g.update(points:[],time:0.6),[])
                XCTAssertEqual(g.update(points:[],time:0.7),[])
            }
        }
    }
    func testCountChangesThresholdDiagonalPinchTimeoutAndCancellation() {
        var g = TrackpadGestureState()
        _ = g.update(points:points(3),time:0)
        _ = g.update(points:points(4),time:0.02)
        _ = g.update(points:points(4,0,-80),time:0.2)
        XCTAssertEqual(g.update(points:[],time:0.3),[.swipe(4,.up)])
        for offset in [CGPoint(x:20,y:0),CGPoint(x:70,y:70)] {
            _ = g.update(points:points(3),time:1)
            _ = g.update(points:points(3,offset.x,offset.y),time:1.2)
            XCTAssertEqual(g.update(points:[],time:1.3),[])
        }
        _ = g.update(points:points(3),time:2);_ = g.update(points:points(3,80),time:2.2)
        XCTAssertEqual(g.cancel(),[]);XCTAssertEqual(g.update(points:[],time:2.3),[])
        _ = g.update(points:points(3),time:3);_ = g.update(points:points(3,80),time:3.2)
        _ = g.update(points:points(4,80),time:3.25);XCTAssertEqual(g.update(points:[],time:3.3),[])
        _ = g.update(points:points(4),time:4)
        _ = g.update(points:[.zero,CGPoint(x:100,y:0),CGPoint(x:200,y:0),CGPoint(x:300,y:0)],time:4.2)
        XCTAssertEqual(g.update(points:[],time:4.3),[])
        _ = g.update(points:points(3),time:5);_ = g.update(points:points(3,80),time:7)
        XCTAssertEqual(g.update(points:[],time:7.1),[])
    }
    func testExistingDragOrScrollCannotBecomeSwipeAndAlwaysReleases() {
        var g = TrackpadGestureState()
        _ = g.update(points:[.zero],time:0);_ = g.advance(time:0.5)
        XCTAssertEqual(g.update(points:points(3),time:0.6),[.dragEnded])
        _ = g.update(points:points(3,80),time:0.8);XCTAssertEqual(g.update(points:[],time:0.9),[])
        _ = g.update(points:points(2),time:1);XCTAssertEqual(g.update(points:points(2,0,20),time:1.1),[.scroll(0,20)])
        _ = g.update(points:points(3,0,20),time:1.2);_ = g.update(points:points(3,0,100),time:1.4)
        XCTAssertEqual(g.update(points:[],time:1.5),[])
        _ = g.update(points:points(2),time:2);_ = g.update(points:points(1),time:2.1)
        XCTAssertEqual(g.update(points:[],time:2.2),[.secondaryClick],"Staggered two-finger lift remains secondary click")
    }
    func testMappingPersistenceOptInAndPublicShortcutValidation() {
        let name = UUID().uuidString,defaults = UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        var p = TrackpadGesturePreferences.load(defaults)
        XCTAssertFalse(p.enabled);XCTAssertNil(p.shortcut(fingers:4,direction:.up))
        p.enabled = true;XCTAssertEqual(p.shortcut(fingers:4,direction:.up)?.key,126)
        XCTAssertNil(p.shortcut(fingers:3,direction:.up));XCTAssertNil(p.shortcut(fingers:4,direction:.down))
        p.mappings["3.down"] = .appExpose;p.save(defaults)
        XCTAssertEqual(TrackpadGesturePreferences.load(defaults),p)
        XCTAssertEqual(p.shortcut(fingers:3,direction:.down)?.key,125)
        XCTAssertFalse(TrackpadShortcut(key:126,modifiers:0).valid)
        XCTAssertFalse(TrackpadShortcut(key:0,modifiers:TrackpadShortcut.control).valid)
        XCTAssertFalse(TrackpadShortcut(key:126,modifiers:UInt64.max).valid)
        p.save(defaults,scope:"Mac A")
        XCTAssertTrue(TrackpadGesturePreferences.load(defaults,scope:"Mac A").enabled)
        XCTAssertFalse(TrackpadGesturePreferences.load(defaults,scope:"Mac B").enabled)
    }
    func testSessionAdmissionRejectsUnauthorizedReplayInvalidAndRapidDuplicates() {
        let chord = TrackpadShortcut(key:126,modifiers:TrackpadShortcut.control)
        let first = TrackpadGestureRequest(id:UUID().uuidString,sequence:1,fingers:4,direction:.up,shortcut:chord)
        var gate = TrackpadGestureAdmission()
        XCTAssertFalse(gate.accept(first,authenticated:false,now:0))
        XCTAssertTrue(gate.accept(first,authenticated:true,now:0))
        XCTAssertFalse(gate.accept(first,authenticated:true,now:1))
        let second = TrackpadGestureRequest(id:UUID().uuidString,sequence:2,fingers:3,direction:.down,shortcut:chord)
        XCTAssertFalse(gate.accept(second,authenticated:true,now:0.1));XCTAssertTrue(gate.accept(second,authenticated:true,now:0.3))
        let bad = TrackpadGestureRequest(id:UUID().uuidString,sequence:3,fingers:2,direction:.up,shortcut:chord)
        XCTAssertFalse(gate.accept(bad,authenticated:true,now:1))
    }
    func testShortcutPostsBalancedPublicEventsAndSecureInputFailsClosed() {
        let input = InputInjector(displayID:1,post:{_ in XCTFail("No real input")})
        var events:[CGEvent] = []
        let chord = TrackpadShortcut(key:126,modifiers:TrackpadShortcut.control)
        XCTAssertFalse(input.handleGestureShortcut(chord,post:{events.append($0)},secureInput:true));XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(input.handleGestureShortcut(chord,post:{events.append($0)},secureInput:false))
        XCTAssertEqual(events.map(\.type),[.keyDown,.keyUp])
        XCTAssertEqual(events.map{$0.getIntegerValueField(.keyboardEventKeycode)},[126,126])
        XCTAssertTrue(events.allSatisfy{$0.flags.contains(.maskControl)})
    }
    func testHapticActionsNeverFireForMovementScrollCancellationOrDuplicateHold() {
        var state = PhoneInputFeedbackState()
        XCTAssertNil(state.trackpad(.click(1),accepted:false))
        XCTAssertEqual(state.trackpad(.click(1),accepted:true),.click)
        XCTAssertEqual(state.trackpad(.click(2),accepted:true),.click)
        XCTAssertEqual(state.trackpad(.secondaryClick,accepted:true),.secondaryClick)
        XCTAssertEqual(state.trackpad(.dragBegan,accepted:true),.hold)
        XCTAssertNil(state.trackpad(.dragBegan,accepted:true))
        for _ in 0..<100 { XCTAssertNil(state.trackpad(.move(1,1),accepted:true));XCTAssertNil(state.trackpad(.scroll(0,1),accepted:true)) }
        XCTAssertNil(state.trackpad(.dragEnded,accepted:true));state.reset()
        XCTAssertEqual(state.trackpad(.dragBegan,accepted:true),.hold)
        XCTAssertNil(PhoneHapticPolicy.intensity(.off))
        XCTAssertEqual(PhoneHapticPolicy.intensity(.light),0.45)
        XCTAssertEqual(PhoneHapticPolicy.intensity(.standard),0.75)
        XCTAssertEqual(PhoneHapticPolicy.intensity(.strong),1)
        var direct = DirectTouchFeedbackState()
        XCTAssertNil(direct.complete(tap:true,accepted:false))
        for _ in 0..<20 { XCTAssertEqual(direct.complete(tap:true,accepted:true),.click) }
        XCTAssertEqual(direct.engage(accepted:true),.hold);XCTAssertNil(direct.engage(accepted:true))
        XCTAssertNil(direct.complete(tap:true,accepted:true),"Hold release must not also signal a click")
        direct.cancel();XCTAssertNil(direct.complete(tap:false,accepted:true))
        let name = UUID().uuidString,defaults = UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        for level in PhoneHapticLevel.allCases {
            defaults.set(level.rawValue,forKey:PhoneHapticLevel.defaultsKey)
            XCTAssertEqual(PhoneHapticLevel.load(defaults),level)
        }
    }
    func testMessagesAlreadyFocusedDuringDragIsNotNewTypingIntent() {
        var press = PointerTypingIntent(),evidence = KeyboardClickEvidence()
        press.begin(CGPoint(x:100,y:20),time:0);press.move(CGPoint(x:160,y:20))
        XCTAssertFalse(press.end(CGPoint(x:180,y:20),time:0.3))
        evidence.begin(now:0)
        for t in [0.15,0.3,0.5] { XCTAssertFalse(evidence.confirms(token:"Messages compose",editable:true,hitMatches:false,now:t)) }
        evidence.begin(now:1)
        XCTAssertFalse(evidence.confirms(token:"Messages compose",editable:true,hitMatches:true,now:1.15))
        XCTAssertTrue(evidence.confirms(token:"Messages compose",editable:true,hitMatches:true,now:1.25))
        evidence.reset();XCTAssertFalse(evidence.confirms(token:"Messages compose",editable:true,hitMatches:true,now:1.4))
        press.begin(.zero,time:2);XCTAssertFalse(press.end(.zero,time:2.5))
        press.begin(.zero,time:3);XCTAssertTrue(press.end(CGPoint(x:2,y:1),time:3.1))
    }
    func testPointerLedgerPreservesDeltasBeforeOSAcknowledgesAndYieldsToPhysicalMouse() {
        var emitted:[CGPoint] = [],physical = CGPoint(x:100,y:100)
        let input = InputInjector(displayID:1,cursorProvider:{physical},displaysProvider:{[CGRect(x:0,y:0,width:4000,height:2000)]},post:{emitted.append($0.location)})
        for _ in 0..<100 { input.handleTrackpad(action:"move",dx:1,dy:0) }
        XCTAssertEqual(emitted.last,CGPoint(x:200,y:100),"Old implementation repeatedly posted 101, losing 99 of 100 points")
        physical = CGPoint(x:1000,y:500)
        input.handleTrackpad(action:"move",dx:10,dy:0)
        XCTAssertEqual(emitted.last,CGPoint(x:1010,y:500))
        var ledger = RelativePointerLedger()
        XCTAssertEqual(ledger.base(observation:.zero,now:0),.zero)
        ledger.posted(CGPoint(x:10,y:0),now:0)
        XCTAssertEqual(ledger.base(observation:.zero,now:0.05),CGPoint(x:10,y:0))
        XCTAssertEqual(ledger.base(observation:.zero,now:0.3),.zero,"Expired coordinates are not replayed")
    }
    func testMovementSlopNeverLosesAccumulatedDisplacement() {
        var g = TrackpadGestureState();_ = g.update(points:[.zero],time:0)
        XCTAssertEqual(g.update(points:[CGPoint(x:2,y:0)],time:0.01),[])
        XCTAssertEqual(g.update(points:[CGPoint(x:5,y:0)],time:0.02),[.move(5,0)])
        XCTAssertEqual(g.update(points:[],time:0.03),[])
        _ = g.update(points:[CGPoint(x:200,y:30)],time:1)
        XCTAssertEqual(g.update(points:[CGPoint(x:205,y:30)],time:1.01),[.move(5,0)])
    }
    func testOnlyStaleMovementIsSkippedAndDirectTouchSecondaryUsesActualTarget() {
        XCTAssertTrue(TrackpadPacketFreshness.skip(action:"move",sentMacMs:0,nowMacMs:251))
        XCTAssertFalse(TrackpadPacketFreshness.skip(action:"move",sentMacMs:0,nowMacMs:250))
        XCTAssertFalse(TrackpadPacketFreshness.skip(action:"move",sentMacMs:nil,nowMacMs:1000))
        for action in ["click","dragBegan","dragEnded","scroll","inputReset"] {
            XCTAssertFalse(TrackpadPacketFreshness.skip(action:action,sentMacMs:0,nowMacMs:1000))
        }
        var events:[CGEvent] = []
        let input = InputInjector(displayID:1,boundsProvider:{_ in CGRect(x:-1000,y:0,width:1000,height:800)},cursorProvider:{.zero},post:{events.append($0)})
        input.handleTouch(phase:"moved",x:0.8,y:0.5)
        XCTAssertEqual(input.lastPostedPoint,CGPoint(x:-200,y:400))
        input.handleTrackpad(action:"secondaryClick")
        XCTAssertEqual(events.last?.type,.rightMouseUp)
        XCTAssertEqual(events.last?.location,CGPoint(x:-200,y:400))
    }
    func testDeterministicDelayedOSReadbackBeforeAfterMeasurement() throws {
        func replay(improved:Bool) -> Double {
            var observed = CGPoint(x:0,y:100),ledger = RelativePointerLedger()
            var outstanding:[(due:Double,point:CGPoint)] = [],lastDue = 0.0,last = observed
            for i in 0..<100 {
                let now = Double(i)*0.01
                while outstanding.first.map({$0.due <= now}) == true { observed = outstanding.removeFirst().point }
                let base = improved ? ledger.base(observation:observed,now:now) : observed
                last = CGPoint(x:base.x+2,y:100)
                let due = max(lastDue+0.001,now+0.02+Double(i%3)*0.01);lastDue = due
                outstanding.append((due,last));if improved { ledger.posted(last,now:now) }
            }
            return last.x
        }
        let old = replay(improved:false),new = replay(improved:true)
        XCTAssertLessThan(old,200);XCTAssertEqual(new,200)
        let out = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/multifinger-20261111")
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let data = try JSONSerialization.data(withJSONObject:["scenario":"Simulated 100 deltas of 2 points, 10ms arrival spacing, ordered OS readback delay jitter 20/30/40ms. Not physical-device latency.","expected_displacement":200,"old_displacement":old,"new_displacement":new,"old_error_points":200-old,"new_error_points":200-new],options:[.prettyPrinted,.sortedKeys])
        try data.write(to:out.appendingPathComponent("synthetic-pointer-measurement.json"))
    }
}
