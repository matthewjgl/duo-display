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

final class PairingV2Tests: XCTestCase {
    func testCommitmentBindsEveryOpeningFieldAndCannotBeAdaptedAfterReveal() throws {
        let key = P256.KeyAgreement.PrivateKey(), other = P256.KeyAgreement.PrivateKey()
        let original = PairingV2.Opening(id: "phone", name: "Phone", initiator: true,
            publicKey: key.publicKey.rawRepresentation, nonce: Data(repeating: 1, count: 32))
        let commitment = try original.commitment()
        try original.verify(commitment)
        let altered = [
            PairingV2.Opening(id: "attacker", name: "Phone", initiator: true, publicKey: original.publicKey, nonce: original.nonce),
            PairingV2.Opening(id: original.id, name: "Another name", initiator: true, publicKey: original.publicKey, nonce: original.nonce),
            PairingV2.Opening(id: original.id, name: original.name, initiator: false, publicKey: original.publicKey, nonce: original.nonce),
            PairingV2.Opening(id: original.id, name: original.name, initiator: true, publicKey: other.publicKey.rawRepresentation, nonce: original.nonce),
            PairingV2.Opening(id: original.id, name: original.name, initiator: true, publicKey: original.publicKey, nonce: Data(repeating: 2, count: 32))]
        for opening in altered { XCTAssertThrowsError(try opening.verify(commitment)) }
        XCTAssertThrowsError(try original.verify(Data()))
    }

    func testV2KeyAndCodeAgreeBindIdentityAndUseFreshTranscripts() throws {
        let a = P256.KeyAgreement.PrivateKey(), b = P256.KeyAgreement.PrivateKey()
        let left = PairingV2.Opening(id: "a", name: "Phone", initiator: true, publicKey: a.publicKey.rawRepresentation, nonce: Data(repeating: 1, count: 32))
        let right = PairingV2.Opening(id: "b", name: "Mac", initiator: false, publicKey: b.publicKey.rawRepresentation, nonce: Data(repeating: 2, count: 32))
        let x = try PairingV2.derive(privateKey: a, own: left, peer: right)
        let y = try PairingV2.derive(privateKey: b, own: right, peer: left)
        XCTAssertEqual(x.key.withUnsafeBytes { Data($0) }, y.key.withUnsafeBytes { Data($0) })
        XCTAssertEqual(x.verificationCode, y.verificationCode)
        let renamed = PairingV2.Opening(id: "c", name: "Mac", initiator: false, publicKey: right.publicKey, nonce: right.nonce)
        let z = try PairingV2.derive(privateKey: a, own: left, peer: renamed)
        XCTAssertNotEqual(x.key.withUnsafeBytes { Data($0) }, z.key.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try PairingV2.derive(privateKey: b, own: left, peer: right))
        XCTAssertThrowsError(try PairingV2.derive(privateKey: a, own: left, peer: left))
    }
}

extension PairingV2Tests {
    func testDisplayNameCanonicalizationRejectsControlBidiAndBoundsLongUnicode() throws {
        let key = P256.KeyAgreement.PrivateKey()
        let raw = String(repeating: "👩‍👩‍👧‍👦", count: 128)
        let cleaned = PairingV2.displayName(raw)
        XCTAssertLessThanOrEqual(cleaned.utf8.count, 512)
        XCTAssertLessThanOrEqual(cleaned.count, 64)
        XCTAssertEqual(PairingV2.displayName("Mac\u{202E}\n Name"), "Mac Name")
        XCTAssertThrowsError(try PairingV2.Opening(id: "peer", name: "Mac\u{202E}", initiator: true,
            publicKey: key.publicKey.rawRepresentation, nonce: Data(repeating: 0, count: 32)).commitment())
        XCTAssertNoThrow(try PairingV2.Opening(id: "peer", name: cleaned, initiator: true,
            publicKey: key.publicKey.rawRepresentation, nonce: Data(repeating: 0, count: 32)).commitment())
        XCTAssertEqual(PhoneErrorCopy.summary("Update SideExtend on both devices to pair securely. Existing trusted devices can still reconnect."),
                       "Update SideExtend on both devices to pair securely.")
        XCTAssertTrue(PhoneErrorCopy.summary("This device is already paired.").contains("Already paired"))
    }
}

extension PairingV2Tests {
    func testFixedTwoLegAttackerCannotReuseMatchingCodeAcrossCommittedKeys() throws {
        // Deterministic transcript regression, not a claim of a real-LAN attack
        // simulation. Network order/tampering are exercised separately.
        func privateKey(_ n: UInt8) throws -> P256.KeyAgreement.PrivateKey {
            var bytes = Data(repeating: 0, count: 32); bytes[31] = n
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: bytes)
        }
        let phone = try privateKey(1), mac = try privateKey(2)
        let attackPhone = try privateKey(3), attackMac = try privateKey(4)
        func opening(_ id: String, _ role: Bool, _ key: P256.KeyAgreement.PrivateKey, _ nonce: UInt8) -> PairingV2.Opening {
            .init(id: id, name: role ? "Phone" : "Mac", initiator: role, publicKey: key.publicKey.rawRepresentation, nonce: Data(repeating: nonce, count: 32))
        }
        let p = opening("phone", true, phone, 1), m = opening("mac", false, mac, 2)
        let ap = opening("phone", true, attackPhone, 3), am = opening("mac", false, attackMac, 4)
        let commitmentPhone = try ap.commitment(), commitmentMac = try am.commitment()
        try ap.verify(commitmentPhone); try am.verify(commitmentMac)
        let left = try PairingV2.derive(privateKey: phone, own: p, peer: am)
        let right = try PairingV2.derive(privateKey: mac, own: m, peer: ap)
        XCTAssertNotEqual(left.verificationCode, right.verificationCode)
        // Offline adaptation of either nonce AFTER seeing the other reveal is
        // precisely the old attack; it now invalidates the fixed commitment.
        let adapted = opening("phone", true, attackPhone, 9)
        XCTAssertThrowsError(try adapted.verify(commitmentPhone))
    }
}
