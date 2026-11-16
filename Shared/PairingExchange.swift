import Foundation
import Network
import CryptoKit

/// Bounded first-pair exchange. This endpoint cannot start capture or input.
/// A matching code must be explicitly approved on both app interfaces.
@MainActor
final class PairingExchange {
    enum ExchangeError: LocalizedError {
        case invalidMessage, disconnected, timeout, unsupportedVersion
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: return "Update SideExtend on both devices to pair securely. Existing trusted devices can still reconnect."
            case .timeout: return "Pairing timed out. Keep both apps open and try again."
            case .invalidMessage: return "Pairing verification failed. Cancel on both devices and try again on a trusted network."
            case .disconnected: return "Pairing interrupted or declined. Try Pair & Connect again."
            }
        }
    }
    private let connection: NWConnection
    private let coordinator: PairingApprovalCoordinator
    private let privateKey = P256.KeyAgreement.PrivateKey()
    private let nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    private let initiator: Bool
    private let ownID: String
    private let name: String
    private var active = true
    private var began = false
    private var started = false
    private var peerCommitment: Data?
    private var revealed = false
    private var ownOpening: PairingV2.Opening {
        .init(id: ownID, name: name, initiator: initiator,
              publicKey: privateKey.publicKey.rawRepresentation, nonce: nonce)
    }
    private var expiry: Task<Void, Never>?
    private var precommitDeadline: Task<Void, Never>?
    private var material: SecurePairing.Material?
    private var peerID: String?
    var onPrompt: (() -> Void)?
    var onComplete: ((String, SymmetricKey) -> Void)?
    var onFailure: ((Error) -> Void)?

    init(connection: NWConnection, coordinator: PairingApprovalCoordinator,
         ownID: String, name: String, initiator: Bool) {
        self.connection = connection; self.coordinator = coordinator
        self.ownID = ownID; self.name = PairingV2.displayName(name); self.initiator = initiator
    }

    func start(timeout: TimeInterval = 60) {
        guard !started else { return }
        started = true
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.active else { return }
                switch state {
                case .ready:
                    do {
                        // Never send a reveal (or accept v1 hello) before the
                        // peer's fixed commitment. No downgrade negotiation.
                        let commitment = try self.ownOpening.commitment()
                        self.send(["type": "pairCommit", "version": PairingV2.version,
                                   "commitment": commitment.base64EncodedString()])
                        self.receiveHeader()
                    } catch { self.fail(ExchangeError.invalidMessage) }
                case .failed(let error): self.fail(error)
                case .cancelled: self.fail(ExchangeError.disconnected)
                default: break
                }
            }
        }
        expiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, min(timeout, 120)) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fail(ExchangeError.timeout)
        }
        precommitDeadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.peerCommitment == nil else { return }
            self.fail(ExchangeError.timeout)
        }
        connection.start(queue: .main)
    }

    func cancel() {
        if active { fail(ExchangeError.disconnected) }
        else { connection.cancel() }
    }

    private func send(_ object: [String: Any]) {
        guard active, let payload = try? JSONSerialization.data(withJSONObject: object), payload.count <= 4096 else { return }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4); frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error { Task { @MainActor in self?.fail(error) } }
        })
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, self.active else { return }
                guard error == nil, let data, data.count == 4 else { self.fail(ExchangeError.disconnected); return }
                let count = data.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
                guard count > 0, count <= 4096 else { self.fail(ExchangeError.invalidMessage); return }
                self.receivePayload(count)
            }
        }
    }

    private func receivePayload(_ count: Int) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, self.active else { return }
                guard error == nil, let data, data.count == count,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.fail(ExchangeError.invalidMessage); return
                }
                do { try self.handle(object) } catch { self.fail(error) }
                if self.active { self.receiveHeader() }
            }
        }
    }

    private func handle(_ object: [String: Any]) throws {
        guard object["version"] as? Int == PairingV2.version else { throw ExchangeError.unsupportedVersion }
        switch object["type"] as? String {
        case "pairCommit":
            guard peerCommitment == nil, !revealed, !began,
                  let encoded = object["commitment"] as? String,
                  let commitment = Data(base64Encoded: encoded), commitment.count == 32
            else { throw ExchangeError.invalidMessage }
            precommitDeadline?.cancel()
            peerCommitment = commitment
            let opening = ownOpening
            revealed = true
            send(["type": "pairReveal", "version": PairingV2.version,
                  "id": opening.id, "name": opening.name, "initiator": opening.initiator,
                  "publicKey": opening.publicKey.base64EncodedString(), "nonce": opening.nonce.base64EncodedString()])
        case "pairReveal":
            guard !began, revealed, let commitment = peerCommitment,
                  let id = object["id"] as? String,
                  let role = object["initiator"] as? Bool, role != initiator,
                  let publicString = object["publicKey"] as? String, let bytes = Data(base64Encoded: publicString),
                  let nonceString = object["nonce"] as? String, let peerNonce = Data(base64Encoded: nonceString),
                  let peerName = object["name"] as? String else { throw ExchangeError.invalidMessage }
            let opening = PairingV2.Opening(id: id, name: peerName, initiator: role, publicKey: bytes, nonce: peerNonce)
            do { try opening.verify(commitment) } catch { throw ExchangeError.invalidMessage }
            let derived = try PairingV2.derive(privateKey: privateKey, own: ownOpening, peer: opening)
            try coordinator.begin(peerID: id, name: peerName, material: derived)
            material = derived; peerID = id; began = true
            coordinator.sendConfirmation = { [weak self] proof in self?.send(["type": "pairApproval", "version": PairingV2.version, "proof": proof.base64EncodedString()]) }
            coordinator.cancelled = { [weak self] in self?.fail(ExchangeError.disconnected) }
            coordinator.completed = { [weak self] peer in
                guard let self, self.active, let material = self.material else { return }
                self.active = false; self.expiry?.cancel(); self.precommitDeadline?.cancel()
                // Finish the queued confirmation before the owner tears down the socket.
                self.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error { self.onFailure?(error) }
                        else { self.onComplete?(peer, material.key) }
                    }
                })
            }
            onPrompt?()
        case "pairApproval":
            guard began, let encoded = object["proof"] as? String,
                  let proof = Data(base64Encoded: encoded), proof.count == 32 else { throw ExchangeError.invalidMessage }
            coordinator.receiveConfirmation(proof)
        default: throw ExchangeError.invalidMessage
        }
    }

    private func fail(_ error: Error) {
        guard active else { return }
        active = false; expiry?.cancel(); precommitDeadline?.cancel(); connection.cancel()
        if began { coordinator.cancel(message: error.localizedDescription) }
        onFailure?(error)
    }
}
