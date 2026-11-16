import XCTest
import CryptoKit
import Network
import AVFoundation

final class PairedReceiverIntegrationTests: XCTestCase {
    func testRevokedAdmissionClosesEvenCorrectTLSKeyBeforeReceiverHello() async throws {
        let receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(), deviceKind: "iPhone", fallbackServiceName: "Revoked QA")
        let key = SymmetricKey(size: .bits256)
        var port: NWEndpoint.Port?
        let ready = expectation(description: "listener ready")
        try receiver.startPairedStream(key: key, identity: "revoked-stream", onReady: { port = $0; ready.fulfill() }, authorize: { false })
        await fulfillment(of: [ready], timeout: 5)
        let c = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(port), using: PairedTransport.parameters(key: key, identity: "revoked-stream"))
        let unauthorizedHello = expectation(description: "revoked peer must receive no hello")
        unauthorizedHello.isInverted = true
        c.stateUpdateHandler = { state in
            if case .ready = state {
                c.receive(minimumIncompleteLength: 4, maximumLength: 4096) { data,_,_,_ in
                    if let data, !data.isEmpty { unauthorizedHello.fulfill() }
                }
            }
        }
        c.start(queue: .main)
        await fulfillment(of: [unauthorizedHello], timeout: 0.5)
        c.cancel()
        let stopped = expectation(description: "stopped"); receiver.stop { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 5)
    }

    /// Review S1: after the device locks, a Mac redialing with the correct key
    /// must not be adopted (and so not rebuild its display on a locked phone);
    /// returning to the foreground restores admission on the same listener.
    func testLockedReceiverRefusesPairedRedialUntilForeground() async throws {
        let receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(), deviceKind: "iPhone", fallbackServiceName: "Sleep QA")
        receiver.start(port: ReceiverRobustnessTests.freePort())
        let key = SymmetricKey(size: .bits256)
        var port: NWEndpoint.Port?
        let ready = expectation(description: "listener ready")
        try receiver.startPairedStream(key: key, identity: "sleep-stream", onReady: { port = $0; ready.fulfill() })
        await fulfillment(of: [ready], timeout: 5)
        let slept = expectation(description: "asleep"); receiver.enterSleep { slept.fulfill() }
        await fulfillment(of: [slept], timeout: 5)
        func dial(_ hello: XCTestExpectation) -> NWConnection {
            let c = NWConnection(host: "127.0.0.1", port: port!, using: PairedTransport.parameters(key: key, identity: "sleep-stream"))
            c.stateUpdateHandler = { state in
                if case .ready = state {
                    c.receive(minimumIncompleteLength: 4, maximumLength: 65536) { data,_,_,_ in if let data, data.count >= 4 { hello.fulfill() } }
                }
            }
            c.start(queue: DispatchQueue(label: "sleep-client"))
            return c
        }
        let asleepHello = expectation(description: "no hello while locked"); asleepHello.isInverted = true
        let first = dial(asleepHello)
        await fulfillment(of: [asleepHello], timeout: 1.5)
        first.cancel()
        receiver.ensureListening()
        let wokeHello = expectation(description: "hello after foreground")
        let second = dial(wokeHello)
        await fulfillment(of: [wokeHello], timeout: 5)
        second.cancel()
        let stopped = expectation(description: "stopped"); receiver.stop { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 5)
    }

    func testReadyListenerIsReusedForSamePair() async throws {
        let receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(), deviceKind: "iPhone", fallbackServiceName: "QA")
        let key = SymmetricKey(size: .bits256)
        var first: NWEndpoint.Port?, second: NWEndpoint.Port?
        let a = expectation(description: "first listener")
        try receiver.startPairedStream(key: key, identity: "reuse") { first = $0; a.fulfill() }
        await fulfillment(of: [a], timeout: 5)
        let b = expectation(description: "reused listener")
        try receiver.startPairedStream(key: key, identity: "reuse") { second = $0; b.fulfill() }
        await fulfillment(of: [b], timeout: 5)
        XCTAssertEqual(first, second)
        let stopped = expectation(description: "stopped")
        receiver.stop { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 5)
    }

    func testRealReceiverAdmitsOnlyMatchingTLSKey() throws {
        let receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(), deviceKind: "iPhone", fallbackServiceName: "QA")
        let key = SymmetricKey(size: .bits256)
        let ready = expectation(description: "secure receiver listening")
        var port: NWEndpoint.Port?
        try receiver.startPairedStream(key: key, identity: "integration", onReady: { p in port = p; ready.fulfill() })
        wait(for: [ready], timeout: 5)
        let rejected = expectation(description: "wrong peer cannot reach receiver hello")
        rejected.isInverted = true
        let intruder = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(port),
            using: PairedTransport.parameters(key: SymmetricKey(size: .bits256), identity: "integration"))
        intruder.stateUpdateHandler = { state in
            if case .ready = state { rejected.fulfill() }
        }
        intruder.start(queue: DispatchQueue(label: "receiver-wrong-key"))
        wait(for: [rejected], timeout: 2)
        intruder.cancel()
        let client = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(port), using: PairedTransport.parameters(key: key, identity: "integration"))
        let hello = expectation(description: "real receiver hello after authentication")
        client.stateUpdateHandler = { state in
            if case .ready = state {
                client.receive(minimumIncompleteLength: 4, maximumLength: 65536) { data, _, _, _ in
                    if let data, data.count >= 4 { hello.fulfill() }
                }
            }
        }
        client.start(queue: DispatchQueue(label: "receiver-integration"))
        wait(for: [hello], timeout: 5)
        client.cancel()
        let stopped = expectation(description: "stopped")
        receiver.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 5)
    }
}

