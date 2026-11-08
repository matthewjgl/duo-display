import Foundation
import Network
import Combine
import CryptoKit

/// Authenticated request channel; never accepts a plaintext request.
@MainActor
final class TrustedConnections: ObservableObject {
    static let shared = TrustedConnections()
    static let service = "_duoconnect._tcp"
    @Published private(set) var macs: [NWBrowser.Result] = []
    @Published private(set) var status = ""
    @Published private(set) var connecting = false
    private var listeners: [NWListener] = []
    private var browser: NWBrowser?
    private var request: NWConnection?
    private var candidates: [NWConnection] = []
    private var receiver: StreamReceiver?
    private var linkObservation: AnyCancellable?
    private var hasStreamed = false
    private var serveName = ""
    private var handler: ((String, String, NWEndpoint) -> String?)?
    private var generation = UUID()
    private var observation: NSObjectProtocol?
    private let ownID: String
    private let lookup: (String) throws -> SymmetricKey?
    private let peers: () -> [String]
    init(ownID: String = PairingApprovalCoordinator.localID,
         lookup: @escaping (String) throws -> SymmetricKey? = { try SecurePairingKeyStore.load(peerID: $0) },
         peers: @escaping () -> [String] = { UserDefaults.standard.stringArray(forKey: "duo.securePeers.v1") ?? [] }) {
        self.ownID = ownID; self.lookup = lookup; self.peers = peers
    }
    func listeningPort(for peer: String) -> NWEndpoint.Port? {
        guard let index = peers().firstIndex(of: peer), listeners.indices.contains(index) else { return nil }
        guard case .ready = listeners[index].state, let port = listeners[index].port, port.rawValue != 0 else { return nil }
        return port
    }

    static func identity(_ a: String, _ b: String) -> String { PairedTransport.identity(a, b) }

    func serve(name: String, handler: @escaping (String, String, NWEndpoint) -> String?) {
        self.serveName = name; self.handler = handler
        if observation == nil {
            observation = NotificationCenter.default.addObserver(forName: .init("DuoPairSaved"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshServers() }
            }
        }
        refreshServers()
    }

    private func refreshServers() {
        listeners.forEach { $0.cancel() }; listeners = []
        candidates.forEach { $0.cancel() }; candidates = []
        for peer in peers() {
            do {
                guard let key = try lookup(peer) else { continue }
                let server = try NWListener(using: PairedTransport.parameters(key: key, identity: Self.identity(ownID, peer)))
                var txt = NWTXTRecord(); txt["mac"] = ownID; txt["phone"] = peer; txt["name"] = serveName
                txt["signature"] = Data(HMAC<SHA256>.authenticationCode(for: Self.advertisement(self.ownID, peer, serveName), using: key)).base64EncodedString()
                server.service = .init(name: DeviceNameText.truncated(serveName + " " + String(peer.prefix(6)), maxBytes: 60),
                                       type: Self.service, txtRecord: txt)
                server.newConnectionHandler = { [weak self, weak server] c in
                    Task { @MainActor in
                        guard let self, let server, self.listeners.contains(where: { $0 === server }), self.candidates.count < 8 else { c.cancel(); return }
                        self.candidates.append(c)
                        let expiry = Task { try? await Task.sleep(nanoseconds: 15_000_000_000); if !Task.isCancelled { c.cancel() } }
                        c.stateUpdateHandler = { [weak self] state in
                            if case .ready = state {
                                Task { @MainActor in
                                    defer { expiry.cancel(); c.cancel(); self?.candidates.removeAll { $0 === c } }
                                    guard let self else { return }
                                    do {
                                        var challenge = PairingChallenge(now: Date())
                                        try await Self.send(["nonce": challenge.nonce.base64EncodedString(), "mac": self.ownID, "name": self.serveName], on: c)
                                        let message = try await Self.read(c)
                                        guard let proofText = message["proof"] as? String, let proof = Data(base64Encoded: proofText),
                                              challenge.verify(proof, key: key, purpose: .connect, macID: self.ownID, phoneID: peer, now: Date()),
                                              let receiverID = message["receiver"] as? String, !receiverID.isEmpty,
                                              let port = message["port"] as? UInt16, let p = NWEndpoint.Port(rawValue: port),
                                              case .hostPort(let host, _) = c.endpoint else { throw RequestError.invalid }
                                        let error = self.handler?(peer, receiverID, .hostPort(host: host, port: p)) ?? (self.handler == nil ? "Mac is unavailable." : nil)
                                        try await Self.send(["accepted": error == nil, "message": error ?? "Starting the display…"], on: c)
                                    } catch { /* Authentication or framing failure: close without starting capture. */ }
                                }
                            }
                        }
                        c.start(queue: .main)
                    }
                }
                listeners.append(server); server.start(queue: .main)
            } catch { status = "Unlock the Mac to access saved pairing keys." }
        }
    }

