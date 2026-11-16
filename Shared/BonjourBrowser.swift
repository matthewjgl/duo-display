import Foundation
import Network
import dnssd

/// The parts of a network path that can change what discovery sees. NWPathMonitor
/// re-delivers updates with identical interfaces (observed repeatedly on Wi-Fi);
/// restarting discovery for those cleared device lists and, for the pairing
/// advertiser, withdrew the Mac's service behind an escalating backoff.
struct PathSignature: Equatable {
    var satisfied: Bool
    var interfaces: [String]
    var gateways: [String]
    var ipv4: Bool
    var ipv6: Bool
    init(satisfied: Bool, interfaces: [String], gateways: [String] = [], ipv4: Bool = true, ipv6: Bool = true) {
        self.satisfied = satisfied; self.interfaces = interfaces.sorted(); self.gateways = gateways.sorted()
        self.ipv4 = ipv4; self.ipv6 = ipv6
    }
    init(_ path: NWPath) {
        self.init(satisfied: path.status == .satisfied,
                  interfaces: path.availableInterfaces.map { "\($0.name):\($0.type)" },
                  gateways: path.gateways.map { String(describing: $0) },
                  ipv4: path.supportsIPv4, ipv6: path.supportsIPv6)
    }
}

/// Thread-safe: monitors call back on their own queues. The first update is the
/// baseline (the old `initial` skip); later ones report only a material change.
final class PathChangeFilter {
    private let lock = NSLock()
    private var last: PathSignature?
    func changed(_ path: NWPath) -> Bool { changed(PathSignature(path)) }
    func changed(_ signature: PathSignature) -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { last = signature }
        guard let last else { return false }
        return last != signature
    }
}

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
    private var startupDeadline: Task<Void, Never>?
    private var becameReady = false
    private let startupTimeout: TimeInterval
    private let launch: (NWBrowser) -> Void

    var onResults: (([NWBrowser.Result]) -> Void)?
    var onState: ((NWBrowser.State) -> Void)?

    private let watchesPath: Bool
    /// `watchesPath: false` is for tests that must not depend on the host network.
    init(type: String, txt: Bool = true, retryDelay: TimeInterval = 2,
         startupTimeout: TimeInterval = 10, watchesPath: Bool = true,
         launch: @escaping (NWBrowser) -> Void = { $0.start(queue: .main) }) {
        self.type = type; self.txt = txt; self.retryDelay = retryDelay
        self.startupTimeout = max(0.01, startupTimeout); self.launch = launch
        self.watchesPath = watchesPath
    }
    func start() {
        active = true
        if path == nil, watchesPath {
            let monitor = NWPathMonitor(); path = monitor
            let filter = PathChangeFilter()
            monitor.pathUpdateHandler = { [weak self] update in
                guard filter.changed(update) else { return }
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
        startupDeadline?.cancel(); startupDeadline = nil
        path?.cancel(); path = nil
        let old = browser; browser = nil; old?.cancel()
        results = []; diagnostic = "Stopped"
    }
    private func replace() {
        guard active else { return }
        let old = browser; browser = nil; old?.cancel()
        generation += 1
        startupDeadline?.cancel(); becameReady = false
        results = []; onResults?([])
        let params = NWParameters.tcp
        let descriptor: NWBrowser.Descriptor = txt
            ? .bonjourWithTXTRecord(type: type, domain: "local.")
            : .bonjour(type: type, domain: "local.")
        let b = NWBrowser(for: descriptor, using: params); browser = b
        diagnostic = "Starting \(type) / local. (attempt \(generation), timeout \(Int(startupTimeout))s)"
        let token = generation
        let deadline = startupTimeout
        startupDeadline = Task { [weak self, weak b] in
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            guard !Task.isCancelled, let self, self.active, self.generation == token,
                  let b, self.browser === b, !self.becameReady else { return }
            self.browser = nil; b.cancel()
            self.results = []; self.onResults?([])
            self.diagnostic = "Startup timed out: \(self.type) / local.; no ready callback after \(Int(self.startupTimeout))s (attempt \(token)). Retrying with backoff; cause unconfirmed."
            Log.info("discovery: " + self.diagnostic)
            self.onState?(.waiting(.posix(.ETIMEDOUT)))
            self.retry(after: .posix(.ETIMEDOUT))
        }
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
                self.diagnostic = "\(self.type) / local.: \(state) (attempt \(self.generation), results \(self.results.count))"
                Log.info("discovery: " + self.diagnostic)
                self.onState?(state)
                switch state {
                case .ready:
                    self.becameReady = true; self.startupDeadline?.cancel(); self.startupDeadline = nil
                    self.attempt = 0
                case .failed(let error), .waiting(let error):
                    self.startupDeadline?.cancel(); self.startupDeadline = nil
                    self.results = []; self.onResults?([])
                    self.retry(after: error)
                default: break
                }
            }
        }
        launch(b)
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
    deinit { browser?.cancel(); path?.cancel(); retry?.cancel(); startupDeadline?.cancel() }
}
