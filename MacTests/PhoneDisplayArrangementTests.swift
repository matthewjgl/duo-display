import XCTest
import CoreGraphics

@MainActor
final class PhoneDisplayArrangementTests: XCTestCase {
    func display(_ id:UInt32,_ rect:CGRect,scale:Double = 2,rotation:Double = 0,mode:UInt32 = 1,mirrored:Bool = false,identity:String? = nil) -> PhoneDisplay {
        .init(id:id,identity:identity ?? "device-\(id)",name:id == 1 ? "Mac main display" : "Display \(id)",frame:rect,scale:scale,rotation:rotation,mode:mode,mirrored:mirrored)
    }
    func layout() -> PhoneDisplayTopology {
        .init(main:1,displays:[display(1,CGRect(x:0,y:0,width:1000,height:800)),display(2,CGRect(x:1000,y:0,width:400,height:600))])
    }
    let context = PhoneArrangementController.Context(session:"stream-A",target:2,unavailable:nil)
    func request(_ action:PhoneArrangementRequest.Action = .place,_ side:PhoneDisplayPlacement? = .left,_ revision:String) -> PhoneArrangementRequest {
        .init(action:action,requestID:UUID().uuidString,revision:revision,placement:side)
    }
    func testAllFourPlacementsAndUndoReadBackActualWithoutChangingMain() async {
        let expected:[PhoneDisplayPlacement:CGPoint] = [.left:CGPoint(x:-400,y:100),.right:CGPoint(x:1000,y:100),.above:CGPoint(x:300,y:-600),.below:CGPoint(x:300,y:800)]
        for side in PhoneDisplayPlacement.allCases {
            var world = layout(),calls = 0,persisted:[PhoneDisplay] = []
            let initial = world
            let controller = PhoneArrangementController(read:{world},configure:{ before,desired in
                XCTAssertEqual(world,before); world = desired; calls += 1
            },settleNanoseconds:0,persist:{persisted.append($0)})
            let preview = controller.snapshot(context)
            XCTAssertEqual(PhoneArrangementGeometry.origin(side,topology:preview.topology,target:2),expected[side])
            let result = await controller.handle(request(.place,side,preview.revision),context:context,stillCurrent:{true})
            XCTAssertTrue(result.applied); XCTAssertTrue(result.canUndo); XCTAssertFalse(result.busy)
            XCTAssertEqual(world.displays[0],initial.displays[0]); XCTAssertEqual(world.main,1)
            XCTAssertEqual(world.displays[1].frame.origin,expected[side]); XCTAssertEqual(result.topology,world)
            let undo = await controller.handle(request(.undo,nil,result.revision),context:context,stillCurrent:{true})
            XCTAssertTrue(undo.applied); XCTAssertFalse(undo.canUndo); XCTAssertEqual(world,initial)
            XCTAssertEqual(calls,2); XCTAssertEqual(persisted.count,2)
        }
    }
    func testOccupiedEdgesAndBridgeAreRejectedInsteadOfMovingOtherMonitors() async {
        let main = display(1,CGRect(x:0,y:0,width:1000,height:800))
        let phone = display(2,CGRect(x:-400,y:0,width:400,height:600))
        let other = display(3,CGRect(x:1000,y:0,width:800,height:800),scale:1)
        var world = PhoneDisplayTopology(main:1,displays:[main,phone,other]),calls = 0
        XCTAssertNil(PhoneArrangementGeometry.origin(.right,topology:world,target:2))
        let controller = PhoneArrangementController(read:{world},configure:{_,desired in calls += 1; world = desired},settleNanoseconds:0)
        let result = await controller.handle(request(.place,.right,controller.snapshot(context).revision),context:context,stillCurrent:{true})
        XCTAssertFalse(result.applied); XCTAssertEqual(calls,0); XCTAssertEqual(world.displays[2],other)
        let bridge = PhoneDisplayTopology(main:1,displays:[main,display(2,CGRect(x:1000,y:0,width:400,height:600)),display(3,CGRect(x:1400,y:0,width:400,height:600))])
        XCTAssertNil(PhoneArrangementGeometry.origin(.left,topology:bridge,target:2))
        XCTAssertTrue(PhoneArrangementGeometry.validLayout(bridge))
    }
    func testLogicalScalingRotationNegativeOriginsAndPointerMapping() {
        for scale in [1.0,2.0,3.0] {
            for size in [CGSize(width:400,height:600),CGSize(width:600,height:400)] {
                let topology = PhoneDisplayTopology(main:1,displays:[display(1,CGRect(x:0,y:0,width:1728,height:1117),scale:2),display(2,CGRect(origin:CGPoint(x:1728,y:0),size:size),scale:scale,rotation:size.width > size.height ? 90 : 0)])
                for side in PhoneDisplayPlacement.allCases {
                    let origin = PhoneArrangementGeometry.origin(side,topology:topology,target:2)!
                    let moved = topology.placing(2,at:origin)
                    XCTAssertTrue(PhoneArrangementGeometry.validLayout(moved))
                    XCTAssertEqual(moved.displays[1].frame.size,size)
                    let rect = moved.displays[1].frame
                    XCTAssertTrue(rect.contains(CGPoint(x:rect.minX+rect.width/2,y:rect.minY+rect.height/2)))
                    if side == .left {
                        let y = max(0,rect.minY)+10
                        XCTAssertEqual(PointerMapping.relative(from:CGPoint(x:1,y:y),dx:-2,dy:0,displays:moved.displays.map(\.frame)),CGPoint(x:-1,y:y))
                    }
                }
            }
        }
    }
    func testRealInputInjectorReadsTheNewLogicalOriginAfterEachArrangement() {
        var world = layout(); var events:[CGEvent] = []
        let input = InputInjector(displayID:2,boundsProvider:{ id in world.displays.first(where:{$0.id == id})!.frame },post:{ events.append($0) })
        for side in PhoneDisplayPlacement.allCases {
            let origin = PhoneArrangementGeometry.origin(side,topology:world,target:2)!
            world = world.placing(2,at:origin)
            input.handleTouch(phase:"began",x:0.5,y:0.5)
            XCTAssertEqual(events.last?.location,CGPoint(x:origin.x+200,y:origin.y+300))
            input.handleTouch(phase:"ended",x:0.5,y:0.5)
        }
        world = .init(main:1,displays:[world.displays[0],display(2,CGRect(x:-600,y:0,width:600,height:400),rotation:90)])
        input.handleTouch(phase:"began",x:0.25,y:0.75)
        XCTAssertEqual(events.last?.location,CGPoint(x:-450,y:300))
        input.releaseAll()
    }
    func testStaleTopologyRotationRecycledIDsReconnectAndReplayNeverWrite() async {
        var world = layout(),calls = 0
        let controller = PhoneArrangementController(read:{world},configure:{_,desired in world = desired; calls += 1},settleNanoseconds:0)
        let old = controller.snapshot(context)
        world = .init(main:1,displays:[world.displays[0],display(2,CGRect(x:1000,y:0,width:600,height:400),rotation:90,mode:2)])
        let stale = await controller.handle(request(.place,.left,old.revision),context:context,stillCurrent:{true})
        XCTAssertFalse(stale.applied); XCTAssertEqual(calls,0)
        let request = request(.place,.left,stale.revision)
        let applied = await controller.handle(request,context:context,stillCurrent:{true})
        XCTAssertTrue(applied.applied); XCTAssertEqual(calls,1)
        let replay = await controller.handle(request,context:context,stillCurrent:{true})
        XCTAssertFalse(replay.applied); XCTAssertEqual(calls,1)
        let freshContext = PhoneArrangementController.Context(session:"stream-B",target:2,unavailable:nil)
        let reconnect = controller.snapshot(freshContext)
        XCTAssertFalse(reconnect.canUndo); XCTAssertNotEqual(reconnect.revision,applied.revision)
        let staleUndo = await controller.handle(self.request(.undo,nil,applied.revision),context:freshContext,stillCurrent:{true})
        XCTAssertFalse(staleUndo.applied); XCTAssertEqual(calls,1)
        world = .init(main:1,displays:[world.displays[0],display(2,world.displays[1].frame,identity:"replacement-phone")])
        XCTAssertNotEqual(controller.snapshot(freshContext).revision,reconnect.revision)
    }
    func testMirroringPrimaryAndUnavailableContextDisableWithoutConfiguring() async {
        for kind in 0..<3 {
            var world = layout(); var ctx = context
            if kind == 0 { world = .init(main:1,displays:[world.displays[0],display(2,world.displays[1].frame,mirrored:true)]) }
            if kind == 1 { world = .init(main:2,displays:world.displays) }
            if kind == 2 { ctx = .init(session:"a",target:nil,unavailable:"Disconnected") }
            let controller = PhoneArrangementController(read:{world},configure:{_,_ in XCTFail("Disabled arrangement must not configure")},settleNanoseconds:0)
            let report = controller.snapshot(ctx); XCTAssertNotNil(report.unavailable)
            let result = await controller.handle(request(.place,.left,report.revision),context:ctx,stillCurrent:{true})
            XCTAssertFalse(result.applied)
        }
    }
    func testFailedAndSnappedConfigurationRestoresPriorLayoutWithoutPersisting() async {
        var world = layout(),calls = 0,saves = 0
        let initial = world
        let controller = PhoneArrangementController(read:{world},configure:{_,desired in
            calls += 1
            if calls == 1 { world = desired.placing(2,at:CGPoint(x:-400,y:0)) }
            else { world = desired }
        },settleNanoseconds:0,persist:{_ in saves += 1})
        let result = await controller.handle(request(.place,.above,controller.snapshot(context).revision),context:context,stillCurrent:{true})
        XCTAssertFalse(result.applied); XCTAssertFalse(result.canUndo); XCTAssertEqual(world,initial)
        XCTAssertEqual(calls,2); XCTAssertEqual(saves,0); XCTAssertTrue(result.message?.contains("restored") == true)
    }
    func testExternalTopologyChangeIsReportedAndNeverRolledBackBlindly() async {
        var world = layout(),calls = 0
        let controller = PhoneArrangementController(read:{world},configure:{_,desired in
            calls += 1
            world = .init(main:1,displays:desired.displays+[self.display(3,CGRect(x:1000,y:0,width:1000,height:800))])
        },settleNanoseconds:0)
        let result = await controller.handle(request(.place,.left,controller.snapshot(context).revision),context:context,stillCurrent:{true})
        XCTAssertFalse(result.applied); XCTAssertEqual(calls,1); XCTAssertEqual(result.topology,world)
        XCTAssertTrue(result.message?.contains("topology changed") == true)
    }
    func testStaleSessionAndNoOpNeverConfigure() async {
        let world = layout()
        let controller = PhoneArrangementController(read:{world},configure:{_,_ in XCTFail("No write expected")},settleNanoseconds:0)
        let report = controller.snapshot(context)
        _ = await controller.handle(request(.place,.left,report.revision),context:context,stillCurrent:{false})
        let centered = world.placing(2,at:CGPoint(x:1000,y:100))
        let noOp = PhoneArrangementController(read:{centered},configure:{_,_ in XCTFail("No-op must not fade screens")},settleNanoseconds:0)
        let result = await noOp.handle(request(.place,.right,noOp.snapshot(context).revision),context:context,stillCurrent:{true})
        XCTAssertFalse(result.applied); XCTAssertFalse(result.canUndo)
    }
    func testUndoExpiresAfterMacChangesLayout() async {
        var world = layout()
        let controller = PhoneArrangementController(read:{world},configure:{_,desired in world = desired},settleNanoseconds:0)
        let applied = await controller.handle(request(.place,.left,controller.snapshot(context).revision),context:context,stillCurrent:{true})
        XCTAssertTrue(applied.canUndo)
        world = world.placing(2,at:CGPoint(x:-400,y:0))
        XCTAssertFalse(controller.snapshot(context).canUndo)
    }
}

