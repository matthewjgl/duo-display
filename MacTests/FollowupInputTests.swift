import XCTest
import CoreGraphics

final class TrackpadSpeedTests: XCTestCase {
    func testFasterCurveKeepsPrecisionAndMakesDefaultAndMaximumSubstantial() {
        let old:[Double] = [0.25,0.4,0.65,1,1.5,2.25,3.5]
        XCTAssertEqual(TrackpadSpeed.defaultLevel,4)
        XCTAssertLessThan(TrackpadSpeed.gains[0],1,"Slow end remains sub-point precision")
        for index in 0..<7 { XCTAssertGreaterThan(TrackpadSpeed.gains[index],old[index]) }
        for pair in zip(TrackpadSpeed.gains,TrackpadSpeed.gains.dropFirst()) { XCTAssertLessThan(pair.0,pair.1) }
        XCTAssertEqual(TrackpadSpeed.gains[3]/old[3],4)
        XCTAssertEqual(TrackpadSpeed.gains[6]/old[6],4)
        XCTAssertEqual(TrackpadSpeed.apply(.move(100,0),level:7),.move(1400,0))
    }
    func testAllLevelsDefaultAndOnlyMovementChanges() {
        let commands: [TrackpadCommand] = [.scroll(2,3),.click(1),.click(2),.secondaryClick,.dragBegan,.dragEnded]
        for level in 1...7 {
            let gain = TrackpadSpeed.gains[level-1]
            XCTAssertEqual(TrackpadSpeed.apply(.move(10,-4),level:level),.move(10*gain,-4*gain))
            for command in commands { XCTAssertEqual(TrackpadSpeed.apply(command,level:level),command) }
        }
        XCTAssertEqual(TrackpadSpeed.gains,[0.75,1.5,2.5,4,6,9,14])
        XCTAssertEqual(TrackpadSpeed.apply(.move(10,20),level:4),.move(40,80))
        XCTAssertEqual(TrackpadSpeed.gains.sorted(),TrackpadSpeed.gains)
        XCTAssertEqual(Set(TrackpadSpeed.gains).count,7)
    }
    func testPersistenceResetInvalidValuesAndLiveChanges() {
        let name = "DuoSpeedTests."+UUID().uuidString
        let defaults = UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        XCTAssertEqual(TrackpadSpeed.load(defaults),4)
        for level in 1...7 {
            TrackpadSpeed.save(level,to:defaults)
            XCTAssertEqual(TrackpadSpeed.load(defaults),level)
            XCTAssertEqual(TrackpadSpeed.load(UserDefaults(suiteName:name)!),level)
            XCTAssertEqual(TrackpadSpeed.apply(.move(1,0),level:TrackpadSpeed.load(defaults)),.move(TrackpadSpeed.gains[level-1],0))
        }
        TrackpadSpeed.save(4,to:defaults); XCTAssertEqual(TrackpadSpeed.load(defaults),4)
        TrackpadSpeed.save(99,to:defaults); XCTAssertEqual(TrackpadSpeed.load(defaults),4)
    }
    func testAllGainsAcrossArrangedScaledRotatedBoundsAndCleanup() {
        for level in 1...7 {
            for screens in [[CGRect(x:-1728,y:0,width:1728,height:1117),CGRect(x:0,y:0,width:500,height:900)],
                            [CGRect(x:0,y:-600,width:900,height:600),CGRect(x:0,y:0,width:1728,height:1117)]] {
                let current = CGPoint(x:0,y:0)
                guard case .move(let dx,let dy) = TrackpadSpeed.apply(.move(10,10),level:level) else { return XCTFail() }
                XCTAssertEqual(PointerMapping.relative(from:current,dx:dx,dy:dy,displays:screens),CGPoint(x:dx,y:dy))
            }
            var gesture = TrackpadGestureState()
            _ = gesture.update(points:[.zero],time:0); _ = gesture.advance(time:0.5)
            XCTAssertEqual(TrackpadSpeed.apply(gesture.cancel()[0],level:level),.dragEnded)
            XCTAssertEqual(gesture.update(points:[],time:0.6),[])
        }
        guard case .move(let x,let y) = TrackpadSpeed.apply(.move(1000,-500),level:7) else { return XCTFail() }
        XCTAssertLessThanOrEqual(abs(x),2048); XCTAssertEqual(y/x,-0.5)
        XCTAssertNil(TrackpadSpeed.apply(.move(.nan,1),level:4))
    }
    func testSlowMovementSurvivesCursorQuantizationAndPreservesPhysicalMouse() {
        for level in 1...7 {
            var pointer = CGPoint(x:100,y:100)
            let input = InputInjector(displayID:CGMainDisplayID(),cursorProvider:{pointer},
                displaysProvider:{[CGRect(x:0,y:0,width:4000,height:2000)]},post:{pointer = $0.location})
            for _ in 0..<100 {
                guard case .move(let dx,let dy) = TrackpadSpeed.apply(.move(1,0),level:level) else { return XCTFail() }
                input.handleTrackpad(action:"move",dx:dx,dy:dy)
            }
            XCTAssertEqual(pointer.x,100+100*TrackpadSpeed.gains[level-1],accuracy:0.001)
            pointer = CGPoint(x:2000,y:800) // Independent physical Mac input.
            for _ in 0..<4 { input.handleTrackpad(action:"move",dx:0.25,dy:0) }
            XCTAssertEqual(pointer,CGPoint(x:2001,y:800))
            input.handleTrackpad(action:"move",dx:0.25,dy:0); input.releaseAll()
            input.handleTrackpad(action:"move",dx:0.75,dy:0)
            XCTAssertEqual(pointer,CGPoint(x:2001,y:800),"Mode/session cleanup retires fractional movement too")
        }
    }

}
final class MacConnectionOptionsTests: XCTestCase {
    let peer = TrustedPeerRegistry.Record(id:"mac",name:"My Mac")
    func testNewMacPairingIsPrimaryAndVisibleDespiteOtherRememberedMacs() {
        let rows = MacConnectionOption.make(remembered:[peer],available:[],nearby:[.init(token:"new",name:"New Mac")])
        XCTAssertEqual(rows.count,2); XCTAssertEqual(rows.last?.action,.pair("new"))
        XCTAssertEqual(rows.last?.title,"Pair & Connect")
    }
    func testRememberedButUnverifiedMacOffersApprovalRatherThanDeadConnect() {
        let rows = MacConnectionOption.make(remembered:[peer],available:[],nearby:[.init(token:"near",name:"My Mac")])
        XCTAssertEqual(rows.count,1); XCTAssertEqual(rows[0].action,.pair("near"))
        XCTAssertTrue(rows[0].detail.contains("Verify pairing"))
    }
    func testTrustedRouteWinsAndDuplicatePairingIsRemoved() {
        let rows = MacConnectionOption.make(remembered:[peer],available:["mac"],nearby:[.init(token:"near",name:"My Mac")])
        XCTAssertEqual(rows.count,1); XCTAssertEqual(rows[0].action,.connect("mac"))
        XCTAssertTrue(rows[0].enabled(busy:false,connected:false))
        XCTAssertFalse(rows[0].enabled(busy:true,connected:false))
        XCTAssertFalse(rows[0].enabled(busy:false,connected:true))
    }
    func testStaleDiscoveryRetryConnectedAndAmbiguousNames() {
        let ready = MacConnectionOption.make(remembered:[peer],available:["mac"],nearby:[])[0]
        let lost = MacConnectionOption.make(remembered:[peer],available:[],nearby:[])[0]
        XCTAssertNotEqual(ready.action,lost.action); XCTAssertEqual(lost.action,.search)
        let retry = MacConnectionOption.make(remembered:[peer],available:["mac"],nearby:[])[0]
        XCTAssertEqual(retry.action,.connect("mac"))
        XCTAssertEqual(MacConnectionOption.make(remembered:[peer],available:["mac"],nearby:[],connected:true)[0].action,.none)
        let ambiguous = MacConnectionOption.make(remembered:[peer],available:[],nearby:[.init(token:"a",name:"My Mac"),.init(token:"b",name:"My Mac")])
        XCTAssertEqual(ambiguous.count,3); XCTAssertEqual(ambiguous[0].action,.search)
    }
}
final class RemoteKeyboardTests: XCTestCase {
    func testControlsManualFallbackAndAccessoryDismissalRequireFreshIntent() {
        var state = KeyboardPresentationState()
        state.receive(report("editor",.unsupported,1,false))
        XCTAssertFalse(state.visible)
        state.openManually() // Existing controls action after sheet dismissal.
        XCTAssertTrue(state.visible); XCTAssertTrue(state.manual)
        state.recordInteraction(5); state.dismiss() // Native accessory Hide keyboard.
        for id in 1...5 { state.receive(report("editor",.editable,id,true)); XCTAssertFalse(state.visible) }
        state.receive(report("editor",.editable,6,false)); XCTAssertFalse(state.visible)
        state.receive(report("editor",.editable,6,true)); XCTAssertTrue(state.visible)
        state.receive(report("other-app",.notEditable,6,false)); XCTAssertFalse(state.visible)
        var gate = KeyboardAdmission()
        let queued = KeyboardCommand(sequence:1,focus:"editor",action:.text,text:"stale",manual:true)
        XCTAssertFalse(gate.accept(queued,focus:report("other-app",.notEditable,6,false),authenticated:true))
        state.receive(report("password",.secure,7,true)); state.openManually(); XCTAssertFalse(state.visible)
    }
    func report(_ token:String = "field", _ kind:KeyboardFocusReport.Kind = .editable,_ interaction:Int = 1,_ intent:Bool = true) -> KeyboardFocusReport {
        .init(token:token,kind:kind,interaction:interaction,phoneIntent:intent)
    }
    func testFocusRequiresRealWritableRoleAndSecureInputAlwaysWins() {
        for role in ["AXTextField","AXTextArea","AXComboBox"] {
            XCTAssertEqual(KeyboardFocusPolicy.kind(role:role,subrole:nil,writable:true,enabled:true,secureInput:false,permission:true),.editable)
            XCTAssertEqual(KeyboardFocusPolicy.kind(role:role,subrole:nil,writable:false,enabled:true,secureInput:false,permission:true),.unsupported)
        }
        XCTAssertEqual(KeyboardFocusPolicy.kind(role:"AXTextField",subrole:"AXSecureTextField",writable:true,enabled:true,secureInput:false,permission:true),.secure)
        XCTAssertEqual(KeyboardFocusPolicy.kind(role:"AXTextField",subrole:nil,writable:true,enabled:true,secureInput:true,permission:true),.secure)
        XCTAssertEqual(KeyboardFocusPolicy.kind(role:nil,subrole:nil,writable:false,enabled:false,secureInput:false,permission:false),.permissionRequired)
    }
    func testAutomaticPresentationDismissalSameFieldNewClickAndDelayedFocus() {
        var state = KeyboardPresentationState()
        state.receive(report("button",.notEditable)); XCTAssertFalse(state.visible)
        state.receive(report()); XCTAssertTrue(state.visible)
        state.dismiss(); state.receive(report()); XCTAssertFalse(state.visible)
        state.receive(report("field",.editable,1,false)); XCTAssertFalse(state.visible)
        state.receive(report("field",.editable,2)); XCTAssertTrue(state.visible)
        state.dismiss(); state.openManually(); XCTAssertTrue(state.visible)
    }
    func testAppSwitchDisconnectReconnectAndSecureManualFallback() {
        var state = KeyboardPresentationState(); state.receive(report()); XCTAssertTrue(state.visible)
        state.receive(report("other-app",.editable,1,false)); XCTAssertFalse(state.visible)
        state.openManually(); XCTAssertTrue(state.visible)
        state.receive(report("password",.secure,2)); XCTAssertFalse(state.visible)
        state.openManually(); XCTAssertFalse(state.visible)
        state.disconnect(); XCTAssertNil(state.focus)
        state.receive(report("new-connection",.editable,0,false)); XCTAssertFalse(state.visible)
        state.receive(report("manual-app",.unsupported,0,false)); state.openManually(); XCTAssertTrue(state.visible)
    }
    func testAdmissionBindsFocusAndSequenceAndRejectsSecureOrUnauthenticated() {
        var gate = KeyboardAdmission()
        let c = KeyboardCommand(sequence:1,focus:"field",action:.text,text:"hello 👋🏽")
        XCTAssertFalse(gate.accept(c,focus:report(),authenticated:false))
        XCTAssertFalse(gate.accept(c,focus:report("other"),authenticated:true))
        XCTAssertFalse(gate.accept(c,focus:report("field",.secure),authenticated:true))
        XCTAssertTrue(gate.accept(c,focus:report(),authenticated:true))
        XCTAssertFalse(gate.accept(c,focus:report(),authenticated:true))
        XCTAssertTrue(gate.accept(.init(sequence:2,focus:"field",action:.backspace,text:nil),focus:report(),authenticated:true))
    }
    func testCompositionUnicodeEmojiAndNoDuplicateCommit() {
        XCTAssertNil(KeyboardText.committed(KeyboardText.sentinel+"に",marked:true))
        let value = "日本語 👨‍👩‍👧‍👦 cafe\u{301}  \n next"
        XCTAssertEqual(KeyboardText.committed(KeyboardText.sentinel+value,marked:false),value)
        XCTAssertNil(KeyboardText.committed(KeyboardText.sentinel,marked:false))
        for limit in [2,20,1024] {
            let chunks = KeyboardText.chunks(value,maxUnits:limit)
            XCTAssertTrue(chunks.allSatisfy { $0.count <= limit })
            XCTAssertEqual(chunks.map { String(decoding:$0,as:UTF16.self) }.joined(),value)
        }
    }
    func testKeyboardViewportPreservesAspectRatioAndTouchMapping() {
        let video = CGSize(width:2668,height:1876)
        for size in [CGSize(width:430,height:900),CGSize(width:430,height:500),CGSize(width:900,height:200),CGSize(width:900,height:430)] {
            let bounds = CGRect(origin:.zero,size:size), rect = ReceiverViewport.rect(video:video,in:bounds)!
            XCTAssertTrue(bounds.contains(rect)); XCTAssertEqual(rect.width/rect.height,video.width/video.height,accuracy:0.0001)
            XCTAssertEqual((rect.midX-rect.minX)/rect.width,0.5,accuracy:0.000001)
            XCTAssertEqual((rect.midY-rect.minY)/rect.height,0.5,accuracy:0.000001)
        }
    }
    func testUnicodeBackspaceAndReturnPostPairedKeyEventsWithoutChangingFocus() {
        var events:[CGEvent] = []
        let injector = InputInjector(displayID:CGMainDisplayID(),post:{_ in XCTFail("Must not touch real pointer")})
        let text = "Hello 🌎 e\u{301}"
        injector.handleKeyboard(.init(sequence:1,focus:"field",action:.text,text:text),to:1,post:{events.append($0)})
        XCTAssertEqual(events.map(\.type),[.keyDown,.keyUp])
        var length = 0, chars = [UniChar](repeating:0,count:64)
        events[0].keyboardGetUnicodeString(maxStringLength:64,actualStringLength:&length,unicodeString:&chars)
        XCTAssertEqual(String(decoding:chars.prefix(length),as:UTF16.self),text)
        injector.handleKeyboard(.init(sequence:2,focus:"field",action:.backspace,text:nil),to:1,post:{events.append($0)})
        XCTAssertEqual(events.last?.getIntegerValueField(.keyboardEventKeycode),51)
        injector.handleKeyboard(.init(sequence:3,focus:"field",action:.enter,text:nil),to:1,post:{events.append($0)})
        XCTAssertEqual(events.last?.getIntegerValueField(.keyboardEventKeycode),36)
    }
    func testManualIntentIsRequiredForUnsupportedEditorsAndDeliveryLedgerNeverReplays() {
        var gate = KeyboardAdmission()
        let focus = report("manual",.unsupported)
        XCTAssertFalse(gate.accept(.init(sequence:1,focus:"manual",action:.text,text:"hi"),focus:focus,authenticated:true))
        XCTAssertTrue(gate.accept(.init(sequence:1,focus:"manual",action:.text,text:"hi",manual:true),focus:focus,authenticated:true))
        var ledger = KeyboardDeliveryLedger()
        XCTAssertTrue(ledger.register(1,focus:"field"))
        XCTAssertFalse(ledger.complete(1,focus:"wrong-session"))
        XCTAssertTrue(ledger.complete(1,focus:"field"))
        XCTAssertFalse(ledger.complete(1,focus:"field"))
        XCTAssertEqual(ledger.count,0)
        _ = ledger.register(2,focus:"field"); ledger.reset(); XCTAssertEqual(ledger.count,0)
    }

