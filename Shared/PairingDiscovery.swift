import Foundation
import Network
import Combine

@MainActor
final class PairingDiscovery: ObservableObject {
    static let shared = PairingDiscovery()
    @Published private(set) var macs: [NWBrowser.Result] = []
    @Published private(set) var status = ""
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var exchange: PairingExchange?
    private var window: Task<Void, Never>?
    private static let service = "_duopair._tcp"

    func browse() {
        guard browser == nil else { return }
        let browse = NWBrowser(for: .bonjour(type: Self.service, domain: nil), using: .tcp)
        browser = browse
        browse.browseResultsChangedHandler = { [weak self, weak browse] results, _ in
            Task { @MainActor in
                guard let self, self.browser === browse else { return }
                self.macs = results.sorted { String(describing: $0.endpoint) < String(describing: $1.endpoint) }
            }
        }
        browse.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed, .waiting:
                    self?.status = "Mac discovery is unavailable. Check Local Network permission and network access."
                default: break
                }
            }
        }
        browse.start(queue: .main)
    }

    func advertise(name: String) {
        stop()
        do {
            let listen = try NWListener(using: .tcp)
            listener = listen
            listen.service = NWListener.Service(name: DeviceNameText.truncated(name, maxBytes: 60), type: Self.service)
            listen.newConnectionHandler = { [weak self, weak listen] connection in
                Task { @MainActor in
                    guard let self, let listen, self.listener === listen, self.exchange == nil else { connection.cancel(); return }
                    self.start(connection, name: name, initiator: false)
                }
            }
            listen.start(queue: .main)
            status = "Pairing available for 60 seconds. Compare the code on both devices."
            window = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch { status = "Could not open local pairing. Check Local Network permission." }
    }

    func pair(with mac: NWBrowser.Result, name: String) {
        guard exchange == nil, macs.contains(mac) else { return }
        start(NWConnection(to: mac.endpoint, using: .tcp), name: name, initiator: true)
    }

    private func start(_ connection: NWConnection, name: String, initiator: Bool) {
        let exchange = PairingExchange(connection: connection, coordinator: .shared,
            ownID: PairingApprovalCoordinator.localID, name: name, initiator: initiator)
        self.exchange = exchange
        status = "Connecting for pairing…"
        exchange.onComplete = { [weak self] _, _ in
            self?.status = "Paired securely. Look for the Mac under Your Macs."
            self?.exchange?.cancel(); self?.exchange = nil
        }
        exchange.onFailure = { [weak self] _ in
            self?.status = "Pairing interrupted or rejected. Try again."
            self?.exchange = nil
        }
        exchange.start()
    }

    func stop() {
        window?.cancel(); window = nil
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil; macs = []
        exchange?.cancel(); exchange = nil
    }
}
