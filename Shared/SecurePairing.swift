import Foundation
import CryptoKit

/// Local building block only. Do not use the derived key until both users have
/// verified the same short authentication string and the peer is trusted.
enum SecurePairing {
    enum Failure: Error { case invalidNonce, identicalKeys }
    struct Material {
        let key: SymmetricKey
        let verificationCode: String
    }

    /// Both peers must pass keys in initiator, responder order. Nonces are
    /// independently generated 32-byte values and must never be reused.
    static func derive(privateKey: P256.KeyAgreement.PrivateKey,
                       peerPublicKey: P256.KeyAgreement.PublicKey,
                       initiator: P256.KeyAgreement.PublicKey,
                       responder: P256.KeyAgreement.PublicKey,
                       initiatorNonce: Data, responderNonce: Data) throws -> Material {
        guard initiatorNonce.count == 32, responderNonce.count == 32 else { throw Failure.invalidNonce }
        guard initiator.rawRepresentation != responder.rawRepresentation else { throw Failure.identicalKeys }
        let own = privateKey.publicKey.rawRepresentation
        guard (own == initiator.rawRepresentation && peerPublicKey.rawRepresentation == responder.rawRepresentation)
                || (own == responder.rawRepresentation && peerPublicKey.rawRepresentation == initiator.rawRepresentation) else {
            throw CryptoKitError.incorrectParameterSize
        }
        var transcript = Data("DuoDisplay pairing v1\0".utf8)
        transcript.append(initiator.rawRepresentation)
        transcript.append(responder.rawRepresentation)
        transcript.append(initiatorNonce)
        transcript.append(responderNonce)
        let digest = Data(SHA256.hash(data: transcript))
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: digest,
                                                  sharedInfo: Data("DuoDisplay peer key v1".utf8), outputByteCount: 32)
        let tag = HMAC<SHA256>.authenticationCode(for: Data("verification code".utf8) + digest, using: key)
        let bytes = Array(tag.prefix(4))
        let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return Material(key: key, verificationCode: String(format: "%06u", value))
    }
}

/// Version 2 first pairing: both sides commit before either reveals its random
/// opening. A network attacker cannot adapt its key/nonce after learning both
/// honest openings. Names, roles and persistent identities are transcript-bound.
/// This changes NEW pairing only; existing Keychain peer keys are not migrated.
enum PairingV2 {
    static let version = 2
    enum Failure: Error { case invalidOpening, commitmentMismatch }
    static func displayName(_ raw: String) -> String {
        let safe = raw.unicodeScalars.filter {
            !((0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value))
        }
        return DeviceNameText.truncated(DeviceNameText.clean(String(String.UnicodeScalarView(safe))) ?? "Device", maxBytes: 512)
    }
    struct Opening {
        let id: String
        let name: String
        let initiator: Bool
        let publicKey: Data
        let nonce: Data

        func transcript() throws -> Data {
            guard !id.isEmpty, id.utf8.count <= 256, name.utf8.count <= 512, name == PairingV2.displayName(name),
                  nonce.count == 32, publicKey.count == 64 else { throw Failure.invalidOpening }
            _ = try P256.KeyAgreement.PublicKey(rawRepresentation: publicKey)
            var result = Data("SideExtend first pairing v2 opening\0".utf8)
            for field in [Data(id.utf8), Data(name.utf8), Data([initiator ? 1 : 0]), publicKey, nonce] {
                var size = UInt32(field.count).bigEndian
                withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
                result.append(field)
            }
            return result
        }
        func commitment() throws -> Data { Data(SHA256.hash(data: try transcript())) }
        func verify(_ commitment: Data) throws {
            guard commitment.count == 32 else { throw Failure.commitmentMismatch }
            // Constant-time comparison through CryptoKit (the hash is not secret).
            let key = SymmetricKey(data: Data("SideExtend commitment comparison v2".utf8))
            let tag = HMAC<SHA256>.authenticationCode(for: commitment, using: key)
            guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: try self.commitment(), using: key)
            else { throw Failure.commitmentMismatch }
        }
    }

    static func derive(privateKey: P256.KeyAgreement.PrivateKey, own: Opening, peer: Opening) throws -> SecurePairing.Material {
        guard own.initiator != peer.initiator, own.id != peer.id,
              own.publicKey == privateKey.publicKey.rawRepresentation,
              own.publicKey != peer.publicKey else { throw Failure.invalidOpening }
        let first = own.initiator ? own : peer, second = own.initiator ? peer : own
        var transcript = Data("SideExtend first pairing v2 key\0".utf8)
        transcript.append(try first.transcript()); transcript.append(try second.transcript())
        let digest = Data(SHA256.hash(data: transcript))
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(rawRepresentation: peer.publicKey))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: digest,
            sharedInfo: Data("SideExtend paired peer v2".utf8), outputByteCount: 32)
        let tag = HMAC<SHA256>.authenticationCode(for: Data("verification code v2".utf8) + digest, using: key)
        let value = tag.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return SecurePairing.Material(key: key, verificationCode: String(format: "%06u", value))
    }
}

/// One challenge belongs to one connection and is consumed even on failure.
/// A caller must discard it on disconnect and create a fresh instance on retry.
struct PairingChallenge {
    enum Purpose: String { case connect = "connect", stream = "stream" }
    let nonce: Data
    let expiresAt: Date
    private(set) var consumed = false

    init(now: Date, lifetime: TimeInterval = 30) {
        let random = SymmetricKey(size: .bits256)
        nonce = random.withUnsafeBytes { Data($0) }
        expiresAt = now.addingTimeInterval(max(0, min(lifetime, 60)))
    }

    /// Every field is length-prefixed, so different names cannot share a MAC.
    static func proof(key: SymmetricKey, nonce: Data, purpose: Purpose,
                      macID: String, phoneID: String) -> Data? {
        guard nonce.count == 32, !macID.isEmpty, !phoneID.isEmpty,
              macID.utf8.count <= 256, phoneID.utf8.count <= 256 else { return nil }
        var data = Data("DuoDisplay authenticated challenge v1\0".utf8)
        for field in [Data(purpose.rawValue.utf8), Data(macID.utf8), Data(phoneID.utf8), nonce] {
            var length = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(field)
        }
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    mutating func verify(_ received: Data, key: SymmetricKey, purpose: Purpose,
                         macID: String, phoneID: String, now: Date) -> Bool {
        guard !consumed else { return false }
        consumed = true
        guard now < expiresAt, received.count == 32,
              let expected = Self.proof(key: key, nonce: nonce, purpose: purpose,
                                        macID: macID, phoneID: phoneID) else { return false }
        // Compare keyed hashes in constant time through CryptoKit's verifier.
        let comparisonKey = SymmetricKey(data: Data("DuoDisplay comparison v1".utf8))
        let wrapped = Data(HMAC<SHA256>.authenticationCode(for: received, using: comparisonKey))
        return HMAC<SHA256>.isValidAuthenticationCode(wrapped, authenticating: expected, using: comparisonKey)
    }
}