    func testKeyboardJobsCannotOutliveTheirStreamOrDeadline() {
        let gate = KeyboardSessionGuard(), first = UUID()
        XCTAssertFalse(gate.perform(first,expires:.infinity) { XCTFail(); return true })
        let session = gate.begin()
        XCTAssertTrue(gate.perform(session,expires:ProcessInfo.processInfo.systemUptime+1) { true })
        XCTAssertFalse(gate.perform(session,expires:0) { XCTFail(); return true })
        gate.invalidate()
        XCTAssertFalse(gate.perform(session,expires:.infinity) { XCTFail(); return true })
        let replacement = gate.begin()
        XCTAssertNotEqual(session,replacement); XCTAssertFalse(gate.matches(session))
    }

    func testDismissalAlsoSuppressesReportsFromAnAlreadySentClick() {
        var state = KeyboardPresentationState()
        state.receive(report()); XCTAssertTrue(state.visible)
        state.recordInteraction(2) // Phone click sent, Mac's AX report still in flight.
        state.dismiss()
        state.receive(report("field",.editable,2)); XCTAssertFalse(state.visible)
        state.recordInteraction(3)
        state.receive(report("field",.editable,3)); XCTAssertTrue(state.visible)
        state.recordInteraction(4) // Return deliberately moves to a new form field.
        state.receive(report("next-field",.editable,4)); XCTAssertTrue(state.visible)
    }

}

