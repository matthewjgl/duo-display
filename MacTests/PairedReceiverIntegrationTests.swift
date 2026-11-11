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
