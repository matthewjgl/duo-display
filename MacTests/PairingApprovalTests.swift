import XCTest
import CryptoKit

@MainActor
final class PairingApprovalTests: XCTestCase {
    func testTwoApprovalsPersistBothPeersOnlyAfterConfirmation() throws {
        let key = SymmetricKey(size: .bits256)
        let material = SecurePairing.Material(key: key, verificationCode: "123456")
        var savedA: [String] = [], savedB: [String] = []
        let a = PairingApprovalCoordinator(ownID: "a", save: { _, id in savedA.append(id) })
        let b = PairingApprovalCoordinator(ownID: "b", save: { _, id in savedB.append(id) })
        a.sendConfirmation = { b.receiveConfirmation($0) }
        b.sendConfirmation = { a.receiveConfirmation($0) }
        try a.begin(peerID: "b", name: "Phone", material: material)
        try b.begin(peerID: "a", name: "Mac", material: material)
        a.approve()
        XCTAssertTrue(savedA.isEmpty); XCTAssertTrue(savedB.isEmpty)
        b.approve()
        XCTAssertEqual(savedA, ["b"]); XCTAssertEqual(savedB, ["a"])
        XCTAssertNil(a.prompt); XCTAssertNil(b.prompt)
        a.approve(); b.approve()
        XCTAssertEqual(savedA.count, 1); XCTAssertEqual(savedB.count, 1)
    }

    func testCancelInvalidProofExpiryAndDuplicateAttemptNeverPersist() throws {
        var saved = 0
        let c = PairingApprovalCoordinator(ownID: "a", save: { _, _ in saved += 1 })
        let m = SecurePairing.Material(key: SymmetricKey(size: .bits256), verificationCode: "123456")
        try c.begin(peerID: "b", name: "Phone", material: m)
        XCTAssertThrowsError(try c.begin(peerID: "c", name: "Other", material: m))
        c.approve(); c.receiveConfirmation(Data(repeating: 0, count: 32))
        XCTAssertNil(c.prompt); XCTAssertEqual(saved, 0)
        try c.begin(peerID: "b", name: "Phone", material: m)
        c.cancel(); c.approve()
        XCTAssertEqual(saved, 0)
        let now = Date()
        try c.begin(peerID: "b", name: "Phone", material: m, now: now, lifetime: 1)
        c.approve(now: now.addingTimeInterval(2))
        XCTAssertNil(c.prompt); XCTAssertEqual(saved, 0)
    }
}
