import Foundation
import Network
import Combine

/// A bounded, explicit first-pairing window. Advertising is not authorization:
/// PairingExchange still requires matching-code approval on both devices.
@MainActor
final class PairingDiscovery: ObservableObject {
    static let shared = PairingDiscovery()
    static let service = "_duopair._tcp"
    static let domain = "local."
    @Published private(set) var macs: [NWBrowser.Result] = []
    @Published private(set) var status = ""
    @Published private(set) var browserState = "Not searching"
    @Published private(set) var advertiserState = "Pairing is closed"
    @Published private(set) var isAdvertising = false
    private var browser: BonjourBrowser?
    private var listener: NWListener?
    private var advertisedName: String?
    private var persistent = false
    private var path: NWPathMonitor?
    private var recovery: Task<Void, Never>?
    private var recoveryAttempt = 0
    private var registrationBlocked = false
    var onApprovalNeeded: (() -> Void)?

    private var exchange: PairingExchange?
    private var window: Task<Void, Never>?
    private var emptyHint: Task<Void, Never>?
    private let hintDelay: TimeInterval
    private let pairingWindow: TimeInterval

    init(hintDelay: TimeInterval = 8, pairingWindow: TimeInterval = 60) {
        self.hintDelay = max(0.01, hintDelay)
        self.pairingWindow = max(0.01, min(60, pairingWindow))
    }

    var diagnostics: String {
        "App: \(DiscoveryGuidance.localVersion())\nBonjour: \(Self.service) / \(Self.domain)\nBrowser: \(browserState)\nAdvertiser: \(advertiserState)\nPairable Macs: \(macs.count)"
    }

    /// A deliberate retry replaces even a failed browser. It never resets keys
    /// or interrupts an in-progress pairing exchange or display session.
    func browse() {
        guard exchange == nil else { return }
        browser?.cancel(); emptyHint?.cancel(); macs = []
        let browse = BonjourBrowser(type: Self.service, txt: false)
        browser = browse
        browserState = "Starting"
        status = DiscoveryGuidance.searching
        browse.onResults = { [weak self, weak browse] results in
            Task { @MainActor in
                guard let self, let browse, self.browser === browse else { return }
                self.macs = results.sorted { String(describing: $0.endpoint) < String(describing: $1.endpoint) }
                if !results.isEmpty {
                    self.status = "Mac available for pairing. Select it and compare the code on both screens."
                } else if self.browserState == "Ready" { self.status = DiscoveryGuidance.noPairableMac }
            }
        }
        browse.onState = { [weak self, weak browse] state in
            Task { @MainActor in
                guard let self, let browse, self.browser === browse else { return }
                switch state {
                case .ready:
                    self.browserState = "Ready"
                    self.emptyHint?.cancel()
                    self.emptyHint = Task { [weak self, weak browse] in
                        guard let self else { return }
                        try? await Task.sleep(nanoseconds: UInt64(self.hintDelay * 1_000_000_000))
                        guard !Task.isCancelled, self.browser === browse, self.macs.isEmpty else { return }
                        self.status = DiscoveryGuidance.noPairableMac
                    }
                case .failed(let error), .waiting(let error):
                    self.emptyHint?.cancel()
                    self.browserState = "Unavailable (\(error))"
                    self.status = DiscoveryGuidance.failure(error, on: .phone)
                case .cancelled: self.browserState = "Stopped"
                default: break
                }
            }
        }
        browse.start()
    }

    func advertise(name: String, persistent: Bool = false) {
        stop()
        self.persistent = persistent; advertisedName = name
        let monitor = NWPathMonitor(); path = monitor
        var initial = true
        monitor.pathUpdateHandler = { [weak self] _ in
            if initial { initial = false; return }
            Task { @MainActor in self?.recover() }
        }
        monitor.start(queue: DispatchQueue(label: "DuoDisplay.pairing-path"))
        openListener(name: name)
    }

    func recover() {
        browser?.recover()
        guard advertisedName != nil, exchange == nil else { return }
        registrationBlocked = false
        scheduleRecovery()
    }

