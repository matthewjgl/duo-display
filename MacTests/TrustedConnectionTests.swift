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
        let stream = expectation(description: "authenticated stream hello")
        let input = expectation(description: "touch on authenticated stream")
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
                        var length = UInt32(frame.count).bigEndian
                        var packet = Data(bytes: &length, count: 4); packet.append(frame)
                        c.send(content: packet, completion: .contentProcessed { _ in })
                        Task { @MainActor in receiver.sendTouch(phase: "began", x: 0.5, y: 0.5) }
                    }
                    if object["type"] as? String == "touch" { input.fulfill() }
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
        phone.connectPeer("mac")
        phone.connectPeer("mac")
        await fulfillment(of: [stream, input, video], timeout: 8)
        XCTAssertEqual(requests, 1, "Repeated taps during connection must not create duplicate requests")
        subscription.cancel()
        sender?.cancel(); phone.cancel()
        let stopped = expectation(description: "receiver stopped")
        receiver.stop { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 5)
    }
}