final class KeyboardZoomViewportTests:XCTestCase {
    func testKeyboardAvoidanceTracksCurrentOrientationAndIgnoresAccessoryOnly() {
        XCTAssertTrue(ReceiverViewport.hasSoftwareKeyboard(window:CGRect(x:0,y:0,width:430,height:900),viewport:CGRect(x:0,y:0,width:430,height:550)))
        XCTAssertTrue(ReceiverViewport.hasSoftwareKeyboard(window:CGRect(x:0,y:0,width:678,height:466),viewport:CGRect(x:0,y:0,width:678,height:225)))
        XCTAssertFalse(ReceiverViewport.hasSoftwareKeyboard(window:CGRect(x:0,y:0,width:430,height:900),viewport:CGRect(x:0,y:0,width:430,height:850)))
        XCTAssertFalse(ReceiverViewport.hasSoftwareKeyboard(window:CGRect(x:0,y:0,width:678,height:466),viewport:CGRect(x:0,y:0,width:678,height:466)))
    }

    func testFocusedViewportCoversEveryOrientationWithoutStretching() throws {
        for video in [CGSize(width:1440,height:900),CGSize(width:900,height:1440)] {
            for size in [CGSize(width:430,height:480),CGSize(width:900,height:160),CGSize(width:950,height:600)] {
                let bounds = CGRect(origin:.zero,size:size)
                var viewport = KeyboardZoomViewport()
                viewport.focus(CGRect(x:0.2,y:0.75,width:0.5,height:0.06),fallback:.zero)
                let rect = try XCTUnwrap(viewport.rect(video:video,in:bounds))
                XCTAssertLessThanOrEqual(rect.minX,bounds.minX);XCTAssertLessThanOrEqual(rect.minY,bounds.minY)
                XCTAssertGreaterThanOrEqual(rect.maxX,bounds.maxX);XCTAssertGreaterThanOrEqual(rect.maxY,bounds.maxY)
                XCTAssertEqual(rect.width/rect.height,video.width/video.height,accuracy:0.00001)
                let field = CGPoint(x:rect.minX+0.45*rect.width,y:rect.minY+0.78*rect.height)
                XCTAssertTrue(bounds.contains(field),"Focused edit area remains visible")
            }
        }
    }
    func testPinchKeepsAnchorAndMapsDirectTouchIntoDesktop() throws {
        let video = CGSize(width:1440,height:900),bounds = CGRect(x:0,y:0,width:400,height:300)
        let point = CGPoint(x:200,y:150)
        var viewport = KeyboardZoomViewport();viewport.focus(nil,fallback:CGPoint(x:0.5,y:0.5))
        let before = try XCTUnwrap(viewport.rect(video:video,in:bounds))
        let x = (point.x-before.minX)/before.width,y = (point.y-before.minY)/before.height
        viewport.pinch(2,at:point,video:video,in:bounds)
        let after = try XCTUnwrap(viewport.rect(video:video,in:bounds))
        XCTAssertEqual((point.x-after.minX)/after.width,x,accuracy:0.00001)
        XCTAssertEqual((point.y-after.minY)/after.height,y,accuracy:0.00001)
        viewport.pan(CGPoint(x:20,y:-30),video:video,in:bounds)
        let panned = try XCTUnwrap(viewport.rect(video:video,in:bounds))
        XCTAssertEqual(panned.minX-after.minX,20,accuracy:0.00001)
        XCTAssertEqual(panned.minY-after.minY,-30,accuracy:0.00001)
    }
    func testBoundsClampingZoomLimitsAndBadMetadata() throws {
        var viewport = KeyboardZoomViewport()
        let video = CGSize(width:1000,height:2000),bounds = CGRect(x:0,y:0,width:400,height:300)
        viewport.focus(CGRect(x:CGFloat.nan,y:0,width:1,height:1),fallback:CGPoint(x:0.5,y:0.5))
        viewport.pinch(100,at:CGPoint(x:200,y:150),video:video,in:bounds)
        XCTAssertEqual(viewport.zoom,6)
        viewport.pan(CGPoint(x:1e6,y:-1e6),video:video,in:bounds)
        let rect = try XCTUnwrap(viewport.rect(video:video,in:bounds))
        XCTAssertTrue(rect.contains(bounds))
        viewport.pinch(0.001,at:.zero,video:video,in:bounds);XCTAssertEqual(viewport.zoom,1)
        viewport.pinch(.nan,at:.zero,video:video,in:bounds);XCTAssertEqual(viewport.zoom,1)
        XCTAssertNil(viewport.rect(video:.zero,in:bounds))
        viewport.focus(nil,fallback:CGPoint(x:0.2,y:0.8));XCTAssertEqual(viewport.zoom,1)
    }
    func testFocusGeometryIsOptionalForExistingPeersAndDoesNotBypassIntent() throws {
        let old = Data(#"{"token":"field","kind":"editable","interaction":1,"phoneIntent":true}"#.utf8)
        let report = try JSONDecoder().decode(KeyboardFocusReport.self,from:old)
        XCTAssertNil(report.region)
        let new = KeyboardFocusReport(token:"field",kind:.editable,interaction:1,phoneIntent:true,region:CGRect(x:0.2,y:0.8,width:0.5,height:0.05))
        XCTAssertEqual(try JSONDecoder().decode(KeyboardFocusReport.self,from:JSONEncoder().encode(new)),new)
        var state = KeyboardPresentationState();state.receive(new);XCTAssertTrue(state.visible)
        state.dismiss();state.receive(new);XCTAssertFalse(state.visible)
        state.receive(.init(token:"secure",kind:.secure,interaction:2,phoneIntent:true,region:.zero));XCTAssertFalse(state.visible)
    }
}
