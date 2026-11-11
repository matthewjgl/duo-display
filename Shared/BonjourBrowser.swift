import Foundation
import Network
import dnssd

/// One browser per role. Failed browsers are terminal; replace them with bounded
/// backoff. Path changes and foreground retries retire old callbacks first.
@MainActor
final class BonjourBrowser {
    private(set) var results: [NWBrowser.Result] = []
    private(set) var diagnostic = "Stopped"
    private(set) var generation = 0
    private let type: String
    private let txt: Bool
    private let retryDelay: TimeInterval
    private var browser: NWBrowser?
    private var path: NWPathMonitor?
    private var retry: Task<Void, Never>?
    private var attempt = 0
    private var active = false
    var onResults: (([NWBrowser.Result]) -> Void)?
    var onState: ((NWBrowser.State) -> Void)?

    init(type: String, txt: Bool = true, retryDelay: TimeInterval = 2) {
        self.type = type; self.txt = txt; self.retryDelay = retryDelay
    }
    func start() {
        active = true
        if path == nil {
            let monitor = NWPathMonitor(); path = monitor
            var initial = true
            monitor.pathUpdateHandler = { [weak self] _ in
                if initial { initial = false; return }
                Task { @MainActor in self?.recover() }
            }
            monitor.start(queue: DispatchQueue(label: "DuoDisplay.discovery-path"))
        }
        replace()
    }
    func recover() {
        guard active else { return }
        retry?.cancel(); retry = nil
        // Debounce roaming/wake bursts; never restart capture or pairing keys.
        scheduleRetry(delay: 0.4)
    }
    func cancel() {
        active = false; retry?.cancel(); retry = nil
        path?.cancel(); path = nil
        let old = browser; browser = nil; old?.cancel()
        results = []; diagnostic = "Stopped"
    }
    private func replace() {
        guard active else { return }
        let old = browser; browser = nil; old?.cancel()
        generation += 1
        results = []; onResults?([])
        let params = NWParameters.tcp
        let descriptor: NWBrowser.Descriptor = txt
            ? .bonjourWithTXTRecord(type: type, domain: "local.")
            : .bonjour(type: type, domain: "local.")
        let b = NWBrowser(for: descriptor, using: params); browser = b
        diagnostic = "Starting \(type) / local."
        b.browseResultsChangedHandler = { [weak self, weak b] results, _ in
            Task { @MainActor in
                guard let self, let b, self.browser === b else { return }
                self.results = Array(results)
                self.onResults?(self.results)
            }
        }
        b.stateUpdateHandler = { [weak self, weak b] state in
            Task { @MainActor in
                guard let self, let b, self.browser === b else { return }
                self.diagnostic = "\(self.type) / local.: \(state)"
                self.onState?(state)
                switch state {
                case .ready: self.attempt = 0
                case .failed(let error), .waiting(let error):
                    self.results = []; self.onResults?([])
                    self.retry(after: error)
                default: break
                }
            }
        }
        b.start(queue: .main)
    }
    /// Shared by the browser callback and recovery tests. A real failure must
    /// replace the terminal NWBrowser, not just update an error label.
    func retry(after error: NWError) {
        guard active, !DiscoveryGuidance.isPolicyDenied(error) else { return }
        attempt = min(attempt + 1, 5)
        scheduleRetry(delay: min(32, retryDelay * pow(2, Double(attempt - 1))))
    }
    private func scheduleRetry(delay: TimeInterval) {
        guard active, retry == nil else { return }
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.active else { return }
            self.retry = nil; self.replace()
        }
    }
    deinit { browser?.cancel(); path?.cancel(); retry?.cancel() }
}
