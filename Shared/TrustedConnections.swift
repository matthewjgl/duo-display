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
    @Published private(set) var serverStatus = "No paired-Mac service started"
    private var listeners: [String: NWListener] = [:]
    private var browser: BonjourBrowser?
    private var request: NWConnection?
    private var candidates: [NWConnection] = []
    private var receiver: StreamReceiver?
    private var linkObservation: AnyCancellable?
    private var hasStreamed = false
    private var serveName = ""
    private var handler: ((String, String, NWEndpoint) -> String?)?
    private var generation = UUID()
    @Published private(set) var rememberedPeers: [TrustedPeerRegistry.Record] = []
    @Published var allowTrustedPhones: Bool {
        didSet {
            preferences.set(allowTrustedPhones, forKey: "duo.allowTrustedPhones.v1")
            if !allowTrustedPhones { onDisabled?() }
            refreshServers()
        }
    }
    var onRevoked: ((String) -> Void)?
    var onDisabled: (() -> Void)?
    private var availability: () -> String? = { nil }
    private var suspended = false
    private var lifecycleActive = false
    private var observers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    private var recovery: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var retryCount = 0
    private var selectedMac: String?
    private let preferences: UserDefaults
    private let erase: (String) throws -> Void
    private let requestTimeout: TimeInterval

    private let ownID: String
    private let lookup: (String) throws -> SymmetricKey?
    private let peers: () -> [String]
    init(ownID: String = PairingApprovalCoordinator.localID,
         lookup: @escaping (String) throws -> SymmetricKey? = { try SecurePairingKeyStore.load(peerID: $0) },
         peers: @escaping () -> [String] = { UserDefaults.standard.stringArray(forKey: "duo.securePeers.v1") ?? [] },
         preferences: UserDefaults = .standard,
         requestTimeout: TimeInterval = 15,
         erase: @escaping (String) throws -> Void = { try SecurePairingKeyStore.remove(peerID: $0) }) {
        self.ownID = ownID; self.lookup = lookup; self.peers = peers
        self.preferences = preferences; self.erase = erase
        self.requestTimeout = max(0.05, min(15, requestTimeout))
        self.allowTrustedPhones = preferences.object(forKey: "duo.allowTrustedPhones.v1") as? Bool ?? true
        refreshRecords()
    }
    deinit {
        listeners.values.forEach { $0.cancel() }; candidates.forEach { $0.cancel() }
        request?.cancel(); pathMonitor?.cancel()
        recovery?.cancel(); retry?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    func listeningPort(for peer: String) -> NWEndpoint.Port? {
        guard let listener = listeners[peer], case .ready = listener.state,
              let port = listener.port, port.rawValue != 0 else { return nil }
        return port
    }

    static func identity(_ a: String, _ b: String) -> String { PairedTransport.identity(a, b) }

    private func refreshRecords() {
        rememberedPeers = TrustedPeerRegistry.records(peers: peers(), defaults: preferences)
    }

    private func watchLifecycle() {
        lifecycleActive = true
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: .init("DuoPairSaved"), object: nil, queue: .main) { [weak self] note in
            let peer = note.object as? String
            Task { @MainActor in
                guard let self, self.lifecycleActive else { return }
                if let peer {
                    // Explicit re-pairing replaces the old key. Retire old Wi-Fi
                    // sessions before restoring listeners with the new key.
                    self.onRevoked?(peer)
                    if self.selectedMac == peer || self.preferences.string(forKey: "duo.selectedPairedMac") == peer {
                        self.receiver?.disconnectPairedStream(stopListening: true)
                    }
                }
                self.refreshRecords(); self.recoverAfterEnvironmentChange()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .init("DuoPairRevoked"), object: nil, queue: .main) { [weak self] note in
            guard let peer = note.object as? String else { return }
            Task { @MainActor in
                guard let self, self.lifecycleActive else { return }
                self.didRevoke(peer)
            }
        })
        let monitor = NWPathMonitor(); pathMonitor = monitor
        var first = true
        monitor.pathUpdateHandler = { [weak self] _ in
            if first { first = false; return }
            Task { @MainActor in self?.scheduleRecovery() }
        }
        monitor.start(queue: DispatchQueue(label: "DuoDisplay.trusted-network"))
    }

    func serve(name: String, availability: @escaping () -> String? = { nil },
               handler: @escaping (String, String, NWEndpoint) -> String?) {
        self.serveName = name; self.handler = handler; self.availability = availability
        watchLifecycle(); refreshRecords(); refreshServers()
    }

    private func scheduleRecovery() {
        guard lifecycleActive else { return }
        recovery?.cancel()
        recovery = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.recoverAfterEnvironmentChange()
        }
    }
    /// Called by network changes, wake, foreground return and explicit Refresh.
    /// Rebuilds discovery/control listeners, never bypasses pairing or restarts capture.
    func recoverAfterEnvironmentChange() {
        guard lifecycleActive else { return }
        retry?.cancel(); retry = nil; retryCount = 0
        refreshRecords()
        if connecting { fail(generation, message: "Network changed. Check the Mac is awake and retry.") }
        refreshServers()
        if let receiver {
            if let peer = selectedMac ?? preferences.string(forKey: "duo.selectedPairedMac"), let key = try? lookup(peer) {
                let keyLookup = lookup
                try? receiver.startPairedStream(key: key, identity: Self.identity(ownID, peer), onReady: nil, authorize: {
                    guard let current = try? keyLookup(peer) else { return false }
                    return Self.sameKey(current, key)
                })
            }
            retryBrowse(receiver: receiver)
        }
    }
    func suspendForSleep() {
        suspended = true; stopServers()
        serverStatus = "Mac asleep or session unavailable. Wake and unlock it before connecting."
    }
    func resumeAfterWake() { suspended = false; recoverAfterEnvironmentChange() }
    private func stopServers() {
        listeners.values.forEach { $0.cancel() }; listeners = [:]
        candidates.forEach { $0.cancel() }; candidates = []
    }
    func shutdown() {
        lifecycleActive = false
        handler = nil
        recovery?.cancel(); retry?.cancel(); pathMonitor?.cancel(); pathMonitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        stopServers(); browser?.cancel(); browser = nil; request?.cancel(); request = nil
        generation = UUID(); connecting = false; linkObservation = nil
    }
    func revoke(_ peer: String) {
        do { try erase(peer); didRevoke(peer) }
        catch { didRevoke(peer); status = "Access revoked locally. Keychain removal failed; unlock and retry removal." }
    }
    private func didRevoke(_ peer: String) {
        refreshRecords(); onRevoked?(peer)
        if selectedMac == peer || preferences.string(forKey: "duo.selectedPairedMac") == peer {
            preferences.removeObject(forKey: "duo.selectedPairedMac")
            fail(generation, message: "Pairing revoked. Approve a new pairing on both devices to reconnect.")
            selectedMac = nil
        }
        macs.removeAll { fields($0)?.mac == peer || fields($0) == nil }
        refreshServers()
    }
    private func scheduleServerRetry() {
        guard retry == nil, !suspended, allowTrustedPhones else { return }
        retryCount = min(retryCount + 1, 5)
        let delay = UInt64(1 << retryCount) * 1_000_000_000
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.retry = nil; self.refreshServers()
        }
    }

    private func refreshServers() {
        stopServers()
        guard handler != nil else { return }
        guard allowTrustedPhones, !suspended else {
            serverStatus = "Trusted-phone connections are disabled or the Mac is asleep."
            return
        }
        serverStatus = "No paired-Mac service registered; pair a phone first."
        candidates.forEach { $0.cancel() }; candidates = []
        for peer in peers() {
            do {
                guard let key = try lookup(peer) else { continue }
                let server = try NWListener(using: PairedTransport.parameters(key: key, identity: Self.identity(ownID, peer)))
                var txt = NWTXTRecord(); txt["mac"] = ownID; txt["phone"] = peer; txt["name"] = serveName
                let state = availability() ?? "ready"
                txt["state"] = state
                txt["signature"] = Data(HMAC<SHA256>.authenticationCode(for: Self.advertisement(self.ownID, peer, serveName, state: state), using: key)).base64EncodedString()
                server.service = .init(name: DeviceNameText.truncated(serveName + " " + String(peer.prefix(6)), maxBytes: 60),
                                       type: Self.service, domain: PairingDiscovery.domain, txtRecord: txt)
                server.newConnectionHandler = { [weak self, weak server] c in
                    Task { @MainActor in
                        guard let self, let server, self.allowTrustedPhones, !self.suspended,
                              self.listeners[peer] === server, self.candidates.count < 8 else { c.cancel(); return }
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
                                        // Re-check current trust after TLS/challenge. A captured key from a
                                        // retired listener must never authorize a revoked/disabled peer.
                                        guard self.allowTrustedPhones, !self.suspended, self.listeners[peer] === server,
                                              let current = try self.lookup(peer),
                                              Self.sameKey(current, key) else { throw RequestError.invalid }
                                        let error = self.availability() ?? self.handler?(peer, receiverID, .hostPort(host: host, port: p)) ?? (self.handler == nil ? "Mac is unavailable." : nil)
                                        try await Self.send(["accepted": error == nil, "message": error ?? "Starting the display…"], on: c)
                                    } catch { /* Authentication or framing failure: close without starting capture. */ }
                                }
                            }
                        }
                        c.start(queue: .main)
                    }
                }
                server.stateUpdateHandler = { [weak self, weak server] state in
                    Task { @MainActor in
                        guard let self, let server, self.listeners[peer] === server else { return }
                        switch state {
                        case .waiting(let error), .failed(let error):
                            self.serverStatus = DiscoveryGuidance.failure(error, on: .mac)
                            self.scheduleServerRetry()
                        default: break
                        }
                    }
                }
                server.serviceRegistrationUpdateHandler = { [weak self, weak server] change in
                    Task { @MainActor in
                        guard let self, let server, self.listeners[peer] === server else { return }
                        switch change {
                        case .add:
                            self.retry?.cancel(); self.retry = nil; self.retryCount = 0
                            self.serverStatus = "Paired-Mac Bonjour service registered."
                        case .remove:
                            self.serverStatus = "Paired-Mac Bonjour registration lost. Restoring discovery…"
                            self.scheduleServerRetry()
                        @unknown default: break
                        }
                    }
                }
                listeners[peer] = server; server.start(queue: .main)
            } catch { serverStatus = "Saved pairing keys unavailable. Unlock the Mac; secure discovery will retry automatically."; scheduleServerRetry() }
        }
    }

    func retryBrowse(receiver: StreamReceiver) {
        guard !connecting else { return }
        browser?.cancel(); browser = nil; macs = []
        browse(receiver: receiver)
    }

    func browse(receiver: StreamReceiver) {
        observe(receiver); watchLifecycle(); refreshRecords()
        guard browser == nil else { return }
        let b = BonjourBrowser(type: Self.service)
        browser = b
        if !connecting && !receiver.connected { status = DiscoveryGuidance.noTrustedMac }
        b.onResults = { [weak self, weak b] results in
            Task { @MainActor in
                guard let self, let b, self.browser === b else { return }
                self.macs = results.filter { self.fields($0)?.phone == self.ownID }
                for result in self.macs {
                    if let peer = self.fields(result) {
                        TrustedPeerRegistry.rememberName(self.name(result), peer: peer.mac, defaults: self.preferences)
                    }
                }
                self.refreshRecords()
                if !self.connecting && !receiver.connected {
                    self.status = self.macs.isEmpty ? DiscoveryGuidance.noTrustedMac : "Paired Mac found. Tap Connect; its permissions and availability will be checked securely."
                }
            }
        }
        b.onState = { [weak self, weak b] state in
            Task { @MainActor in
                guard let self, let b, self.browser === b else { return }
                switch state { case .failed(let error), .waiting(let error): self.status = DiscoveryGuidance.failure(error, on: .phone); default: break }
            }
        }
        b.start()
    }

    func name(_ result: NWBrowser.Result) -> String {
        if case .bonjour(let txt) = result.metadata, let name = txt["name"] { return name }
        if case .service(let name, _, _, _) = result.endpoint { return name }
        return "Mac"
    }
    private static func advertisement(_ mac: String, _ phone: String, _ name: String, state: String? = nil) -> Data {
        if let state { return try! JSONEncoder().encode(["Duo Display discovery v2", mac, phone, name, state]) }
        return try! JSONEncoder().encode(["Duo Display discovery v1", mac, phone, name])
    }
    nonisolated static func sameKey(_ a: SymmetricKey, _ b: SymmetricKey) -> Bool {
        let bytes = a.withUnsafeBytes { Data($0) }
        let tag = HMAC<SHA256>.authenticationCode(for: bytes, using: b)
        return HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: b.withUnsafeBytes { Data($0) }, using: b)
    }
    func result(for peer: String) -> NWBrowser.Result? { macs.first { fields($0)?.mac == peer } }
    func availabilityLabel(for peer: String) -> String {
        guard let result = result(for: peer) else { return "Unavailable — the Mac may be asleep/offline, trusted connections disabled, or this pairing revoked. It must be awake, unlocked and running Duo Display on this network." }
        if case .bonjour(let txt) = result.metadata, let state = txt["state"] { return state == "ready" ? "Ready to connect" : state }
        return "Available — readiness checked when connecting"
    }
    func canConnect(to peer: String) -> Bool {
        guard let result = result(for: peer), !connecting else { return false }
        // TXT availability is a hint and can be stale after a permission change.
        // The authenticated request checks current readiness before starting capture.
        _ = result
        return true
    }
    func connectPeer(_ peer: String) {
        guard let result = result(for: peer) else { status = availabilityLabel(for: peer); return }
        connect(result)
    }
    private func fields(_ result: NWBrowser.Result) -> (mac: String, phone: String)? {
        guard case .bonjour(let txt) = result.metadata, let mac = txt["mac"], let phone = txt["phone"],
              let name = txt["name"], let signature = txt["signature"], let bytes = Data(base64Encoded: signature),
              let key = try? lookup(mac),
              HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: Self.advertisement(mac, phone, name, state: txt["state"]), using: key) else { return nil }
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
            preferences.set(macID, forKey: "duo.selectedPairedMac")
            selectedMac = macID
            connecting = true; status = "Connecting securely…"
            let token = UUID(); generation = token
            let c = NWConnection(to: endpoint, using: PairedTransport.parameters(key: key, identity: Self.identity(ownID, macID)))
            request = c
            let keyLookup = lookup
            try receiver.startPairedStream(key: key, identity: Self.identity(ownID, macID), onReady: { [weak self] port in
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
                                        try? await Task.sleep(nanoseconds: UInt64((self?.requestTimeout ?? 15) * 1_000_000_000))
                                        guard let self, self.generation == token, !receiver.link.phase.isStreaming else { return }
                                        self.fail(token, message: "The Mac did not start video. Wake and unlock it, check capture/control permissions, then retry.")
                                    }
                                } catch { self.fail(token, message: "Mac unreachable or authentication failed. Retry.") }
                            }
                        } else {
                            switch state {
                            case .failed, .waiting:
                                Task { @MainActor in self?.fail(token, message: "Mac unreachable or pairing key rejected. Check that it is awake, unlocked and running Duo Display on this network, then retry.") }
                            default: break
                            }
                        }
                    }
                    c.start(queue: .main)
                }
            }, authorize: {
                guard let current = try? keyLookup(macID) else { return false }
                return Self.sameKey(current, key)
            })
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.requestTimeout ?? 15) * 1_000_000_000))
                guard let self, self.generation == token, self.connecting else { return }
                self.fail(token, message: "Connection timed out. Check the Mac and retry.")
            }
        } catch { fail(generation, message: "Pairing key or secure listener unavailable. Unlock and retry.") }
    }
    private func observe(_ receiver: StreamReceiver) {
        self.receiver = receiver
        linkObservation = receiver.$link.receive(on: DispatchQueue.main).sink { [weak self] link in
            Task { @MainActor in
                guard let self, receiver.link == link else { return }
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
        generation = UUID(); request?.cancel(); request = nil; hasStreamed = false
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