    private func scheduleRecovery() {
        guard recovery == nil, !registrationBlocked, let name = advertisedName else { return }
        // Withdraw before the backoff, not immediately before registering its
        // replacement. Otherwise mDNS can rename the replacement as a collision
        // and leave the previous name cached as an apparently available Mac.
        let retired = listener; listener = nil; isAdvertising = false
        retired?.service = nil; retired?.cancel()
        recoveryAttempt = min(recoveryAttempt + 1, 5)
        recovery = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(1 << (self?.recoveryAttempt ?? 1)) * 1_000_000_000)
            guard !Task.isCancelled, let self, self.advertisedName != nil else { return }
            self.recovery = nil
            guard self.exchange == nil else { return }
            self.openListener(name: name)
        }
    }

    private func openListener(name: String) {
        registrationBlocked = false
        let old = listener; listener = nil; old?.service = nil; old?.cancel()
        window?.cancel(); window = nil; isAdvertising = false
        do {
            let parameters = NWParameters.tcp
            let listen = try NWListener(using: parameters)
            listener = listen
            listen.service = .init(name: DeviceNameText.truncated(name, maxBytes: 60), type: Self.service, domain: Self.domain)
            advertiserState = "Starting listener"
            status = "Opening pairing on the local network…"
            listen.stateUpdateHandler = { [weak self, weak listen] state in
                Task { @MainActor in
                    guard let self, let listen, self.listener === listen else { return }
                    switch state {
                    case .ready:
                        if !self.isAdvertising { self.advertiserState = "Listener ready; registering Bonjour" }
                    case .waiting(let error), .failed(let error):
                        self.isAdvertising = false
                        self.advertiserState = "Unavailable (\(error))"
                        self.status = DiscoveryGuidance.failure(error, on: .mac)
                        self.registrationBlocked = DiscoveryGuidance.isPolicyDenied(error)
                        if !DiscoveryGuidance.isPolicyDenied(error) { self.scheduleRecovery() }
                    case .cancelled: self.isAdvertising = false
                    default: break
                    }
                }
            }
            listen.serviceRegistrationUpdateHandler = { [weak self, weak listen] change in
                Task { @MainActor in
                    guard let self, let listen, self.listener === listen else { return }
                    switch change {
                    case .add:
                        self.isAdvertising = true
                        self.advertiserState = "Bonjour registered"
                        self.recoveryAttempt = 0; self.recovery?.cancel(); self.recovery = nil
                        self.status = self.persistent
                            ? "Ready for pairing. Select this Mac on the iPhone, then approve matching codes on both screens."
                            : "Ready for pairing for 60 seconds. On the iPhone, tap Find Macs, then compare the code on both screens."
                        self.window?.cancel()
                        guard !self.persistent else { return }
                        self.window = Task { [weak self] in
                            guard let self else { return }
                            try? await Task.sleep(nanoseconds: UInt64(self.pairingWindow * 1_000_000_000))
                            guard !Task.isCancelled, self.listener === listen else { return }
                            self.stop()
                            self.status = "Pairing window closed. Choose Pair a phone to open it again."
                        }
                    case .remove:
                        self.isAdvertising = false
                        self.advertiserState = "Bonjour registration removed"
                        self.status = "Pairing advertisement lost. Restoring discovery…"
                        self.scheduleRecovery()
                    @unknown default: break
                    }
                }
            }
            listen.newConnectionHandler = { [weak self, weak listen] connection in
                Task { @MainActor in
                    guard let self, let listen, self.listener === listen, self.exchange == nil else { connection.cancel(); return }
                    self.start(connection, name: name, initiator: false)
                }
            }
            listen.start(queue: .main)
            // Registration can fail without ever becoming ready; never leave a
            // silent, indefinitely starting listener or claim it is discoverable.
            window = Task { [weak self, weak listen] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self, let listen, self.listener === listen, !self.isAdvertising, !self.registrationBlocked else { return }
                self.listener?.cancel(); self.listener = nil
                self.advertiserState = "Registration did not complete"
                self.status = "Pairing registration did not complete. Retrying; check Local Network access and network isolation if this persists."
                self.scheduleRecovery()
            }
        } catch {
            advertiserState = "Listener creation failed"
            status = "Could not open local pairing. The cause is not confirmed; retrying."
            scheduleRecovery()
        }
    }

    func pair(with mac: NWBrowser.Result, name: String) {
        guard exchange == nil, macs.contains(mac) else { return }
        emptyHint?.cancel()
        start(NWConnection(to: mac.endpoint, using: .tcp), name: name, initiator: true)
    }

    private func start(_ connection: NWConnection, name: String, initiator: Bool) {
        let exchange = PairingExchange(connection: connection, coordinator: .shared,
            ownID: PairingApprovalCoordinator.localID, name: name, initiator: initiator)
        self.exchange = exchange
        exchange.onPrompt = { [weak self] in self?.onApprovalNeeded?() }
        status = "Connecting for pairing…"
        exchange.onComplete = { [weak self] _, _ in
            self?.status = "Paired securely. Look for the Mac under Your Macs."
            self?.exchange?.cancel(); self?.exchange = nil
            if self?.persistent == true { self?.recover() }
        }
        exchange.onFailure = { [weak self] _ in
            self?.status = "Pairing interrupted or rejected. Choose Pair a phone on the Mac, then Find Macs to try again."
            self?.exchange = nil
            if self?.persistent == true { self?.recover() }
        }
        exchange.start()
    }

    func stop() {
        advertisedName = nil; persistent = false
        recovery?.cancel(); recovery = nil; recoveryAttempt = 0
        path?.cancel(); path = nil
        window?.cancel(); window = nil
        emptyHint?.cancel(); emptyHint = nil
        listener?.service = nil; listener?.cancel(); listener = nil; isAdvertising = false
        advertiserState = "Pairing is closed"
        browser?.cancel(); browser = nil; macs = []; browserState = "Not searching"
        exchange?.cancel(); exchange = nil
    }
}