extension PhoneDisplayArrangementTests {
    func testPublicModeScaleUsesBackingPixelsWithoutScalingArrangementOrigins() {
        XCTAssertEqual(PublicDisplayArrangement.backingScale(logicalWidth:2056,pixelWidth:4112),2)
        XCTAssertEqual(PublicDisplayArrangement.backingScale(logicalWidth:2560,pixelWidth:2560),1)
        XCTAssertEqual(PublicDisplayArrangement.backingScale(logicalWidth:0,pixelWidth:0),1)
        let topology = layout()
        XCTAssertEqual(PhoneArrangementGeometry.origin(.right,topology:topology,target:2)?.x,1000)
    }
    func testRollbackReadbackFailureIsNeverReportedAsRestored() async {
        var world = layout(),calls = 0
        let controller = PhoneArrangementController(read:{world},configure:{_,_ in
            calls += 1
            if calls == 1 { world = world.placing(2,at:CGPoint(x:-400,y:0)) }
        },settleNanoseconds:0)
        let result = await controller.handle(request(.place,.above,controller.snapshot(context).revision),context:context,stillCurrent:{true})
        XCTAssertFalse(result.applied); XCTAssertEqual(calls,2)
        XCTAssertTrue(result.message?.contains("could not be confirmed") == true)
        XCTAssertEqual(result.topology,world)
    }
    func testAPIFailureBeforeCommitPreservesWorkingLayoutAndPreferences() async {
        let world = layout(); var saves = 0
        let controller = PhoneArrangementController(read:{world},configure:{_,_ in throw PhoneArrangementController.Failure.changed },settleNanoseconds:0,persist:{_ in saves += 1})
        let result = await controller.handle(request(.place,.left,controller.snapshot(context).revision),context:context,stillCurrent:{true})
        XCTAssertFalse(result.applied); XCTAssertEqual(result.topology,world); XCTAssertFalse(result.canUndo); XCTAssertEqual(saves,0)
    }
    func testSimultaneousRequestsCannotProduceCompetingTransactions() async {
        var world = layout(),calls = 0
        var release:CheckedContinuation<Void,Never>?
        let started = expectation(description:"configuration started")
        let controller = PhoneArrangementController(read:{world},configure:{_,desired in
            calls += 1
            await withCheckedContinuation { release = $0; started.fulfill() }
            world = desired
        },settleNanoseconds:0)
        let initial = controller.snapshot(context)
        let firstRequest = request(.place,.left,initial.revision)
        let task = Task { @MainActor in await controller.handle(firstRequest,context:context,stillCurrent:{true}) }
        await fulfillment(of:[started],timeout:2)
        let second = await controller.handle(request(.place,.above,initial.revision),context:context,stillCurrent:{true})
        XCTAssertTrue(second.busy); XCTAssertFalse(second.applied); XCTAssertEqual(calls,1)
        release?.resume()
        let result = await task.value
        XCTAssertTrue(result.applied); XCTAssertEqual(calls,1)
    }
    func testSessionCancellationBeforeCommitDoesNotWrite() async {
        var world = layout(),connected = true,calls = 0
        let controller = PhoneArrangementController(read:{world},configure:{_,desired in
            calls += 1; connected = false
            guard connected else { throw PhoneArrangementController.Failure.changed }
            world = desired
        },settleNanoseconds:0)
        let before = world
        let result = await controller.handle(request(.place,.below,controller.snapshot(context).revision),context:context,stillCurrent:{connected})
        XCTAssertFalse(result.applied); XCTAssertEqual(calls,1); XCTAssertEqual(world,before)
    }
}
