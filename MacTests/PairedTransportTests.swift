import XCTest
import CryptoKit
import Network

final class PairedTransportTests: XCTestCase {
    func testStableServiceSurvivesRestartAndIsPairSpecific() {
        XCTAssertEqual(PairedTransport.identity("mac", "phone"), PairedTransport.identity("phone", "mac"))
        XCTAssertEqual(PairedTransport.endpoint(mac: "mac", phone: "phone"), PairedTransport.endpoint(mac: "mac", phone: "phone"))
        XCTAssertNotEqual(PairedTransport.endpoint(mac: "mac", phone: "phone"), PairedTransport.endpoint(mac: "other", phone: "phone"))
    }

    func testTLSStreamRequiresMatchingPairKey() throws {
        for matches in [true, false] {
            let key = SymmetricKey(size: .bits256)
            let queue = DispatchQueue(label: "paired-transport-test")
            let listener = try NWListener(using: PairedTransport.parameters(key: key, identity: "pair-test"))
            let listening = expectation(description: "listening")
            listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
            var incoming: NWConnection?
            let received = expectation(description: "authenticated payload")
            received.isInverted = !matches
            listener.newConnectionHandler = { connection in
                incoming = connection
                connection.stateUpdateHandler = { state in
                    if case .ready = state {
                        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, _ in
                            if data == Data("test".utf8) { received.fulfill() }
                        }
                    }
                }
                connection.start(queue: queue)
            }
            listener.start(queue: queue)
            wait(for: [listening], timeout: 5)
            let client = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port),
                using: PairedTransport.parameters(key: matches ? key : SymmetricKey(size: .bits256), identity: "pair-test"))
            client.stateUpdateHandler = { state in
                if case .ready = state { client.send(content: Data("test".utf8), completion: .contentProcessed { _ in }) }
            }
            client.start(queue: queue)
            wait(for: [received], timeout: matches ? 5 : 2)
            client.cancel(); listener.cancel()
            queue.sync { incoming?.cancel() }
        }
    }
}
