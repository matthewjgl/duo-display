import XCTest
import Network
import CryptoKit

@MainActor
final class PairingExchangeTests: XCTestCase {
    func testRealSocketExchangeDerivesSameCodeAndPersistsAfterBothApprovals() async throws {
        let listening = expectation(description: "listener ready")
        let paired = expectation(description: "both approvals completed"); paired.expectedFulfillmentCount = 2
        var keyA: Data?, keyB: Data?
        let a = PairingApprovalCoordinator(ownID: "a", save: { key, id in
            XCTAssertEqual(id, "b"); keyA = key.withUnsafeBytes { Data($0) }
        })
        let b = PairingApprovalCoordinator(ownID: "b", save: { key, id in
            XCTAssertEqual(id, "a"); keyB = key.withUnsafeBytes { Data($0) }
        })
        var server: PairingExchange?
        let listener = try NWListener(using: .tcp)
        listener.stateUpdateHandler = { state in if case .ready = state { listening.fulfill() } }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                let exchange = PairingExchange(connection: connection, coordinator: b, ownID: "b", name: "QA Mac", initiator: false)
                server = exchange
                exchange.onPrompt = {
                    if a.prompt != nil {
                        XCTAssertEqual(a.prompt?.code, b.prompt?.code)
                        a.approve(); b.approve()
                    }
                }
                exchange.onComplete = { _, _ in paired.fulfill() }
                exchange.onFailure = { XCTFail("Server pairing failed: \($0)") }
                exchange.start()
            }
        }
        listener.start(queue: .main)
        await fulfillment(of: [listening], timeout: 5)
        let connection = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port), using: .tcp)
        let client = PairingExchange(connection: connection, coordinator: a, ownID: "a", name: "QA Phone", initiator: true)
        client.onComplete = { _, _ in paired.fulfill() }
        client.onFailure = { XCTFail("Client pairing failed: \($0)") }
        // Either peer may receive hello first. Approve only once both prompts exist.
        client.onPrompt = { if b.prompt != nil { a.approve(); b.approve() } }
        client.start()
        await fulfillment(of: [paired], timeout: 5)
        XCTAssertNotNil(keyA); XCTAssertEqual(keyA, keyB)
        listener.cancel(); connection.cancel(); server?.cancel()
    }
}
