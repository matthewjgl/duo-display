import XCTest
import CryptoKit

final class SecurePairingTests: XCTestCase {
    func testBothPeersDeriveSameKeyAndCodeAndNonceChangesIt() throws {
        let a = P256.KeyAgreement.PrivateKey(), b = P256.KeyAgreement.PrivateKey()
        let n1 = Data(repeating: 1, count: 32), n2 = Data(repeating: 2, count: 32)
        func material(_ key: P256.KeyAgreement.PrivateKey, _ peer: P256.KeyAgreement.PublicKey, _ nonce: Data) throws -> SecurePairing.Material {
            try SecurePairing.derive(privateKey: key, peerPublicKey: peer, initiator: a.publicKey,
                responder: b.publicKey, initiatorNonce: n1, responderNonce: nonce)
        }
        let left = try material(a, b.publicKey, n2), right = try material(b, a.publicKey, n2)
        XCTAssertEqual(left.key.withUnsafeBytes { Data($0) }, right.key.withUnsafeBytes { Data($0) })
        XCTAssertEqual(left.verificationCode, right.verificationCode)
        XCTAssertEqual(left.verificationCode.count, 6)
        XCTAssertNotEqual(left.key.withUnsafeBytes { Data($0) }, try material(a, b.publicKey, Data(repeating: 3, count: 32)).key.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try material(a, b.publicKey, Data()))
        XCTAssertThrowsError(try material(P256.KeyAgreement.PrivateKey(), b.publicKey, n2))
    }
}

final class PairingChallengeTests: XCTestCase {
    func testValidProofIsSingleUseAndBoundToPurposeAndPeer() {
        let now = Date(timeIntervalSince1970: 1000), key = SymmetricKey(size: .bits256)
        var c = PairingChallenge(now: now)
        let proof = PairingChallenge.proof(key: key, nonce: c.nonce, purpose: .connect, macID: "mac", phoneID: "phone")!
        XCTAssertTrue(c.verify(proof, key: key, purpose: .connect, macID: "mac", phoneID: "phone", now: now))
        XCTAssertFalse(c.verify(proof, key: key, purpose: .connect, macID: "mac", phoneID: "phone", now: now))
        var other = PairingChallenge(now: now)
        let p = PairingChallenge.proof(key: key, nonce: other.nonce, purpose: .connect, macID: "mac", phoneID: "phone")!
        XCTAssertFalse(other.verify(p, key: key, purpose: .stream, macID: "mac", phoneID: "phone", now: now))
        XCTAssertFalse(other.verify(p, key: key, purpose: .connect, macID: "mac", phoneID: "phone", now: now))
        var expired = PairingChallenge(now: now, lifetime: 5)
        let q = PairingChallenge.proof(key: key, nonce: expired.nonce, purpose: .connect, macID: "mac", phoneID: "phone")!
        XCTAssertFalse(expired.verify(q, key: key, purpose: .connect, macID: "mac", phoneID: "phone", now: now.addingTimeInterval(5)))
        var forged = PairingChallenge(now: now)
        let bad = PairingChallenge.proof(key: SymmetricKey(size: .bits256), nonce: forged.nonce, purpose: .connect, macID: "mac", phoneID: "phone")!
        XCTAssertFalse(forged.verify(bad, key: key, purpose: .connect, macID: "mac", phoneID: "phone", now: now))
    }
}
