import Foundation
import Combine
import CryptoKit

@MainActor
final class PairingApprovalCoordinator: ObservableObject {
    static let shared = PairingApprovalCoordinator()
    static let localID: String = {
        let key = "duo.securePairing.localID.v1"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()
    struct Prompt: Identifiable {
        let id: UUID
        let peerID: String
        let name: String
        let code: String
    }
    enum Failure: Error { case busy, invalidPeer, expired, rejected }
    @Published private(set) var prompt: Prompt?
    @Published private(set) var status = ""
    private var key: SymmetricKey?
    private var localApproved = false
    private var remoteApproved = false
    private var deadline = Date.distantPast
    private var timeout: Task<Void, Never>?
    private let ownID: String
    private let save: (SymmetricKey, String) throws -> Void
    var sendConfirmation: ((Data) -> Void)?
    var completed: ((String) -> Void)?
    var cancelled: (() -> Void)?

    init(ownID: String = PairingApprovalCoordinator.localID,
         save: @escaping (SymmetricKey, String) throws -> Void = { try SecurePairingKeyStore.save($0, peerID: $1) }) {
        self.ownID = ownID
        self.save = save
    }

    func begin(peerID: String, name: String, material: SecurePairing.Material,
               now: Date = Date(), lifetime: TimeInterval = 60) throws {
        guard prompt == nil else { throw Failure.busy }
        guard !peerID.isEmpty, peerID != ownID, peerID.utf8.count <= 256 else { throw Failure.invalidPeer }
        key = material.key
        localApproved = false; remoteApproved = false
        deadline = now.addingTimeInterval(max(0, min(lifetime, 120)))
        let token = UUID()
        prompt = Prompt(id: token, peerID: peerID, name: String(name.prefix(128)), code: material.verificationCode)
        status = "Compare the code on both devices."
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, min(lifetime, 120)) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.prompt?.id == token else { return }
            self.cancel(message: "Pairing expired. Try again.")
        }
    }

    func approve(now: Date = Date()) {
        guard let prompt, let key, now < deadline else { cancel(message: "Pairing expired. Try again."); return }
        guard !localApproved else { return }
        localApproved = true
        status = "Waiting for approval on the other device…"
        sendConfirmation?(confirmation(key: key, from: ownID, to: prompt.peerID))
        finishIfReady(now: now)
    }

    func receiveConfirmation(_ proof: Data, now: Date = Date()) {
        guard let prompt, let key, now < deadline else { cancel(message: "Pairing expired. Try again."); return }
        let message = confirmationMessage(from: prompt.peerID, to: ownID)
        guard HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: key) else {
            cancel(message: "Pairing verification failed. Compare codes and try again."); return
        }
        remoteApproved = true
        finishIfReady(now: now)
    }

    func cancel(message: String = "Pairing cancelled.") {
        timeout?.cancel(); timeout = nil
        prompt = nil; key = nil
        localApproved = false; remoteApproved = false
        status = message
        cancelled?()
    }

    private func finishIfReady(now: Date) {
        guard localApproved, remoteApproved, let prompt, let key, now < deadline else { return }
        do {
            try save(key, prompt.peerID)
            let peer = prompt.peerID
            timeout?.cancel(); timeout = nil
            self.prompt = nil; self.key = nil
            status = "Paired securely."
            completed?(peer)
        } catch { cancel(message: "Could not save pairing in Keychain. Unlock the device and try again.") }
    }

    private func confirmation(key: SymmetricKey, from: String, to: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: confirmationMessage(from: from, to: to), using: key))
    }
    private func confirmationMessage(from: String, to: String) -> Data {
        // JSON preserves field boundaries; key is bound to the ECDH transcript.
        try! JSONEncoder().encode(["DuoDisplay mutual approval v1", from, to])
    }
}