extension PairedReceiverIntegrationTests {
    func testPhonePlainChannelsNeverAdmitLANEvenBeforeFirstPair() {
        for address in ["192.168.1.20", "10.0.0.4", "fe80::1", "100.70.1.2"] {
            XCTAssertFalse(StreamReceiver.allowsPlainChannel(endpoint: .hostPort(host: NWEndpoint.Host(address), port: 9000), requiresPairing: true))
        }
        for address in ["127.0.0.1", "::1"] {
            XCTAssertTrue(StreamReceiver.allowsPlainChannel(endpoint: .hostPort(host: NWEndpoint.Host(address), port: 9000), requiresPairing: true))
        }
    }
}

#if DEBUG
extension PairedReceiverIntegrationTests {
    @MainActor
    func testPairedInputWriteCompletionsDoNotWaitForVideoProcessing() async throws { try await measureVideoBlockedInput(paired:true) }
    @MainActor
    func testUSBEquivalentInputWriteCompletionsDoNotWaitForVideoProcessing() async throws { try await measureVideoBlockedInput(paired:false) }
    @MainActor
    private func measureVideoBlockedInput(paired:Bool) async throws {
        let receiver = StreamReceiver(displayLayer:AVSampleBufferDisplayLayer(),deviceKind:"iPhone",fallbackServiceName:"Input pacing QA")
        receiver.trackpadSpeedLevel = { 4 }
        let key = SymmetricKey(size:.bits256)
        var port:NWEndpoint.Port?
        if paired {
            let ready = expectation(description:"paired TLS listener")
            try receiver.startPairedStream(key:key,identity:"input-video-pacing",onReady:{ port=$0;ready.fulfill() })
            await fulfillment(of:[ready],timeout:5)
        } else {
            let plainPort = ReceiverRobustnessTests.freePort();port=NWEndpoint.Port(rawValue:plainPort)!
            receiver.start(port:plainPort)
            for _ in 0..<200 where !receiver.discoveryDiagnostic.contains("registered") { try await Task.sleep(nanoseconds:10_000_000) }
            XCTAssertTrue(receiver.discoveryDiagnostic.contains("registered"))
        }
        let c = NWConnection(host:"127.0.0.1",port:try XCTUnwrap(port),using:paired ? PairedTransport.parameters(key:key,identity:"input-video-pacing") : .tcp)
        var framing = InputControlFrames(), arrivals:[Double] = [], displacement = 0.0
        func framed(_ object:[String:Any]) throws -> Data {
            let payload = try JSONSerialization.data(withJSONObject:object);var n=UInt32(payload.count).bigEndian
            var bytes=Data(bytes:&n,count:4);bytes.append(payload);return bytes
        }
        func read() {
            c.receive(minimumIncompleteLength:1,maximumLength:65536) { data,_,complete,error in
                Task { @MainActor in
                if let data, let frames = try? framing.append(data) {
                    for payload in frames {
                        guard let object = try? JSONSerialization.jsonObject(with:payload) as? [String:Any] else { continue }
                        if object["type"] as? String == "hello" {
                            c.send(content:try! framed(["type":WireMessage.welcome,"pv":WireProtocol.version,"trackpad":true]),completion:.contentProcessed{_ in})
                        }
                        if object["type"] as? String == "trackpad",object["action"] as? String == "move" {
                            arrivals.append(ProcessInfo.processInfo.systemUptime);displacement += object["dx"] as? Double ?? 0
                        }
                    }
                }
                if !complete,error == nil { read() }
                }
            }
        }
        c.stateUpdateHandler = { state in Task { @MainActor in if case .ready = state { read() } } }
        c.start(queue:.main)
        for _ in 0..<100 where !receiver.macSupportsTrackpad { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertTrue(receiver.macSupportsTrackpad)
        let blocked = expectation(description:"controlled video queue stall")
        let release = DispatchSemaphore(value:0)
        defer { release.signal();c.cancel();receiver.stop() }
        receiver.debugEnqueueVideoWork { blocked.fulfill();_ = release.wait(timeout:.now()+3) }
        await fulfillment(of:[blocked],timeout:2)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<12 {
            receiver.sendTrackpad(.move(1,0))
            try await Task.sleep(nanoseconds:5_000_000)
        }
        try await Task.sleep(nanoseconds:40_000_000)
        let beforeRelease = arrivals.count
        let elapsed = ProcessInfo.processInfo.systemUptime-start
        release.signal()
        for _ in 0..<100 where displacement < 48 { try await Task.sleep(nanoseconds:5_000_000) }
        XCTAssertEqual(displacement,48,accuracy:0.001,"No lost or duplicated relative movement")
        let gaps=zip(arrivals.dropFirst(),arrivals).map{($0-$1)*1000}.sorted()
        let report:[String:Any] = ["scenario":"Real \(paired ? "paired TLS" : "USB-equivalent plain") loopback; video/state queue deliberately held while12 main-thread moves arrive5ms apart. Not physical Wi-Fi latency.","sent_moves":12,"arrived_before_video_unblock":beforeRelease,"held_window_ms":elapsed*1000,"wire_writes":arrivals.count,"displacement":displacement,"max_arrival_gap_ms":gaps.last ?? 0]
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/trackpad-regression17-20261115")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent(paired ? "paired-video-stall-measurement.json" : "usb-video-stall-measurement.json"))
        XCTAssertGreaterThanOrEqual(beforeRelease,8,"Video processing must not stall phone-to-Mac pointer writes on an otherwise healthy authenticated connection")
    }
}

#endif

extension PairedReceiverIntegrationTests {
    @MainActor
    func testLateRetiredPairedCallbacksCannotDisconnectReplacementOrRouteItsInput() async throws {
        let receiver = StreamReceiver(displayLayer:AVSampleBufferDisplayLayer(),deviceKind:"iPhone",fallbackServiceName:"Retirement QA")
        receiver.trackpadSpeedLevel = {4}
        let key=SymmetricKey(size:.bits256)
        var port:NWEndpoint.Port?
        let ready=expectation(description:"paired listener")
        try receiver.startPairedStream(key:key,identity:"retired-io",onReady:{port=$0;ready.fulfill()})
        await fulfillment(of:[ready],timeout:5)
        let firstHello=expectation(description:"first hello"),secondHello=expectation(description:"replacement hello")
        let secondMove=expectation(description:"input routed to replacement")
        let firstMove=expectation(description:"no new input routed to retired peer");firstMove.isInverted=true
        func frame(_ object:[String:Any]) throws -> Data {
            let payload=try JSONSerialization.data(withJSONObject:object);var n=UInt32(payload.count).bigEndian
            var data=Data(bytes:&n,count:4);data.append(payload);return data
        }
        func make(_ index:Int) -> NWConnection {
            let c=NWConnection(host:"127.0.0.1",port:port!,using:PairedTransport.parameters(key:key,identity:"retired-io"))
            var frames=InputControlFrames()
            func read() {
                c.receive(minimumIncompleteLength:1,maximumLength:65536) { data,_,complete,error in
                    Task { @MainActor in
                        if let data,let payloads=try? frames.append(data) {
                            for p in payloads {
                                guard let o=try? JSONSerialization.jsonObject(with:p) as? [String:Any] else {continue}
                                if o["type"] as? String == "hello" {
                                    (index == 1 ? firstHello : secondHello).fulfill()
                                    c.send(content:try! frame(["type":WireMessage.welcome,"pv":WireProtocol.version,"trackpad":true]),completion:.contentProcessed{_ in})
                                }
                                if o["type"] as? String == "trackpad" { (index == 1 ? firstMove : secondMove).fulfill() }
                            }
                        }
                        if !complete,error == nil {read()}
                    }
                }
            }
            c.stateUpdateHandler = {state in Task { @MainActor in if case .ready=state {read()} } }
            c.start(queue:.main);return c
        }
        let a=make(1)
        await fulfillment(of:[firstHello],timeout:5)
        let b=make(2)
        defer {a.cancel();b.cancel();receiver.stop()}
        await fulfillment(of:[secondHello],timeout:5)
        a.cancel() // its late EOF/state callbacks must be harmless after adoption
        for _ in 0..<100 where !receiver.macSupportsTrackpad {try await Task.sleep(nanoseconds:5_000_000)}
        try await Task.sleep(nanoseconds:50_000_000)
        XCTAssertTrue(receiver.connected)
        receiver.sendTrackpad(.move(2,0))
        await fulfillment(of:[secondMove],timeout:3)
        await fulfillment(of:[firstMove],timeout:0.1)
        XCTAssertTrue(receiver.connected)
    }
}