    func browse(receiver: StreamReceiver) {
        observe(receiver)
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.service, domain: nil), using: .tcp)
        browser = b
        b.browseResultsChangedHandler = { [weak self, weak b] results, _ in
            Task { @MainActor in
                guard let self, self.browser === b else { return }
                self.macs = results.filter { self.fields($0)?.phone == self.ownID }
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state { case .failed, .waiting: self?.status = "Mac discovery is unavailable. Check Local Network permission and Wi-Fi."; default: break }
            }
        }
        b.start(queue: .main)
    }

    func name(_ result: NWBrowser.Result) -> String {
        if case .bonjour(let txt) = result.metadata, let name = txt["name"] { return name }
        if case .service(let name, _, _, _) = result.endpoint { return name }
        return "Mac"
    }
    private static func advertisement(_ mac: String, _ phone: String, _ name: String) -> Data {
        try! JSONEncoder().encode(["Duo Display discovery v1", mac, phone, name])
    }
    private func fields(_ result: NWBrowser.Result) -> (mac: String, phone: String)? {
        guard case .bonjour(let txt) = result.metadata, let mac = txt["mac"], let phone = txt["phone"],
              let name = txt["name"], let signature = txt["signature"], let bytes = Data(base64Encoded: signature),
              let key = try? lookup(mac),
              HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: Self.advertisement(mac, phone, name), using: key) else { return nil }
        return (mac, phone)
    }

    func connect(_ result: NWBrowser.Result) {
        guard !connecting, macs.contains(result), let peer = fields(result), let receiver else { return }
        connectTrusted(endpoint: result.endpoint, macID: peer.mac, receiver: receiver)
    }

    func connectTrusted(endpoint: NWEndpoint, macID: String, receiver: StreamReceiver) {
        guard !connecting else { return }
        observe(receiver)
        do {
            guard let key = try lookup(macID) else { status = "Pair with this Mac first."; return }
            UserDefaults.standard.set(macID, forKey: "duo.selectedPairedMac")
            connecting = true; status = "Connecting securely…"
            let token = UUID(); generation = token
            let c = NWConnection(to: endpoint, using: PairedTransport.parameters(key: key, identity: Self.identity(ownID, macID)))
            request = c
            try receiver.startPairedStream(key: key, identity: Self.identity(ownID, macID)) { [weak self] port in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    c.stateUpdateHandler = { [weak self] state in
                        if case .ready = state {
                            Task { @MainActor in
                                guard let self, self.generation == token else { c.cancel(); return }
                                do {
                                    let challenge = try await Self.read(c)
                                    guard challenge["mac"] as? String == macID,
                                          let n = challenge["nonce"] as? String, let nonce = Data(base64Encoded: n),
                                          let proof = PairingChallenge.proof(key: key, nonce: nonce, purpose: .connect, macID: macID, phoneID: self.ownID) else { throw RequestError.invalid }
                                    try await Self.send(["proof": proof.base64EncodedString(), "port": Int(port.rawValue), "receiver": StreamReceiver.installID], on: c)
                                    let response = try await Self.read(c)
                                    guard self.generation == token else { return }
                                    let message = response["message"] as? String ?? "Connection failed. Retry."
                                    guard response["accepted"] as? Bool == true else { self.fail(token, message: message); return }
                                    self.status = message
                                    c.cancel(); self.request = nil
                                    Task { [weak self] in
                                        try? await Task.sleep(nanoseconds: 15_000_000_000)
                                        guard let self, self.generation == token, !receiver.link.phase.isStreaming else { return }
                                        self.fail(token, message: "The Mac did not start video. Check its permissions and retry.")
                                    }
                                } catch { self.fail(token, message: "Mac unreachable or authentication failed. Retry.") }
                            }
                        } else if case .failed = state { Task { @MainActor in self?.fail(token, message: "Mac unreachable. Check Wi-Fi, pairing and permissions.") } }
                    }
                    c.start(queue: .main)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.generation == token, self.connecting else { return }
                self.fail(token, message: "Connection timed out. Check the Mac and retry.")
            }
        } catch { connecting = false; status = "Pairing key or secure listener unavailable. Unlock and retry." }
    }
    private func observe(_ receiver: StreamReceiver) {
        self.receiver = receiver
        linkObservation = receiver.$link.receive(on: DispatchQueue.main).sink { [weak self] link in
            Task { @MainActor in
                guard let self else { return }
                if link.phase.isStreaming {
                    self.connecting = false
                    self.hasStreamed = true
                    self.status = "Connected via " + link.phase.fullLabel
                } else if link.phase.isInTransition {
                    self.status = link.phase.fullLabel
                } else if link.phase == .disconnected, self.hasStreamed {
                    self.hasStreamed = false
                    self.status = "Disconnected. Choose Connect to try again."
                }
            }
        }
    }
    func cancel() { fail(generation, message: "Connection cancelled.") }
    private func fail(_ token: UUID, message: String) {
        guard generation == token else { return }
        generation = UUID(); request?.cancel(); request = nil
        receiver?.disconnectPairedStream(stopListening: true)
        connecting = false; status = message
    }
    enum RequestError: Error { case invalid, closed }
    private static func send(_ object: [String: Any], on c: NWConnection) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        var size = UInt32(data.count).bigEndian; var frame = Data(bytes: &size, count: 4); frame.append(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            c.send(content: frame, completion: .contentProcessed { e in if let e { continuation.resume(throwing: e) } else { continuation.resume() } })
        }
    }
    private static func read(_ c: NWConnection) async throws -> [String: Any] {
        let header = try await exact(c, count: 4)
        let count = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard count > 0, count <= 4096 else { throw RequestError.invalid }
        let data = try await exact(c, count: count)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RequestError.invalid }
        return object
    }
    private static func exact(_ c: NWConnection, count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            c.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: RequestError.closed) }
            }
        }
    }
}
