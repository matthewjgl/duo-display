import XCTest
import Network
import CryptoKit
import AVFoundation
import Combine

@MainActor
final class TrustedConnectionTests: XCTestCase {
    /// The integration stream starts with an actual TCP pairing exchange and
    /// matching-code approval on both coordinators. Secrets are injected into
    /// the subsequent app transport, rather than stored in the real Keychain.
    private func approvedPairKey() async throws -> SymmetricKey {
        var macKey: SymmetricKey?, phoneKey: SymmetricKey?
        let mac = PairingApprovalCoordinator(ownID: "mac", save: { macKey = $0; XCTAssertEqual($1,"phone") })
        let phone = PairingApprovalCoordinator(ownID: "phone", save: { phoneKey = $0; XCTAssertEqual($1,"mac") })
        let listener = try NWListener(using: .tcp)
        let ready = expectation(description: "first-pair listener")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        var server: PairingExchange?
        let both = expectation(description: "both explicit approvals persisted"); both.expectedFulfillmentCount = 2
        listener.newConnectionHandler = { c in
            Task { @MainActor in
                let exchange = PairingExchange(connection:c, coordinator:mac, ownID:"mac", name:"QA Mac", initiator:false)
                server = exchange
                exchange.onPrompt = { if phone.prompt != nil { XCTAssertEqual(phone.prompt?.code, mac.prompt?.code); mac.approve(); phone.approve() } }
                exchange.onComplete = { _,_ in both.fulfill() }
                exchange.onFailure = { XCTFail("Pairing failed: \($0)") }
                exchange.start()
            }
        }
        listener.start(queue:.main); await fulfillment(of:[ready],timeout:5)
        let c = NWConnection(host:"127.0.0.1",port:try XCTUnwrap(listener.port),using:.tcp)
        let exchange = PairingExchange(connection:c,coordinator:phone,ownID:"phone",name:"QA Phone",initiator:true)
        exchange.onPrompt = { if mac.prompt != nil { XCTAssertEqual(phone.prompt?.code, mac.prompt?.code); mac.approve(); phone.approve() } }
        exchange.onComplete = { _,_ in both.fulfill() }
        exchange.onFailure = { XCTFail("Pairing failed: \($0)") }
        exchange.start(); await fulfillment(of:[both],timeout:5)
        listener.cancel(); c.cancel(); server?.cancel()
        let key = try XCTUnwrap(macKey)
        XCTAssertTrue(TrustedConnections.sameKey(key,try XCTUnwrap(phoneKey)))
        return key
    }
    func testMissingStoredKeyCannotMisindexAnotherPeersListener() async throws {
        let key = SymmetricKey(size: .bits256)
        let mac = TrustedConnections(ownID: "mac", lookup: { $0 == "phone" ? key : nil }, peers: { ["missing", "phone"] })
        mac.serve(name: "QA key lookup") { _, _, _ in XCTFail("No request was authorized"); return "Unavailable" }
        for _ in 0..<100 {
            if mac.listeningPort(for: "phone") != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(mac.listeningPort(for: "missing"))
        XCTAssertNotNil(mac.listeningPort(for: "phone"))
    }
    func testPhoneRequestStartsAuthenticatedReceiverAndCarriesTouch() async throws {
        let key = try await approvedPairKey()
        let mac = TrustedConnections(ownID: "mac", lookup: { _ in key }, peers: { ["phone"] })
        let phone = TrustedConnections(ownID: "phone", lookup: { _ in key }, peers: { ["mac"] })
        defer { mac.shutdown(); phone.shutdown() }
        let receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(), deviceKind: "iPhone", fallbackServiceName: "QA")
        var liveSpeed = 4
        receiver.trackpadSpeedLevel = { liveSpeed }
        receiver.gesturePreferences = { var p = TrackpadGesturePreferences();p.enabled = true;return p }
        let shortcutDelivered = expectation(description:"shortcut over authenticated streaming session")
        var gestureGate = TrackpadGestureAdmission()
        let keyboard = expectation(description:"Unicode keyboard input over authenticated stream")
        let speedUpdates = expectation(description:"all speed levels over one live stream"); speedUpdates.expectedFulfillmentCount = 1
        let focus = KeyboardFocusReport(token:"fixture-field",kind:.editable,interaction:1,phoneIntent:true,region:CGRect(x:0.2,y:0.75,width:0.65,height:0.06))
        var keyboardGate = KeyboardAdmission()
        var speedDisplacement = 0.0
        var speedMoves = 0
        var keyboardPackets: [Int:Int] = [:]
        let rejection = expectation(description:"rejected keyboard input surfaces failure")
        let missingAck = expectation(description:"missing keyboard ack surfaces uncertainty without resend")
        let keyboardErrors = receiver.$keyboardError.sink { error in
            if error?.contains("focus or access changed") == true { rejection.fulfill() }
            if error?.contains("was not confirmed") == true { missingAck.fulfill() }
        }
        var keyboardSent = false
        let keyboardSubscription = receiver.$keyboardPresentation.sink { state in
            if state.visible && !keyboardSent {
                keyboardSent = true
                Task { @MainActor in
                    receiver.sendKeyboard(.text,text:"日本語 👨‍👩‍👧‍👦 e\u{301}")
                }
            }
        }
        let layoutApplied = expectation(description:"authenticated arrangement applies and reads back actual simulated layout")
        let layoutUndone = expectation(description:"authenticated undo restores simulated layout")
        let mainDisplay = PhoneDisplay(id:1,identity:"fixture-main",name:"Mac main display",frame:CGRect(x:0,y:0,width:1000,height:800),scale:2,rotation:0,mode:1,mirrored:false)
        let phoneDisplay = PhoneDisplay(id:2,identity:"fixture-phone",name:"Phone",frame:CGRect(x:1000,y:0,width:400,height:600),scale:2,rotation:0,mode:1,mirrored:false)
        var world = PhoneDisplayTopology(main:1,displays:[mainDisplay,phoneDisplay])
        let originalLayout = world
        var configurationCalls = 0,resetPackets = 0,arrangementStage = 0
        let arrangement = PhoneArrangementController(read:{world},configure:{ before,desired in
            XCTAssertEqual(world,before); world = desired; configurationCalls += 1
        },settleNanoseconds:0)
        let arrangementContext = PhoneArrangementController.Context(session:"fixture-stream",target:2,unavailable:nil)
        let arrangementCapability = receiver.$macSupportsArrangement.sink { supported in
            if supported { Task { @MainActor in receiver.watchPhoneArrangement(true) } }
        }
        let arrangementUpdates = receiver.$phoneArrangement.sink { report in
            guard let report else { return }
            if arrangementStage == 0 {
                arrangementStage = 1
                XCTAssertNotNil(PhoneArrangementGeometry.origin(.left,topology:report.topology,target:2))
                Task { @MainActor in receiver.arrangePhone(.left,revision:report.revision) }
            } else if arrangementStage == 1 && report.applied {
                arrangementStage = 2; XCTAssertTrue(report.canUndo)
                XCTAssertEqual(report.topology.displays[1].frame.minX,-400)
                XCTAssertEqual(report.topology.displays[0],mainDisplay)
                layoutApplied.fulfill()
                Task { @MainActor in receiver.arrangePhone(undo:true,revision:report.revision) }
            } else if arrangementStage == 2 && report.applied && !report.canUndo {
                arrangementStage = 3; XCTAssertEqual(report.topology,originalLayout); layoutUndone.fulfill()
            }
        }
        let stream = expectation(description: "authenticated stream hello")
        let userClosing = expectation(description:"explicit user disconnect announces closing")
        let input = expectation(description: "touch on authenticated stream")
        let relativeInput = expectation(description: "relative input carried by authenticated video session")
        let reset = expectation(description: "input reset carried by same secure session")
        var pointer = CGPoint(x: 95, y: 30)
        var posted: [CGEvent] = []
        let injector = InputInjector(displayID: CGMainDisplayID(), cursorProvider: { pointer },
            displaysProvider: { [CGRect(x:0,y:0,width:100,height:100), CGRect(x:100,y:0,width:100,height:100)] },
            post: { posted.append($0); pointer = $0.location })
        let inputSubscription = receiver.$macSupportsTrackpad.sink { supported in
            if supported {
                Task { @MainActor in
                    receiver.sendTrackpad(.dragBegan)
                    receiver.sendTrackpad(.move(20, 0))
                    receiver.resetInputs()
                    for level in 1...7 { liveSpeed = level; receiver.sendTrackpad(.move(1,0)) }
                    liveSpeed = 4
                }
            }
        }
        let video = expectation(description: "H264 delivered and receiver format decoded")
        let subscription = receiver.$videoSize.sink { size in
            if size.width == 640 && size.height == 360 { video.fulfill() }
        }
        let frame = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/paired-frame.h264"))
        var sender: NWConnection?
        var requests = 0
        func read(_ c: NWConnection) {
            c.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, error in
                guard error == nil, let header, header.count == 4 else { return }
                let count = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
                guard count > 0, count < 65536 else { return }
                c.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, _ in
                    guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                    if object["type"] as? String == "hello" {
                        stream.fulfill()
                        let welcome = Data("{\"type\":\"welcome\",\"pv\":7,\"min\":1,\"trackpad\":true,\"keyboard\":true,\"displayArrangement\":true,\"shortcutGestures\":true}".utf8)
                        var welcomeLength = UInt32(welcome.count).bigEndian
                        var welcomePacket = Data(bytes: &welcomeLength, count: 4); welcomePacket.append(welcome)
                        c.send(content: welcomePacket, completion: .contentProcessed { _ in })
                        var length = UInt32(frame.count).bigEndian
                        var packet = Data(bytes: &length, count: 4); packet.append(frame)
                        c.send(content: packet, completion: .contentProcessed { _ in })
                        Task { @MainActor in receiver.sendTouch(phase: "began", x: 0.5, y: 0.5) }
                    }
                    if object["type"] as? String == "touch" { input.fulfill() }
                    if object["type"] as? String == WireMessage.closing { userClosing.fulfill() }
                    if object["type"] as? String == "trackpadGesture" {
                        let request = try! JSONDecoder().decode(TrackpadGestureRequest.self,from:data)
                        XCTAssertTrue(gestureGate.accept(request,authenticated:true,now:ProcessInfo.processInfo.systemUptime))
                        var keys:[CGEvent] = []
                        XCTAssertTrue(injector.handleGestureShortcut(request.shortcut,post:{keys.append($0)},secureInput:false))
                        XCTAssertEqual(keys.map(\.type),[.keyDown,.keyUp])
                        XCTAssertEqual(keys.first?.getIntegerValueField(.keyboardEventKeycode),126)
                        let ack = try! JSONSerialization.data(withJSONObject:["type":"trackpadGestureResult","id":request.id,"accepted":true])
                        var length = UInt32(ack.count).bigEndian
                        var packet = Data(bytes:&length,count:4);packet.append(ack)
                        c.send(content:packet,completion:.contentProcessed{_ in})
                        shortcutDelivered.fulfill()
                    }
                    if object["type"] as? String == "trackpad" {
                        let action = object["action"] as? String ?? ""
                        injector.handleTrackpad(action: action, dx: object["dx"] as? Double ?? 0, dy: object["dy"] as? Double ?? 0)
                        if action == "move" {
                            if speedMoves == 0 {
                                XCTAssertEqual(posted.last?.type, .leftMouseDragged)
                                XCTAssertEqual(posted.last?.location, CGPoint(x:95 + 20 * TrackpadSpeed.gains[TrackpadSpeed.defaultLevel-1],y:30))
                                relativeInput.fulfill()
                            } else {
                                // Socket backpressure may combine adjacent moves. Verify all
                                // seven live gains arrive exactly once in total, not packet count.
                                speedDisplacement += object["dx"] as? Double ?? 0
                                XCTAssertLessThanOrEqual(speedDisplacement,TrackpadSpeed.gains.reduce(0,+))
                                if speedDisplacement == TrackpadSpeed.gains.reduce(0,+) { speedUpdates.fulfill() }
                            }
                            speedMoves += 1
                        }
                    }
                    if object["type"] as? String == "phoneArrangement" {
                        let request = try! JSONDecoder().decode(PhoneArrangementRequest.self,from:data)
                        Task { @MainActor in
                            let report:PhoneArrangementReport
                            if request.action == .subscribe { report = arrangement.snapshot(arrangementContext) }
                            else if request.action == .unsubscribe { return }
                            else { report = await arrangement.handle(request,context:arrangementContext,stillCurrent:{true}) }
                            var response = try! JSONSerialization.jsonObject(with:JSONEncoder().encode(report)) as! [String:Any]
                            response["type"] = "phoneArrangementState"; response["requestID"] = request.requestID
                            let payload = try! JSONSerialization.data(withJSONObject:response)
                            var size = UInt32(payload.count).bigEndian
                            var packet = Data(bytes:&size,count:4); packet.append(payload)
                            c.send(content:packet,completion:.contentProcessed { _ in })
                        }
                    }
                    if object["type"] as? String == "keyboardInput" {
                        let command = try! JSONDecoder().decode(KeyboardCommand.self,from:data)
                        keyboardPackets[command.sequence,default:0] += 1
                        XCTAssertTrue(keyboardGate.accept(command,focus:focus,authenticated:true))
                        if command.sequence == 1 {
                            XCTAssertEqual(command.text,"日本語 👨‍👩‍👧‍👦 e\u{301}")
                            keyboard.fulfill()
                        }
                        if command.sequence < 3 { // Simulate uncertain or interrupted delivery for later keys.
                            let ack = try! JSONSerialization.data(withJSONObject:["type":"keyboardAck","sequence":command.sequence,"focus":command.focus,"accepted":command.sequence == 1])
                            var ackLength = UInt32(ack.count).bigEndian
                            var ackPacket = Data(bytes:&ackLength,count:4); ackPacket.append(ack)
                            c.send(content:ackPacket,completion:.contentProcessed { _ in })
                        }
                    }
                    if object["type"] as? String == "inputReset" {
                        injector.releaseAll(); resetPackets += 1
                        if resetPackets == 1 {
                            XCTAssertEqual(posted.last?.type, .leftMouseUp); reset.fulfill()
                            // A deliberate edit follows drag cleanup; do not race an
                            // automatic keyboard open against the drag that dismisses it.
                        var focusObject = try! JSONSerialization.jsonObject(with:JSONEncoder().encode(focus)) as! [String:Any]
                        focusObject["type"] = "keyboardFocus"
                        let focusData = try! JSONSerialization.data(withJSONObject:focusObject)
                        var focusLength = UInt32(focusData.count).bigEndian
                        var focusPacket = Data(bytes:&focusLength,count:4); focusPacket.append(focusData)
                        c.send(content:focusPacket,completion:.contentProcessed { _ in })

                        }
                    }
                    Task { @MainActor in read(c) }
                }
            }
        }
        mac.serve(name: "QA Mac") { peer, id, endpoint in
            requests += 1
            XCTAssertEqual(peer, "phone"); XCTAssertEqual(id, StreamReceiver.installID)
            let c = NWConnection(to: endpoint, using: PairedTransport.parameters(key: key, identity: TrustedConnections.identity("mac", "phone")))
            sender = c
            c.stateUpdateHandler = { if case .ready = $0 { Task { @MainActor in read(c) } } }
            c.start(queue: .main)
            return nil
        }
        // Real Bonjour discovery of the persistent trusted service, with no
        // first-pairing advertiser/window and no Mac-side Connect interaction.
        XCTAssertFalse(PairingDiscovery.shared.isAdvertising)
        phone.browse(receiver: receiver)
        for _ in 0..<250 {
            if phone.result(for: "mac") != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(phone.result(for: "mac"), phone.status)
        XCTAssertEqual(phone.availabilityLabel(for: "mac"), "Ready to connect")
        phone.connectAfterPairing("mac", receiver: receiver)
        phone.connectPeer("mac")
        await fulfillment(of: [stream, input, video, relativeInput, reset, speedUpdates, keyboard, layoutApplied, layoutUndone], timeout: 8)
        for _ in 0..<50 {
            if receiver.keyboardPendingCount == 0 { break }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        XCTAssertEqual(receiver.keyboardPendingCount,0)
        XCTAssertEqual(configurationCalls,2)
        XCTAssertNil(receiver.keyboardError)
        XCTAssertTrue(receiver.macSupportsShortcutGestures)
        receiver.sendTrackpad(.swipe(4,.up))
        await fulfillment(of:[shortcutDelivered],timeout:3)
        for _ in 0..<50 {
            if receiver.gestureStatus?.hasPrefix("Shortcut sent") == true { break }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        XCTAssertTrue(receiver.gestureStatus?.hasPrefix("Shortcut sent") == true)
        XCTAssertEqual(requests, 1, "Repeated taps during connection must not create duplicate requests")
        receiver.sendKeyboard(.enter)
        await fulfillment(of:[rejection],timeout:5)
        XCTAssertFalse(receiver.keyboardPresentation.visible)
        receiver.showPhoneKeyboard(); receiver.sendKeyboard(.backspace)
        await fulfillment(of:[missingAck],timeout:5)
        XCTAssertFalse(receiver.keyboardPresentation.visible)
        XCTAssertEqual(receiver.keyboardPendingCount,0)
        XCTAssertEqual(keyboardPackets,[1:1,2:1,3:1],"An uncertain key must never be resent automatically")
        receiver.showPhoneKeyboard(); receiver.sendKeyboard(.text,text:"pending")
        XCTAssertEqual(receiver.keyboardPendingCount,1)
        receiver.resetPhoneKeyboardSession() // exact cleanup invoked by socket adoption, even without connected=false
        XCTAssertEqual(receiver.keyboardPendingCount,0)
        XCTAssertFalse(receiver.macSupportsKeyboard); XCTAssertNil(receiver.keyboardPresentation.focus)
        XCTAssertTrue(receiver.keyboardError?.contains("Connection changed") == true)
        receiver.sendTrackpad(.dragBegan)
        let userDisconnected = expectation(description:"user disconnect completes and returns to selection")
        receiver.disconnectForUser { userDisconnected.fulfill() }
        await fulfillment(of:[userClosing,userDisconnected],timeout:5)
        XCTAssertFalse(receiver.connected)
        XCTAssertFalse(receiver.pairedSession)
        XCTAssertFalse(receiver.keyboardPresentation.visible)
        XCTAssertEqual(posted.last?.type,.leftMouseUp,"Disconnect releases the owned drag before closing")
        subscription.cancel(); inputSubscription.cancel(); keyboardSubscription.cancel(); keyboardErrors.cancel(); arrangementCapability.cancel(); arrangementUpdates.cancel()
        sender?.cancel(); phone.cancel()
        let stopped = expectation(description: "receiver stopped")
        receiver.stop { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 5)
    }
}
