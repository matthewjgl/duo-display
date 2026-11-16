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

@MainActor
final class PairingV2NetworkRejectionTests: XCTestCase {
    private func frame(_ object: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: object)
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: 4); data.append(payload); return data
    }

    private func reject(_ messages: [[String: Any]], initiator: Bool = true, timeout: TimeInterval = 2,
                        cancel: Bool = false, echo: Bool = false) async throws {
        let listening = expectation(description: "listener ready")
        let first = expectation(description: "commit only before remote commit")
        let failed = expectation(description: "fail closed")
        var saves = 0, prompts = 0
        var attack: NWConnection?
        let coordinator = PairingApprovalCoordinator(ownID: "honest", save: { _, _ in saves += 1 })
        let listener = try NWListener(using: .tcp)
        listener.stateUpdateHandler = { state in if case .ready = state { listening.fulfill() } }
        listener.newConnectionHandler = { conn in
            attack = conn
            conn.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
                    guard let header, header.count == 4 else { return }
                    let size = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
                    conn.receive(minimumIncompleteLength: size, maximumLength: size) { payload, _, _, _ in
                        let object = payload.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                        XCTAssertEqual(object?["type"] as? String, "pairCommit")
                        XCTAssertEqual(object?["version"] as? Int, 2)
                        XCTAssertNil(object?["publicKey"]); XCTAssertNil(object?["nonce"])
                        first.fulfill()
                        if echo, let object {
                            // Reflect the honest commitment, then its reveal.
                            // A reflected role/identity must never produce trust.
                            conn.send(content: try! self.frame(object), completion: .contentProcessed { _ in })
                            conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { h, _, _, _ in
                                guard let h, h.count == 4 else { return }
                                let n = h.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
                                conn.receive(minimumIncompleteLength: n, maximumLength: n) { body, _, _, _ in
                                    guard let body, let reveal = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
                                    XCTAssertEqual(reveal["type"] as? String, "pairReveal")
                                    conn.send(content: try! self.frame(reveal), completion: .contentProcessed { _ in })
                                }
                            }
                        } else if messages.isEmpty {
                            // Do not commit. There must be no second frame
                            // (especially no key/nonce reveal) before timeout.
                            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { bytes, _, _, _ in
                                XCTAssertTrue(bytes?.isEmpty ?? true, "Revealed before peer commitment")
                            }
                        }
                        for message in messages {
                            conn.send(content: try! self.frame(message), completion: .contentProcessed { _ in })
                        }
                    }
                }
            }
            conn.start(queue: .main)
        }
        listener.start(queue: .main)
        await fulfillment(of: [listening], timeout: 3)
        let conn = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port), using: .tcp)
        let exchange = PairingExchange(connection: conn, coordinator: coordinator, ownID: "honest", name: "QA", initiator: initiator)
        exchange.onPrompt = { prompts += 1 }
        exchange.onComplete = { _, _ in XCTFail("Untrusted exchange completed") }
        exchange.onFailure = { _ in failed.fulfill() }
        exchange.start(timeout: timeout)
        await fulfillment(of: [first], timeout: 3)
        if cancel { exchange.cancel() }
        await fulfillment(of: [failed], timeout: 4)
        XCTAssertEqual(saves, 0); XCTAssertNil(coordinator.prompt)
        // No prompt at all for malformed/legacy/early exchange; invalid approval
        // is tested separately after a valid opening but must still never save.
        if !messages.contains(where: { $0["type"] as? String == "pairApproval" }) { XCTAssertEqual(prompts, 0) }
        exchange.cancel(); attack?.cancel(); listener.cancel()
    }

    func testLegacyAndUnknownVersionsCannotDowngradeFirstPairing() async throws {
        try await reject([["type": "pairHello", "version": 1]])
        try await reject([["type": "pairHello"]], initiator: false)
        try await reject([["type": "pairCommit", "version": 3]])
    }

    func testEarlyRevealDuplicateCommitAndTamperedOpeningFailClosed() async throws {
        let key = P256.KeyAgreement.PrivateKey()
        let opening = PairingV2.Opening(id: "peer", name: "Mac", initiator: false,
            publicKey: key.publicKey.rawRepresentation, nonce: Data(repeating: 7, count: 32))
        let reveal: [String: Any] = ["type": "pairReveal", "version": 2, "id": opening.id, "name": opening.name,
            "initiator": false, "publicKey": opening.publicKey.base64EncodedString(), "nonce": opening.nonce.base64EncodedString()]
        let commit: [String: Any] = ["type": "pairCommit", "version": 2, "commitment": try opening.commitment().base64EncodedString()]
        try await reject([reveal])
        try await reject([commit, commit])
        try await reject([["type": "pairCommit", "version": 2, "commitment": Data(repeating: 0, count: 32).base64EncodedString()], reveal])
        var changed = reveal; changed["id"] = "substituted"
        try await reject([commit, changed])
        // Replayed opening alone cannot authorize: a fresh honest key and nonce
        // derive a different key, so an old/forged approval is rejected.
        try await reject([commit, reveal, ["type": "pairApproval", "version": 2,
            "proof": Data(repeating: 1, count: 32).base64EncodedString()]])
    }

    func testReflectionAndPrematureApprovalCannotAuthorize() async throws {
        try await reject([], echo: true)
        try await reject([["type": "pairApproval", "version": 2, "proof": Data(repeating: 0, count: 32).base64EncodedString()]])
    }

    func testTimeoutAndCancellationDoNotPersistTrust() async throws {
        try await reject([], timeout: 0.2)
        try await reject([], cancel: true)
    }
}
