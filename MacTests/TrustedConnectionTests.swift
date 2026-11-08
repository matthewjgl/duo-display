import XCTest
import Network
import CryptoKit
import AVFoundation
import Combine

@MainActor
final class TrustedConnectionTests: XCTestCase {
    func testPhoneRequestStartsAuthenticatedReceiverAndCarriesTouch() async throws {
        let key = SymmetricKey(size: .bits256)
        let mac = TrustedConnections(ownID: "mac", lookup: { _ in key }, peers: { ["phone"] })
        let phone = TrustedConnections(ownID: "phone", lookup: { _ in key }, peers: { ["mac"] })
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
        var port: NWEndpoint.Port?
        for _ in 0..<100 {
            port = mac.listeningPort(for: "phone")
            if port != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        phone.connectTrusted(endpoint: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(port)), macID: "mac", receiver: receiver)
        phone.connectTrusted(endpoint: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(port)), macID: "mac", receiver: receiver)
        await fulfillment(of: [stream, input, video], timeout: 8)
        XCTAssertEqual(requests, 1, "Repeated taps during connection must not create duplicate requests")
        subscription.cancel()
        sender?.cancel(); phone.cancel()
        let stopped = expectation(description: "receiver stopped")
        receiver.stop { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 5)
    }
}
