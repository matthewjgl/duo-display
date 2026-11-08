import SwiftUI
import Network
import Combine
import Sparkle
import dnssd

/// How the app presents itself. One bundle, switched at runtime via the
/// activation policy — like Raycast/Hammerspoon style background agents.
enum AppPresentation: String, CaseIterable {
    case menuBar, dock, background

    var label: String {
        switch self {
        case .menuBar: return "Menu bar"
        case .dock: return "Dock"
        case .background: return "Background only"
        }
    }
}

@main
struct DuoDisplayMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = SenderController.shared

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { controller.presentation == .menuBar },
            set: { _ in }
        )) {
            ContentView(controller: controller, updater: appDelegate.updater)
        } label: {
            // Optional compact "18 ms" next to the icon (Settings: "Show
            // latency next to the menu bar icon"). Off by default.
            HStack(spacing: 4) {
                Image(systemName: controller.running
                      ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
                if controller.showLatencyInMenuBar, !controller.menuBarCompact.isEmpty {
                    Text(controller.menuBarCompact).monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Development builds keep their own identity and must never update to Release.
    #if DEBUG
    let updater: SPUStandardUpdaterController? = nil
    #else
    let updater: SPUStandardUpdaterController? = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hand the updater to the control window, which is built outside the
        // SwiftUI App scene (NSHostingView), so it can offer the same button.
        MainWindow.updater = updater
        let presentation = SenderController.shared.presentation
        NSApp.setActivationPolicy(presentation == .dock ? .regular : .accessory)
        if presentation != .menuBar {
            MainWindow.show()
        }
    }

    // Background/Dock modes: opening the app again (Spotlight, Finder, Dock
    // click) brings up the control window — Hammerspoon-style.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        MainWindow.show()
        return false
    }
}

/// The control panel as a regular window, for Dock/background presentation.
@MainActor
enum MainWindow {
    private static var window: NSWindow?
    // Set once at launch by AppDelegate so the control window can share the
    // app's single Sparkle updater.
    static var updater: SPUStandardUpdaterController?

    static func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(origin: .zero, size: ContentView.size),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = "Duo Display"
            w.contentView = NSHostingView(
                rootView: ContentView(controller: SenderController.shared,
                                      updater: updater))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum ConnectionTarget: Hashable {
    case usb(udid: String?)           // wired via built-in usbmuxd; nil = first device
    case wifi(NWBrowser.Result)       // discovered via Bonjour

    /// Stable identity for sessions and persistence — survives Bonjour
    /// re-discovery (fresh NWBrowser.Result) and USB replugs (new DeviceID).
    var sessionID: String {
        switch self {
        case .usb(let udid): return "usb:\(udid ?? "first")"
        case .wifi(let result):
            if case .service(let name, _, _, _) = result.endpoint { return "wifi:\(name)" }
            return "wifi:unknown"
        }
    }
}

/// One connected (or connecting) device: its target, its sender pipeline,
/// and the per-device status the UI shows. Each session owns a full pipeline
/// — virtual display, capture, encoder, socket — so devices are independent:
/// one disconnecting never stalls the others.
@MainActor
final class DeviceSession: ObservableObject, Identifiable {
    nonisolated let id: String
    let target: ConnectionTarget
    let name: String
    let sender: MacSender

    @Published var status = "Starting…"
    @Published var framesSent = 0
    // Latest `live` report from the phone (~1 Hz): the phone's own measured
    // capture->display latency and received FPS. nil until one arrives, which
    // is also what an older phone app (no `live` message) looks like.
    @Published var live: LiveStats?
    var liveAt: Date?
    /// The report counts as current only while it keeps arriving.
    func liveIsFresh(at now: Date = Date()) -> Bool {
        guard let liveAt else { return false }
        return now.timeIntervalSince(liveAt) <= LiveStats.staleAfter
    }
    // The sender's start() threw: the pipeline is freed, only this row's
    // error text remains. A failed session must never swallow a fresh
    // connect for its device the way a live one does.
    @Published var failed = false
    @Published var wirelessHandoffAllowed = false
    @Published var selectedQuality: StreamQuality = .best
    @Published var guidance: ConnectionGuidance?
    @Published var performanceHealth = PerformanceHealth()
    @Published var transportPending = true
    var usbUpgradeSuppressed = false
    var usbUnavailable = false
    // Receiver's per-install identity (from hello) — the key for recognizing
    // the same physical device across USB and WiFi.
    var deviceID: String?
    // "iPhone" / "iPad" from hello — naming fallback while (or in case)
    // lockdown hasn't resolved the device's real name.
    var deviceKind: String?
    // Power actions the receiver offers on the live path (PROTOCOL.md 6.6).
    // Every hello replaces it, so it follows the session on and off the cable.
    @Published var powerActions: [PowerAction] = []
    // `target` names the identity the session was created for; the live
    // transport can migrate (cable-in upgrade, unplug failover) — these
    // track where the sender actually is right now.
    @Published var onUSB: Bool
    // The udid the session is (or was last) cabled through, so a usbmuxd
    // detach can be matched back to this session for failover.
    var usbUDID: String?
    // The Bonjour service name this session was started from or failed over
    // to. Kept because browse results routinely arrive without their TXT
    // record (no install id to match on) and the USB device is detached
    // after a failover — the name is then the only link between the session
    // and its service row.
    var wifiServiceName: String?
    // Logged once per unplug while waiting for the Wi-Fi service to appear.
    var waitingForWiFiLogged = false

    // The live TCP path runs over a cable (Thunderbolt Bridge / Ethernet)
    // rather than WiFi — reported by the sender once connected.
    @Published var wired = false

    var transportLabel: String { onUSB ? "USB" : wired ? "Cable" : "WiFi" }

    // The Display size control (extend only): the choice for this device
    // and what each choice gives on it, from the latest hello.
    private var lastHello: PhoneInfo?
    @Published private(set) var displaySize: DisplaySize = .default
    @Published private(set) var displaySizeOutcomes: [DisplaySizeOutcome] = []

    func helloArrived(_ info: PhoneInfo) {
        lastHello = info
        wirelessHandoffAllowed = DeviceSetupStore.load(info.id).wirelessAllowed
        selectedQuality = DeviceSetupStore.quality(info.id, fallback: selectedQuality)
        refreshDisplaySize()
    }

    func beginTransportChange(_ message: String) {
        status = message
        transportPending = true
        live = nil
        liveAt = nil
        performanceHealth = PerformanceHealth()
        guidance = nil
    }

    func allowWirelessHandoff(_ allowed: Bool) {
        guard DeviceIdentity.valid(deviceID) != nil else { return }
        guard DeviceSetupStore.update(deviceID, { $0.wirelessAllowed = allowed }) else {
            guidance = .newerSettings; return
        }
        wirelessHandoffAllowed = allowed
    }

    func setQuality(_ quality: StreamQuality) {
        guard DeviceIdentity.valid(deviceID) != nil else { return }
        guard sender.setQuality(quality, for: deviceID) else { guidance = .newerSettings; return }
        selectedQuality = quality
    }

    func setDisplaySize(_ size: DisplaySize) {
        guard let info = lastHello else { return }
        sender.setDisplaySize(size, for: info)
        refreshDisplaySize()
    }

    /// Also called when the picker opens: the outcomes can change without a
    /// hello (an HEVC failure, a refused 2x mode).
    func refreshDisplaySize() {
        guard let info = lastHello else { return }
        displaySize = DisplaySizeStore.load(key: sender.displaySizeKey(for: info))
        let outcomes = sender.displaySizeOutcomes(for: info)
        if outcomes != displaySizeOutcomes { displaySizeOutcomes = outcomes }
    }

    init(id: String, target: ConnectionTarget, name: String, sender: MacSender) {
        self.id = id
        self.target = target
        self.name = name
        self.sender = sender
        if case .usb(let udid) = target {
            onUSB = true
            usbUDID = udid
        } else {
            onUSB = false
        }
    }
}

@MainActor
final class SenderController: ObservableObject {
    static let shared = SenderController()

    @Published var presentation = AppPresentation(
        rawValue: UserDefaults.standard.string(forKey: "presentation") ?? "") ?? .menuBar {
        didSet {
            UserDefaults.standard.set(presentation.rawValue, forKey: "presentation")
            NSApp.setActivationPolicy(presentation == .dock ? .regular : .accessory)
            // Never strand the user without UI: leaving menu-bar mode opens
            // the window immediately.
            if presentation != .menuBar { MainWindow.show() }
        }
    }

    @Published var sessions: [DeviceSession] = []
    @Published var discovered: [NWBrowser.Result] = []
    // Every cabled device: usbmuxd's iPhones and iPads plus Android devices
    // in accessory mode (udid `aoa:<serial>`). The connection policy treats
    // them alike.
    @Published var usbDevices: [UsbmuxDevice] = []
    private var usbmuxDevices: [UsbmuxDevice] = []
    private var accessoryDevices: [UsbmuxDevice] = []
    // `-host x.x.x.x` / `-port n` bypass usbmuxd with a manual TCP endpoint
    // (debugging escape hatch, e.g. an iproxy or SSH tunnel).
    @Published var host = UserDefaults.standard.string(forKey: "host") ?? "127.0.0.1"
    @Published var port = UserDefaults.standard.string(forKey: "port") ?? "9000"
    // `-mode mirror` / `-mode extend` launch argument also works.
    @Published var mode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .extend
    @Published var quality = StreamQuality(rawValue: UserDefaults.standard.string(forKey: "quality") ?? "") ?? .best {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") }
    }

    /// Codec A/B switch: Auto (HEVC when both ends can), or force HEVC / H.264.
    /// Takes effect by restarting the sessions (see the Codec picker).
    @Published var codecPreference = CodecPreference.stored {
        didSet { UserDefaults.standard.set(codecPreference.rawValue, forKey: CodecPreference.defaultsKey) }
    }
    /// Plug in the cable and the Mac dials the phone on its own (the phone app
    /// must be open in the foreground — iOS cannot be launched from the Mac).
    /// On by default. Off = the cable only lists the phone; click Connect.
    @Published var autoConnectOnCable = UserDefaults.standard.object(forKey: "autoConnectOnCable") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoConnectOnCable, forKey: "autoConnectOnCable") }
    }

    /// Optional compact latency next to the menu bar icon. Off by default.
    @Published var showLatencyInMenuBar = UserDefaults.standard.bool(forKey: "showLatencyInMenuBar") {
        didSet {
            UserDefaults.standard.set(showLatencyInMenuBar, forKey: "showLatencyInMenuBar")
            refreshMenuBarReadout()
        }
    }
    /// "18 ms" (worst current latency across sessions), or "" with no reading.
    /// Only updated while the setting above is on, so it costs nothing when off.
    @Published var menuBarCompact = ""
    private var liveTimer: Timer?

    var running: Bool { !sessions.isEmpty }

    /// ~1 Hz: re-evaluates freshness (a phone that stops reporting goes back to
    /// "—"), updates the icon's hover tooltip and the optional compact label.
    func refreshMenuBarReadout() {
        let now = Date()
        var lines: [String] = []
        var worst: Double?
        for session in sessions {
            let fresh = session.liveIsFresh(at: now)
            lines.append("\(session.name): \(LiveStats.summary(session.live, fresh: fresh))")
            if fresh, let ms = session.live?.latencyMs { worst = max(worst ?? 0, ms) }
        }
        StatusItemTooltip.set(lines.isEmpty ? nil
            : "Duo Display\n" + lines.joined(separator: "\n")
              + "\nLatency: Mac capture → phone display, measured on the phone")
        let compact = (showLatencyInMenuBar && worst != nil) ? String(format: "%.0f ms", worst!) : ""
        if compact != menuBarCompact { menuBarCompact = compact }
    }

    @Published var discoveryGuidance: ConnectionGuidance?
    @Published var lastConnectionGuidance: ConnectionGuidance?

    func retryDiscovery() {
        browser?.cancel()
        discovered = []
        startBrowsing()
    }

    private var usbProbes: [String: UUID] = [:]
    private var usbProbeAttempted: Set<String> = []
    private var browser: NWBrowser?
    private var usbWatcher: UsbmuxDeviceWatcher?
    private var accessoryWatcher: AccessoryDeviceWatcher?

    // Connection policy — one session per physical device, and the cable
    // wins whenever it's available (lower, steadier latency than WiFi):
    //
    //  - USB devices connect on attach ("plug in and go") unless the user
    //    explicitly disconnected them once (usbDisabled).
    //  - Plugging the cable in while the device streams over WiFi migrates
    //    the live session onto USB; unplugging it fails over to WiFi when
    //    the device's service is visible — otherwise the session ends after
    //    the usual grace. Migrations swap only the socket (switchTransport):
    //    the virtual display survives, so no screen flash, no window
    //    reshuffle — the earlier no-switching policy existed because
    //    migration used to mean destroying and recreating the session.
    //  - WiFi devices the user connected before (wifiRemembered) reconnect
    //    in a short window at LAUNCH only — never mid-session.
    // `-autostart NO` disables all auto-connecting, including migrations.
    private var usbDisabled = Set(UserDefaults.standard.stringArray(forKey: "usbDisabled") ?? []) {
        didSet { UserDefaults.standard.set(Array(usbDisabled), forKey: "usbDisabled") }
    }
    private var wifiRemembered = Set(UserDefaults.standard.stringArray(forKey: "wifiRemembered") ?? []) {
        didSet { UserDefaults.standard.set(Array(wifiRemembered), forKey: "wifiRemembered") }
    }
    // Install id learned from each USB device's hello, persisted, so the
    // same hardware is recognized across transports even when the user
    // renamed the advertised service. @Published so the device list regroups
    // the moment an identity is learned.
    @Published private var installIDByUDID: [String: String] =
        UserDefaults.standard.dictionary(forKey: "installIDByUDID") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(installIDByUDID, forKey: "installIDByUDID") }
    }
    private let autoConnectEnabled = UserDefaults.standard.object(forKey: "autostart") == nil
        || UserDefaults.standard.bool(forKey: "autostart")

    // Bonjour usually reports devices before usbmuxd does — WiFi reconnects
    // wait out this window so a cabled device is dialed over USB first. The
    // deadline closes the window for good: a remembered WiFi device that
    // appears later was brought near the Mac mid-session, which is a user
    // action to confirm, not auto-grab.
    private var wifiAutoConnectArmed = false
    private let wifiAutoConnectDeadline = Date().addingTimeInterval(12)
    // Services whose Bonjour record is currently seen over the direct
    // host-to-host cable. Plugging that cable in is a deliberate act, so a
    // record newly gaining such an interface connects like a cabled iPhone
    // does; plain WiFi discovery never grabs a (possibly shared) receiver
    // after the launch window. Transition-based, so a record that stays on
    // the cable connects once, not on every browse update.
    private var onDirectCable: Set<String> = []
    // Service names the user disconnected while cabled. The record can
    // vanish and return without a replug (the receiver's display sleeps and
    // wakes, it restarts), and a cable-only receiver's unplug looks the
    // same, so the opt-out simply holds until the user connects by hand.
    // In memory: a relaunched sender starts fresh.
    private var cableOptOut: Set<String> = []
    // Accessory-mode devices whose receiver app quit (`closing`). Dialing one
    // opens the app again, so the next wired-list change must not redial it:
    // the opt-out holds until the device is unplugged or the user connects it.
    // In memory, like cableOptOut.
    private var receiverClosedOnCable: Set<String> = []
    // Every service seen on the cable this run: a Disconnect counts as a
    // cable opt-out even while the record is briefly gone (receiver asleep).
    private var everOnCable: Set<String> = []

    init() {
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMenuBarReadout() }
        }
        startBrowsing()
        usbWatcher = UsbmuxDeviceWatcher { [weak self] devices in
            self?.usbmuxDevices = devices
            self?.wiredDevicesChanged()
        }
        accessoryWatcher = AccessoryDeviceWatcher { [weak self] devices in
            self?.accessoryDevices = devices
            self?.wiredDevicesChanged()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.wifiAutoConnectArmed = true
            self.autoConnect()
        }
    }

    private func startBrowsing() {
        // TXT records carry the receiver's install id (new receivers).
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_opensidecar._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            DispatchQueue.main.async {
                guard let self, let browser, self.browser === browser else { return }
                self.discovered = Array(results)
                self.endSessionsWhoseServiceVanished()
                // A cable pulled before the device's Wi-Fi service was seen
                // fails over the moment it shows up (inside the grace).
                self.failoverIfCableGone()
                self.autoConnect()
                self.connectNewlyCabled()
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            Task { @MainActor in
                guard let self, let browser, self.browser === browser else { return }
                switch state {
                case .ready: self.discoveryGuidance = nil
                case .waiting(let error), .failed(let error):
                    self.discoveryGuidance = .discoveryError(error, on: .mac)
                default: break
                }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    // MARK: - Physical-device identity

    private func serviceName(of result: NWBrowser.Result) -> String? {
        if case .service(let name, _, _, _) = result.endpoint { return name }
        return nil
    }

    private func txtID(of result: NWBrowser.Result) -> String? {
        if case .bonjour(let txt) = result.metadata { return txt["id"] }
        return nil
    }

    /// Same hardware? Strong match: the service's install id equals the id
    /// this USB device announced in a (past or present) hello. Fallback for
    /// old receivers: lockdown device name equals the service name.
    private func sameDevice(_ result: NWBrowser.Result, _ device: UsbmuxDevice) -> Bool {
        if txtID(of: result) != nil || installIDByUDID[device.udid] != nil {
            return DeviceIdentity.matches(txtID(of: result), installIDByUDID[device.udid])
        }
        if let name = serviceName(of: result), let usbName = device.name,
           usbName == name { return true }
        return false
    }

    /// The session (over either transport) already serving this USB device.
    /// A failed session serves nothing — it must not block auto-connecting
    /// the same physical device over the other transport.
    private func activeSession(coveringUSB device: UsbmuxDevice) -> DeviceSession? {
        if let direct = session(for: "usb:\(device.udid)"), !direct.failed { return direct }
        return sessions.first { s in
            guard !s.failed, case .wifi(let result) = s.target else { return false }
            return DeviceIdentity.matches(installIDByUDID[device.udid], s.deviceID)
        }
    }

    /// The session (over either transport) already serving this WiFi service.
    /// Failed sessions are excluded for the same reason as above.
    private func activeSession(coveringWiFi result: NWBrowser.Result) -> DeviceSession? {
        if let name = serviceName(of: result), let direct = session(for: "wifi:\(name)"),
           !direct.failed {
            return direct
        }
        return sessions.first { s in
            guard !s.failed, case .usb(let udid) = s.target else { return false }
            if let id = txtID(of: result), s.deviceID == id { return true }
            if let udid, let device = usbDevices.first(where: { $0.udid == udid }),
               sameDevice(result, device) { return true }
            // Browse results routinely lack their TXT record and the USB
            // device is gone after a failover — the service name is then
            // the only remaining link to the session.
            let name = serviceName(of: result)
            return name != nil && (name == s.wifiServiceName || name == s.name)
        }
    }

    // MARK: - Connection policy

    private func autoConnect() {
        guard autoConnectEnabled else { return }
        dedupeSessions()
        // The -host/-port escape hatch is an explicit choice — dial it like
        // the wired devices (it joins them, not replaces them).
        if UserDefaults.standard.object(forKey: "host") != nil,
           !usbDisabled.contains("usb:first"), session(for: "usb:first") == nil {
            connect(to: .usb(udid: nil))
        }
        for device in usbDevices {
            // Not even a cable upgrade: the dial would reopen the app.
            guard !receiverClosedOnCable.contains(device.udid) else { continue }
            if installIDByUDID[device.udid] == nil,
               !usbDisabled.contains("usb:\(device.udid)"),
               sessions.contains(where: { !$0.failed && !$0.onUSB }),
               session(for: "usb:\(device.udid)") == nil {
                probeUSBIdentity(device)
                continue
            }
            if let covering = activeSession(coveringUSB: device) {
                // usbDisabled gates auto-connecting a device, not the
                // transport of a session the user deliberately has running —
                // however it was started, the cable is better: take it.
                upgradeToUSB(covering, device: device)
            } else if autoConnectOnCable,
                      !usbDisabled.contains("usb:\(device.udid)"), connectsOnAttach(device) {
                connect(to: .usb(udid: device.udid))
            }
        }
        guard wifiAutoConnectArmed, Date() < wifiAutoConnectDeadline else { return }
        for result in discovered {
            let target = ConnectionTarget.wifi(result)
            let id = txtID(of: result)
            let remembered = wifiRemembered.contains(target.sessionID)
            // One-time migration: a device the user connected over Wi-Fi
            // before per-device setup existed keeps reconnecting at launch.
            // An existing record (including a later Disconnect) always wins.
            if remembered, DeviceIdentity.valid(id) != nil, !DeviceSetupStore.hasRecord(id) {
                DeviceSetupStore.update(id) { $0.wirelessAllowed = true; $0.reconnectAtLaunch = true }
            }
            let setup = DeviceSetupStore.load(id)
            // Receivers without an install id cannot hold a record; they keep
            // the earlier remembered-by-service behavior.
            let wanted = DeviceIdentity.valid(id) == nil
                ? remembered
                : setup.reconnectAtLaunch && setup.wirelessAllowed
            if wanted,
               activeSession(coveringWiFi: result) == nil,
               !cabled(result) {
                connect(to: target)
            }
        }
    }

    /// An attached, auto-connectable USB device is (about to be) dialed over
    /// the cable — its WiFi service must not be grabbed in the launch race.
    private func cabled(_ result: NWBrowser.Result) -> Bool {
        usbDevices.contains {
            sameDevice(result, $0) && !usbDisabled.contains("usb:\($0.udid)") && connectsOnAttach($0)
        }
    }

    /// Dialing an Android device in accessory mode switches its USB mode and
    /// opens the receiver app on it, so plugging in only connects a device
    /// that streamed over the cable before (its install id is known).
    /// Anything else is any Android phone plugged in to charge: the first
    /// connect is a click in the device list.
    private func connectsOnAttach(_ device: UsbmuxDevice) -> Bool {
        guard AOA.serial(fromUDID: device.udid) != nil else { return true }
        return !receiverClosedOnCable.contains(device.udid) && installIDByUDID[device.udid] != nil
    }

    /// A Mac receiver just appeared on the direct cable: connect to it unless
    /// a session already covers it (a live WiFi session moves onto the cable
    /// through the sender's own upgrade probe instead).
    private func connectNewlyCabled() {
        let nowOnCable = Set(discovered.compactMap { result in
            result.interfaces.contains(where: DirectCable.isDirectLink) ? serviceName(of: result) : nil
        })
        let plugged = nowOnCable.subtracting(onDirectCable)
        onDirectCable = nowOnCable
        everOnCable.formUnion(nowOnCable)
        guard autoConnectEnabled, !plugged.isEmpty else { return }
        for result in discovered {
            guard let name = serviceName(of: result), plugged.contains(name),
                  !cableOptOut.contains(name),
                  activeSession(coveringWiFi: result) == nil,
                  !alreadyServedOnCable(result),
                  // A USB-attached phone belongs to the usbmux path and its
                  // own opt-out, never this one.
                  !usbDevices.contains(where: { sameDevice(result, $0) }) else { continue }
            Log.info("\(name) appeared on the direct cable — connecting")
            connect(to: .wifi(result))
        }
    }

    /// A live session may already talk to this receiver under another
    /// service name (renamed while streaming). Match the install id when the
    /// browse result carries TXT; it often does not, so also treat any live
    /// session already on the cable as covering it: a second cabled Mac
    /// receiver at the same time is rare, and a click still connects it.
    private func alreadyServedOnCable(_ result: NWBrowser.Result) -> Bool {
        let id = txtID(of: result)
        return sessions.contains { s in
            guard !s.failed else { return false }
            if let id, s.deviceID == id { return true }
            return s.wired && s.deviceKind == "Mac"
        }
    }

    private func wiredDevicesChanged() {
        let devices = usbmuxDevices + accessoryDevices
        let newlyAttached = Set(devices.map(\.udid)).subtracting(usbDevices.map(\.udid))
        let detached = Set(usbDevices.map(\.udid)).subtracting(devices.map(\.udid))
        usbDevices = devices
        for udid in detached {
            usbProbes.removeValue(forKey: udid)
            usbProbeAttempted.remove(udid)
        }
        receiverClosedOnCable.subtract(detached)
        // Duo Display: physically unplugging and replugging is a fresh "go".
        // A past Disconnect click opts an iPhone out of auto-connect until the
        // user clicks Connect; unplugging clears that, so plug-in-and-stream
        // keeps working after an earlier manual disconnect.
        if autoConnectOnCable {
            for udid in detached where AOA.serial(fromUDID: udid) == nil {
                usbDisabled.remove("usb:\(udid)")
            }
        }
        for session in sessions {
            if let udid = session.usbUDID, detached.contains(udid) || newlyAttached.contains(udid) {
                session.usbUpgradeSuppressed = false
                session.usbUnavailable = detached.contains(udid)
            }
        }
        failoverIfCableGone()
        autoConnect()
    }

    private func probeUSBIdentity(_ device: UsbmuxDevice) {
        guard AOA.serial(fromUDID: device.udid) == nil,
              !usbProbeAttempted.contains(device.udid), let port = UInt16(port) else { return }
        usbProbeAttempted.insert(device.udid)
        let token = UUID()
        usbProbes[device.udid] = token
        Task { [weak self] in
            do {
                let id = try await USBPeerProbe.installID(deviceID: device.deviceID, port: port)
                guard let self, self.usbProbes[device.udid] == token,
                      self.usbDevices.contains(where: { $0.udid == device.udid && $0.deviceID == device.deviceID }) else { return }
                self.usbProbes.removeValue(forKey: device.udid)
                self.installIDByUDID[device.udid] = id
                self.autoConnect()
            } catch {
                guard let self, self.usbProbes[device.udid] == token else { return }
                self.usbProbes.removeValue(forKey: device.udid)
                self.lastConnectionGuidance = ConnectionGuidance(
                    finding: "USB identity could not be confirmed for automatic switching.",
                    action: "Unlock the phone and open Duo Display. If you recognize it, choose Connect manually; this may restart its display. The existing session has not been moved.")
            }
        }
    }

    /// How to dial a cabled device: usbmuxd, or accessory mode for Android.
    private func wiredTransport(udid: String?, port: UInt16) -> SenderTransport {
        if let serial = udid.flatMap(AOA.serial(fromUDID:)) {
            return .accessory(serial: serial)
        }
        return .usb(udid: udid, port: port)
    }

    /// Cable plugged in while the device streams over WiFi: migrate the live
    /// session onto USB. No-op when the session is already cabled.
    private func upgradeToUSB(_ session: DeviceSession, device: UsbmuxDevice) {
        guard !session.onUSB, !session.usbUpgradeSuppressed, !session.usbUnavailable,
              let peerID = DeviceIdentity.valid(session.deviceID),
              DeviceIdentity.matches(peerID, installIDByUDID[device.udid]),
              let portNum = UInt16(port) else { return }
        Log.info("cable attached for \(session.id) — migrating to USB")
        session.beginTransportChange(TransportFailover.statusToUSB)
        session.onUSB = true
        session.usbUDID = device.udid
        // The match may have been by name only — pin the strong identity so
        // future matching (and the next launch) recognizes the pair.
        if let id = session.deviceID { installIDByUDID[device.udid] = id }
        session.sender.switchTransport(to: wiredTransport(udid: device.udid, port: portNum), expectedPeerID: peerID)
    }

    /// Cable unplugged under a live USB session: keep the pipeline (virtual
    /// display, capture, encoder) and redial the same device over its Wi-Fi
    /// (Bonjour) service. The phone dims its last frame and shows "Switching
    /// to Wi-Fi · wireless mode" meanwhile. With no visible service the session
    /// keeps its normal fate: it retries through the sender's 10 s grace, picks
    /// the service up if it appears in that window (browse updates call this
    /// again), and otherwise ends like any disconnect.
    ///
    /// A deliberate Disconnect never gets here: `disconnect` removes the
    /// session first, so there is nothing to fail over.
    private func failoverIfCableGone() {
        let attached = Set(usbDevices.map(\.udid))
        for session in sessions where !session.failed {
            let service = authorizedWiFiService(for: session)
            switch TransportFailover.decide(autoConnectEnabled: autoConnectEnabled,
                                            sessionOnUSB: session.onUSB,
                                            sessionUDID: session.usbUDID,
                                            attachedUDIDs: session.usbUnavailable
                                                ? attached.subtracting(session.usbUDID.map { [$0] } ?? []) : attached,
                                            wifiServiceVisible: service != nil) {
            case .none:
                session.waitingForWiFiLogged = false
            case .waitForWiFi:
                if !session.waitingForWiFiLogged {
                    session.beginTransportChange("USB unavailable — waiting briefly for an approved Wi-Fi route…")
                    session.waitingForWiFiLogged = true
                    Log.info("cable detached for \(session.id) — waiting for its Wi-Fi service")
                }
                session.guidance = .waitingForWiFi
            case .switchToWiFi:
                guard let service, let peerID = DeviceIdentity.valid(session.deviceID) else { continue }
                Log.info("cable detached for \(session.id) — failing over to WiFi")
                session.waitingForWiFiLogged = false
                session.beginTransportChange(TransportFailover.statusToWiFi)
                session.onUSB = false
                session.wifiServiceName = serviceName(of: service)
                session.sender.switchTransport(to: .tcp(service.endpoint), expectedPeerID: peerID)
            }
        }
    }

    /// A quit receiver app loses its Bonjour advertisement within ~1s, far
    /// faster than WiFi dial timeouts can notice (dials to a withdrawn
    /// service stall rather than getting refused). Report the withdrawal to
    /// each live WiFi session's sender; it only acts if its connection is
    /// already down too, which together proves the app is gone. Debounced
    /// 3s: an mDNS record can drop briefly during a WiFi roam — only a
    /// withdrawal that persists counts. One-shot, guarded re-check, so
    /// overlapping browse events at worst repeat an idempotent call.
    private func endSessionsWhoseServiceVanished() {
        for session in sessions where !session.onUSB {
            guard wifiService(for: session) == nil else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak session] in
                guard let self, let session,
                      self.sessions.contains(where: { $0 === session }),
                      self.wifiService(for: session) == nil else { return }
                session.sender.peerServiceWithdrawn()
            }
        }
    }

    /// The discovered WiFi service belonging to this session's device.
    private func wifiService(for session: DeviceSession) -> NWBrowser.Result? {
        discovered.first { result in
            if let id = txtID(of: result), let deviceID = session.deviceID {
                return id == deviceID
            }
            let name = serviceName(of: result)
            return name != nil && (name == session.wifiServiceName || name == session.name)
        }
    }

    private func authorizedWiFiService(for session: DeviceSession) -> NWBrowser.Result? {
        guard let index = AutomaticHandoff.wirelessIndex(
            expectedID: session.deviceID, advertisedIDs: discovered.map { txtID(of: $0) },
            allowed: session.wirelessHandoffAllowed) else { return nil }
        return discovered[index]
    }

    /// Safety net, not a feature: if identity was learned too late (old
    /// receiver, renamed service) and one physical device ended up with two
    /// sessions, the transports steal the receiver's single connection from
    /// each other forever. Keep the cable, drop the WiFi twin.
    private func dedupeSessions() {
        // Failed sessions hold no pipeline: a USB corpse must never win the
        // "keep the cable" rule against a working WiFi session.
        let usbSessionIDs = Set(sessions.compactMap { s -> String? in
            if case .usb = s.target, !s.failed { return s.deviceID }
            return nil
        })
        for s in sessions {
            guard case .wifi(let result) = s.target else { continue }
            let duplicate = (s.deviceID.map { usbSessionIDs.contains($0) } ?? false)
                || (txtID(of: result).map { usbSessionIDs.contains($0) } ?? false)

            if duplicate {
                Log.info("two sessions for one device — keeping the cable, dropping \(s.id)")
                end(s)
            }
        }
    }

    /// Human-readable device name for a target (no transport suffix — the
    /// UI shows transports separately).
    func label(for target: ConnectionTarget) -> String {
        switch target {
        case .usb(let udid):
            if let device = usbDevices.first(where: { $0.udid == udid }), let name = device.name {
                return name
            }
            if udid == nil { return "Manual (\(host):\(port))" }
            return udid.flatMap(AOA.serial(fromUDID:)) == nil ? "iPhone / iPad" : "Android device"
        case .wifi(let result):
            return serviceName(of: result) ?? "WiFi device"
        }
    }

    func session(for id: String) -> DeviceSession? {
        sessions.first { $0.id == id }
    }

    /// Derive a stable, per-device display serial from the session identity.
    /// FNV-1a over the id string; macOS keys saved display arrangement on
    /// vendor/product/serial, so each device keeps its screen position.
    private static func displaySerial(for id: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash == 0 ? 1 : hash
    }

    // A display identity macOS saved hostile state for (see
    // MacSender.setupExtend) is abandoned permanently: the validated offset
    // from the device's base identity is persisted per session id and every
    // future session starts from it.
    private static func identityOffsetKey(for id: String) -> String { "displaySerialBump.\(id)" }
    private func identityOffset(for id: String) -> UInt32 {
        UInt32(clamping: UserDefaults.standard.integer(forKey: Self.identityOffsetKey(for: id)))
    }

    func connect(to target: ConnectionTarget, userInitiated: Bool = false,
                 awaitingWake: Bool = false) {
        let id = target.sessionID
        if userInitiated, case .usb(let udid?) = target,
           installIDByUDID[udid] == nil,
           sessions.contains(where: { !$0.failed && !$0.onUSB && DeviceIdentity.valid($0.deviceID) == nil }) {
            lastConnectionGuidance = ConnectionGuidance(
                finding: "An older wireless receiver has no stable identity for a safe cable handoff.",
                action: "Disconnect the older wireless session first, then connect USB manually. Update the receiver to enable automatic handoff without recreating its display.")
            return
        }
        if let existing = session(for: id) {
            // A failed session holds no pipeline — replace the corpse
            // instead of letting it swallow the fresh attempt.
            guard existing.failed else { return }
            end(existing)
        }

        // Never create a second session for the same physical device — the
        // receiver holds one connection, so a twin would steal it. But an
        // explicit user click overrides: e.g. right after unplugging the
        // cable, the dying USB session sits in its 10s reconnect grace and
        // would otherwise swallow the tap on the WiFi row.
        let covering: DeviceSession?
        switch target {
        case .usb(let udid?):
            covering = usbDevices.first(where: { $0.udid == udid })
                .flatMap { activeSession(coveringUSB: $0) }
        case .wifi(let result):
            covering = activeSession(coveringWiFi: result)
        default:
            covering = nil
        }
        if let covering {
            guard userInitiated else { return }
            Log.info("user chose \(id) — taking over from \(covering.id)")
            end(covering)
        }

        // Connecting a device clears its "don't auto-connect" state.
        switch target {
        case .usb(let udid):
            usbDisabled.remove(id)
            if userInitiated, let udid { receiverClosedOnCable.remove(udid) }
        case .wifi(let result):
            wifiRemembered.insert(id)
            if userInitiated, let name = serviceName(of: result) { cableOptOut.remove(name) }
        }

        let transport: SenderTransport
        switch target {
        case .usb(let udid):
            guard let portNum = UInt16(port) else { return }
            if UserDefaults.standard.object(forKey: "host") != nil, udid == nil {
                // Manual override: dial a plain TCP endpoint instead of usbmuxd.
                transport = .tcp(.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: portNum)!))
            } else {
                transport = wiredTransport(udid: udid, port: portNum)
            }
        case .wifi(let result):
            transport = .tcp(result.endpoint)
        }

        let name = label(for: target)
        let expectedID: String?
        switch target {
        case .usb(let udid): expectedID = userInitiated ? nil : udid.flatMap { installIDByUDID[$0] }
        case .wifi(let result): expectedID = txtID(of: result)
        }
        let selectedQuality = DeviceSetupStore.quality(expectedID, fallback: quality)
        let sender = MacSender(transport: transport, name: name, mode: mode,
                               quality: selectedQuality, displaySerial: Self.displaySerial(for: id),
                               identityOffset: identityOffset(for: id),
                               awaitingWake: awaitingWake, expectedPeerID: expectedID)
        let session = DeviceSession(id: id, target: target, name: name, sender: sender)
        session.selectedQuality = selectedQuality
        lastConnectionGuidance = nil
        if case .wifi(let result) = target {
            session.wifiServiceName = serviceName(of: result)
        }
        sender.onStatus = { [weak session] text in
            // Retry loops re-announce the same status every second (e.g. the
            // asleep wait) — only a change is worth the UI churn and the log line.
            guard let session, session.status != text else { return }
            session.status = text
            Log.info("status[\(id)]: \(text)")
        }
        sender.onHello = { [weak self, weak session] info in
            guard let self, let session else { return }
            let firstHello = session.deviceID == nil
            session.deviceID = info.id
            session.deviceKind = info.device
            if firstHello, userInitiated, case .wifi = target {
                DeviceSetupStore.update(info.id) { $0.wirelessAllowed = true; $0.reconnectAtLaunch = true }
            }
            session.helloArrived(info)
            let power = (info.power ?? []).compactMap(PowerAction.init(rawValue:))
            if power != session.powerActions {
                Log.info("session \(session.id) power actions: "
                    + (power.isEmpty ? "none" : power.map(\.rawValue).joined(separator: ",")))
                session.powerActions = power
            }
            if case .usb(let udid?) = session.target, let installID = info.id {
                self.installIDByUDID[udid] = installID
            }
            self.dedupeSessions()
            // The learned identity may reveal that this WiFi session's device
            // is cabled — take the upgrade opportunity right away.
            self.autoConnect()
        }
        sender.onStats = { [weak session] frames, _ in
            session?.framesSent = frames
        }
        sender.onLiveStats = { [weak session] live in
            guard let session, !session.transportPending else { return }
            session.live = live
            session.liveAt = Date()
            session.performanceHealth.receive(live, at: Date())
        }
        sender.onDisconnected = { [weak self, weak session] in
            // Device unplugged / left the network and stayed gone: end this
            // session fully (virtual display + capture + indicator). No
            // transport fallback — reconnecting is the user's call.
            guard let self, let session else { return }
            Log.info("device disconnected — session \(session.id) stopped")
            self.lastConnectionGuidance = session.guidance ?? .disconnected
            self.end(session)
        }
        sender.onTransportReady = { [weak session] onUSB in
            guard let session, session.onUSB == onUSB else { return }
            if onUSB { session.usbUnavailable = false }
            session.transportPending = false
            session.guidance = nil
        }
        sender.onUSBUnavailable = { [weak self, weak session] in
            guard let self, let session, self.sessions.contains(where: { $0 === session }), session.onUSB else { return }
            session.usbUnavailable = true
            self.failoverIfCableGone()
        }
        sender.onIdentityMismatch = { [weak session] in
            session?.guidance = .identityMismatch
        }
        sender.onTransportUnavailable = { [weak self, weak session] in
            guard let self, let session,
                  self.sessions.contains(where: { $0 === session }), session.onUSB,
                  let service = self.authorizedWiFiService(for: session),
                  let peerID = DeviceIdentity.valid(session.deviceID) else { return }
            session.usbUpgradeSuppressed = true
            session.onUSB = false
            session.beginTransportChange("USB did not respond — returning to approved Wi-Fi…")
            session.sender.switchTransport(to: .tcp(service.endpoint), expectedPeerID: peerID)
        }
        sender.onPeerSleeping = { [weak self, weak session] in
            // The device locked. Unlike a plain disconnect this is a
            // known-temporary state announced by the receiver, so ending
            // the session (which frees the cursor from the now-invisible
            // display) is paired with a replacement session that dials
            // patiently until the device wakes and accepts again.
            guard let self, let session else { return }
            let target = session.target
            Log.info("session \(session.id) asleep — display down, waiting for wake")
            self.end(session)
            self.connect(to: target, awaitingWake: true)
        }
        sender.onCaptureStoppedByUser = { [weak self, weak session] in
            // The user stopped the capture in the system UI — same intent as
            // the in-app Disconnect, so it also opts the device out of
            // auto-connect (or the next browse event would resurrect it).
            guard let self, let session else { return }
            Log.info("session \(session.id) capture stopped via the system UI — honoring as disconnect")
            self.disconnect(session)
        }
        sender.onDisplayIdentityBumped = { [weak session] totalOffset in
            // The sender reports the validated absolute offset — store it
            // as-is. Adding would double-count when a rotation rebuild
            // re-discovers the same poisoned identity within one session.
            guard let session else { return }
            UserDefaults.standard.set(Int(totalOffset), forKey: Self.identityOffsetKey(for: session.id))
            Log.info("display identity for \(session.id) moved to offset \(totalOffset) — "
                + "macOS saved hostile state for the old one")
        }
        sender.onTransportPath = { [weak session] wired in
            session?.wired = wired
        }
        sender.onPeerClosed = { [weak self, weak session] in
            // The receiver app quit — a deliberate goodbye, so no reconnect
            // waits around. Reopening the app is a fresh start handled by
            // the normal discovery/auto-connect paths.
            guard let self, let session else { return }
            Log.info("session \(session.id) closed by the receiver — ending")
            if session.onUSB, let udid = session.usbUDID, AOA.serial(fromUDID: udid) != nil {
                self.receiverClosedOnCable.insert(udid)
            }
            self.end(session)
        }
        sessions.append(session)
        Task {
            do {
                try await sender.start()
            } catch is CancellationError {
                // stopped by the user while waiting — nothing to report
            } catch {
                Log.info("sender failed to start: \(error)")
                session.status = "Failed: \(error.localizedDescription)"
                // Free the half-built pipeline: a leaked virtual display
                // would keep holding this device's serial, and a parked
                // live-looking session would swallow every future connect.
                session.failed = true
                sender.stop()
            }
        }
    }

    /// User-initiated disconnect: also opt the device out of auto-connect.
    func disconnect(_ session: DeviceSession) {
        // An unconfirmed USB probe must never resurrect a session after Stop.
        for udid in usbProbes.keys { usbDisabled.insert("usb:\(udid)") }
        usbProbes.removeAll()
        DeviceSetupStore.update(session.deviceID) { $0.reconnectAtLaunch = false }
        switch session.target {
        case .usb: usbDisabled.insert(session.id)
        case .wifi:
            wifiRemembered.remove(session.id)
            if let name = session.wifiServiceName, everOnCable.contains(name) {
                cableOptOut.insert(name)
            }
        }
        // A migrated session is also reachable the other way — opt that side
        // out too, or auto-connect resurrects the device moments later.
        if session.onUSB, let udid = session.usbUDID { usbDisabled.insert("usb:\(udid)") }
        if let name = session.wifiServiceName { wifiRemembered.remove("wifi:\(name)") }
        end(session)
    }

    func disconnectAll() {
        sessions.forEach { disconnect($0) }
    }

    /// Restart a session that failed to start (its pipeline is already
    /// freed): tear the corpse out and dial the same target fresh. The
    /// socket-only Reconnect can't help there — nothing was ever built.
    func retry(_ session: DeviceSession) {
        let target = session.target
        end(session)
        connect(to: target, userInitiated: true)
    }

    private func end(_ session: DeviceSession) {
        session.sender.stop()
        sessions.removeAll { $0.id == session.id }
    }

    /// Mode/quality apply per-pipeline at construction — rebuild every session.
    func restartAll() {
        guard running else { return }
        let targets = sessions.map(\.target)
        sessions.forEach { $0.sender.stop() }
        sessions.removeAll()
        targets.forEach { connect(to: $0) }
        autoConnect()   // a rebuilt WiFi session may deserve its cable back
    }

    // MARK: - Device list (one row per physical device)

    struct DeviceEntry: Identifiable {
        let id: String
        let name: String
        let usbTarget: ConnectionTarget?
        let wifiTarget: ConnectionTarget?

        var transportLabel: String {
            switch (usbTarget != nil, wifiTarget != nil) {
            case (true, true): return "USB · WiFi"
            case (true, false): return "USB"
            case (false, true): return "WiFi"
            default: return ""
            }
        }
        /// Lowest latency first.
        var preferredTarget: ConnectionTarget? { usbTarget ?? wifiTarget }
    }

    var deviceEntries: [DeviceEntry] {
        var entries: [DeviceEntry] = []
        var mergedServices = Set<String>()
        var coveredSessionIDs = Set<String>()

        for device in usbDevices {
            // A discovered WiFi service for the same hardware folds into
            // this row instead of appearing as a second device.
            let twin = discovered.first { sameDevice($0, device) }
            if let twin, let name = serviceName(of: twin) { mergedServices.insert(name) }
            let usbTarget = ConnectionTarget.usb(udid: device.udid)
            coveredSessionIDs.insert(usbTarget.sessionID)
            if let twin { coveredSessionIDs.insert(ConnectionTarget.wifi(twin).sessionID) }
            // A WiFi-identity session migrated onto this cable serves the
            // device even when its service is no longer advertised.
            if let covering = activeSession(coveringUSB: device) {
                coveredSessionIDs.insert(covering.id)
            }
            entries.append(DeviceEntry(
                id: "device:\(device.udid)",
                name: device.name
                    ?? twin.flatMap(serviceName)
                    ?? session(for: usbTarget.sessionID)?.deviceKind
                    ?? label(for: usbTarget),
                usbTarget: usbTarget,
                wifiTarget: twin.map { .wifi($0) }))
        }
        if UserDefaults.standard.object(forKey: "host") != nil {
            let target = ConnectionTarget.usb(udid: nil)
            coveredSessionIDs.insert(target.sessionID)
            entries.append(DeviceEntry(id: target.sessionID, name: label(for: target),
                                       usbTarget: target, wifiTarget: nil))
        }
        for result in discovered {
            guard let name = serviceName(of: result), !mergedServices.contains(name)
            else { continue }
            let target = ConnectionTarget.wifi(result)
            coveredSessionIDs.insert(target.sessionID)
            // A USB-identity session that failed over to WiFi serves this
            // service — claim it, or it would dangle as a second row and
            // this one would offer a Connect that steals the receiver.
            if let covering = activeSession(coveringWiFi: result) {
                coveredSessionIDs.insert(covering.id)
            }
            entries.append(DeviceEntry(id: "service:\(name)", name: name,
                                       usbTarget: nil, wifiTarget: target))
        }
        // Sessions whose device vanished from discovery (e.g. Bonjour record
        // gone while the stream is still alive) keep a row to disconnect.
        for session in sessions where !coveredSessionIDs.contains(session.id) {
            entries.append(DeviceEntry(id: session.id, name: session.name,
                                       usbTarget: nil, wifiTarget: nil))
        }
        return entries
    }

    func session(for entry: DeviceEntry) -> DeviceSession? {
        if let target = entry.usbTarget {
            if let s = session(for: target.sessionID) { return s }
            if case .usb(let udid?) = target,
               let device = usbDevices.first(where: { $0.udid == udid }),
               let s = activeSession(coveringUSB: device) { return s }
        }
        if let target = entry.wifiTarget {
            if let s = session(for: target.sessionID) { return s }
            // Transport-migrated sessions keep their original identity — a
            // USB-identity session failed over to WiFi still owns this row.
            if case .wifi(let result) = target,
               let s = activeSession(coveringWiFi: result) { return s }
        }
        return session(for: entry.id)   // dangling-session rows
    }
}

/// Polls the permission states the app depends on so the UI can surface
/// exactly what's missing instead of failing silently.
@MainActor
final class PermissionMonitor: ObservableObject {
    @Published var screenRecording = false
    @Published var inputControl = false
    private var observations = Set<AnyCancellable>()
    private var lastDiagnostic: String?

    init() {
        refresh()
        Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observations)
    }

    func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess()
        inputControl = InputInjector.hasInputControlPermission
        let diagnostic = "screenCapture=\(screenRecording) eventPosting=\(inputControl) axClient=\(AXIsProcessTrusted())"
        if diagnostic != lastDiagnostic {
            Log.info("Permission check: \(diagnostic) bundle=\(Bundle.main.bundleIdentifier ?? "unknown") path=\(Bundle.main.bundlePath)")
            lastDiagnostic = diagnostic
        }
    }

    /// Request only on the user's Grant action, never while polling.
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        refresh()
    }

    func requestInputControl() {
        _ = InputInjector.requestInputControlPermission()
        refresh()
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ContentView: View {
    @ObservedObject var controller: SenderController
    @StateObject private var permissions = PermissionMonitor()
    // Retained for the future signed Duo Display update integration.
    let updater: SPUStandardUpdaterController?

    static let size = CGSize(width: 820, height: 640)
    @State private var page: DuoMacPage = .devices

    private var missingPermissions: Int {
        (permissions.screenRecording ? 0 : 1) + (permissions.inputControl ? 0 : 1)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(page.rawValue).font(.system(size: 25, weight: .bold))
                        Text(page.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if page == .devices {
                        Button(action: arrangeDisplays) {
                            Label("Arrange Displays…", systemImage: "rectangle.3.group")
                        }
                        .help("Open System Settings to position your extended displays.")
                    }
                }
                .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 20)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch page {
                        case .devices: devicesPage
                        case .picture: picturePage
                        case .app: appPage
                        case .permissions: permissionsPage
                        }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack(spacing: 12) {
                    DuoMacStatusPill(title: controller.running ? "Connected" : "Ready to connect",
                                     color: controller.running ? .green : .secondary)
                    Spacer()
                    Button("Logs") { Log.revealInFinder() }
                        .help("Reveal the Duo Display log files in Finder")
                    if let updater { CheckForUpdatesView(updater: updater) }
                    else { Link("Updates", destination: URL(string: "https://myduodisplay.com/download")!) }
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .controlSize(.small)
                .padding(.horizontal, 24).padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .toggleStyle(.switch)
        .accentColor(DuoMacTheme.accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
                Text("Duo Display").font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.top, 10)
            VStack(alignment: .leading, spacing: 8) {
                Text("Workspace").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                ForEach(DuoMacPage.allCases) { item in
                    Button { page = item } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol).frame(width: 18)
                            Text(item.rawValue)
                            Spacer(minLength: 0)
                            if item == .permissions && missingPermissions > 0 {
                                Text("\(missingPermissions)").font(.caption2.weight(.bold))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.orange.opacity(0.16)))
                            }
                        }
                        .font(.system(size: 13, weight: page == item ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 9)
                        .foregroundStyle(page == item ? DuoMacTheme.accent : Color.primary)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(page == item ? DuoMacTheme.accent.opacity(0.12) : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                }
            }
            Spacer()
            Button { page = .permissions } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Label(missingPermissions == 0 ? "Setup complete" : "Finish setup",
                          systemImage: missingPermissions == 0 ? "checkmark.shield" : "lock.shield")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(missingPermissions == 0 ? Color.secondary : Color.orange)
                    Text(missingPermissions == 0 ? "Ready for your devices" : "\(missingPermissions) permission\(missingPermissions == 1 ? "" : "s") needed")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .buttonStyle(.plain)
        }
        .padding(14).frame(width: 194).frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private func arrangeDisplays() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func connectionGuidance(_ guidance: ConnectionGuidance) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(guidance.finding, systemImage: "info.circle").font(.subheadline.weight(.medium))
            Text(guidance.action).font(.caption).foregroundStyle(.secondary)
            if guidance == .localNetworkDenied {
                Button("Open Local Network settings") { PermissionMonitor.openPrivacyPane("Privacy_LocalNetwork") }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.06)))
    }

    private var devicesPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            DuoWorkspaceOverview(connected: controller.running,
                                 extended: controller.mode == .extend)
            HStack {
                Text(controller.running ? "Your displays" : "Nearby devices").font(.headline)
                Text("\(controller.deviceEntries.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Label("USB & Wi-Fi", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let guidance = controller.discoveryGuidance ?? controller.lastConnectionGuidance {
                connectionGuidance(guidance)
            }
            if controller.deviceEntries.isEmpty {
                connectionGuidance(.noDevices)
                Button("Retry discovery") { controller.retryDiscovery() }
                VStack(spacing: 12) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 28, weight: .light)).foregroundStyle(DuoMacTheme.accent)
                    Text("Bring your next screen online").font(.headline)
                    Text("Open Duo Display on your iPhone, iPad or Mac.\nConnect a USB cable or join the same Wi-Fi network.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(28).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .textBackgroundColor)))
            }
            ForEach(controller.deviceEntries) { entry in
                VStack(alignment: .leading, spacing: 12) {
                    if let session = controller.session(for: entry) {
                        SessionRow(title: entry.name, session: session, controller: controller)
                    } else {
                        HStack(spacing: 14) {
                            Image(systemName: "display.2").font(.title2)
                                .foregroundStyle(DuoMacTheme.accent).frame(width: 40, height: 44)
                                .background(RoundedRectangle(cornerRadius: 10).fill(DuoMacTheme.accent.opacity(0.08)))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.name).font(.headline)
                                Label(entry.transportLabel, systemImage: entry.usbTarget == nil ? "wifi" : "cable.connector")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let target = entry.preferredTarget {
                                Button("Connect") { controller.connect(to: target, userInitiated: true) }
                                    .buttonStyle(.borderedProminent).controlSize(.large)
                            }
                        }
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06)))
            }
            if controller.running {
                HStack {
                    Text("Stream controls apply to every connected display.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Disconnect All") { controller.disconnectAll() }
                }
            }
        }
    }

    private var picturePage: some View {
        DuoMacCard("Picture & performance", symbol: "display") {
                Text("Display mode").font(.headline)
                Picker("Mode", selection: $controller.mode) {
                    Text("Extend").tag(CaptureMode.extend)
                    Text("Mirror").tag(CaptureMode.mirror)
                }
                .pickerStyle(.segmented)
                .onChange(of: controller.mode) { controller.restartAll() }
                Text(controller.mode == .extend ? "Add an independent desktop beside your Mac." : "Show the same desktop on both screens.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Divider().padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Quality", selection: $controller.quality) {
                        ForEach(StreamQuality.allCases, id: \.self) { q in
                            Text(q.label).tag(q)
                        }
                    }
                    .onChange(of: controller.quality) { controller.restartAll() }
                    Text(controller.quality.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Codec", selection: $controller.codecPreference) {
                        ForEach(CodecPreference.allCases, id: \.self) { c in
                            Text(c.label).tag(c)
                        }
                    }
                    .onChange(of: controller.codecPreference) { controller.restartAll() }
                    Text("Auto chooses HEVC when both devices support it. Choose H.264 or HEVC to compare compatibility and performance. Live latency and FPS appear beside each connected device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }


        }
    }

    private var appPage: some View {
        DuoMacCard("Make it yours", symbol: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Auto-connect when a cable is plugged in", isOn: $controller.autoConnectOnCable)
                    Text("Open Duo Display on the iPhone (it must be in the foreground; the Mac cannot launch it). Streaming starts as soon as the app is up. Unplugging and replugging also clears an earlier Disconnect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show latency next to the menu bar icon", isOn: $controller.showLatencyInMenuBar)
                    Text("Adds a small \"18 ms\" beside the icon while a device streams. Hovering the icon always shows latency and FPS for each device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Show app in", selection: $controller.presentation) {
                        ForEach(AppPresentation.allCases, id: \.self) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    if controller.presentation == .background {
                        Text("No menu bar or Dock icon — streaming keeps running. Open the Duo Display app again (Spotlight/Finder) to show this window.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }


        }
    }

    private var permissionsPage: some View {
        DuoMacCard("Allow the connection", symbol: "lock.shield") {
                    permissionRow(
                        "Screen Recording",
                        granted: permissions.screenRecording,
                        help: "Required to capture the display.",
                        anchor: "Privacy_ScreenCapture",
                        request: { permissions.requestScreenRecording() }
                    )
                    permissionRow(
                        InputInjector.permissionSettingsName,
                        granted: permissions.inputControl,
                        help: "Allows taps, drags and scrolling from your device. Enable Duo Display in Privacy & Security → \(InputInjector.permissionSettingsName).",
                        anchor: "Privacy_Accessibility",
                        request: { permissions.requestInputControl() }
                    )
                    // macOS offers no API to query Local Network access, so
                    // infer from discovery results and let the user check.
                    permissionRow(
                        "Local Network",
                        granted: !controller.discovered.isEmpty,
                        uncertain: controller.discovered.isEmpty,
                        help: "Required for WiFi mode. If no device appears in the Devices list, allow Duo Display under Privacy & Security → Local Network on this Mac AND on the device — and keep the Duo Display app open there.",
                        anchor: "Privacy_LocalNetwork"
                    )
            Button("Recheck permissions") { permissions.refresh() }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func permissionRow(_ title: String, granted: Bool, uncertain: Bool = false,
                               help: String, anchor: String,
                               request: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: uncertain ? "questionmark.circle.fill"
                            : granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(uncertain ? .orange : granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if uncertain || !granted {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if uncertain || !granted {
                if let request {
                    Button("Grant…") { request() }
                        .controlSize(.small)
                        .help("Ask macOS for this permission. If the system dialog was already dismissed once, this registers the app under \(title) in System Settings — flip the toggle there.")
                }
                Button("Open Settings") {
                    PermissionMonitor.openPrivacyPane(anchor)
                }
                .controlSize(.small)
            }
        }
    }
}

/// One connected device: live status, throughput, reconnect + disconnect.
@MainActor
struct SessionRow: View {
    let title: String
    @ObservedObject var session: DeviceSession
    let controller: SenderController
    @State private var confirmingShutdown = false
    @State private var choosingDisplaySize = false

    private var statusColor: Color {
        if session.status.hasPrefix("Extending") || session.status.hasPrefix("Mirroring")
            || session.status.hasPrefix("Connected") {
            return .green
        }
        if session.status.hasPrefix("Failed") || session.status.contains("stopped") {
            return .red
        }
        return .orange
    }

    private static func latencyColor(_ ms: Double?) -> Color {
        guard let ms else { return .secondary }
        return ms <= 30 ? .green : ms <= 60 ? .yellow : .orange
    }

    private static func fpsColor(_ fps: Int?) -> Color {
        guard let fps else { return .secondary }
        return fps >= 50 ? .green : fps >= 28 ? .yellow : .orange
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("\(session.transportLabel) · \(session.status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                // Live numbers measured on the phone, refreshed ~1 Hz while
                // the menu is open. "—" until the phone reports (or if it is
                // an older app that never does).
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let fresh = session.liveIsFresh(at: context.date)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Text(LiveStats.latencyText(session.live, fresh: fresh))
                                .foregroundStyle(fresh ? Self.latencyColor(session.live?.latencyMs) : .secondary)
                            Text("·").foregroundStyle(.secondary)
                            Text(LiveStats.fpsText(session.live, fresh: fresh))
                                .foregroundStyle(fresh ? Self.fpsColor(session.live?.fps) : .secondary)
                        }
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        if let guidance = session.guidance ?? (fresh && session.performanceHealth.elevated ? .slow : (!fresh ? .noMeasurements : nil)) {
                            Text(guidance.finding).font(.caption).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                            Text(guidance.action).font(.caption2).foregroundStyle(.secondary).lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(LiveStats.measurementLabel(session.live, fresh: fresh))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .help("Measured on the phone: latency is the time from the Mac capturing a frame to the phone showing it (needs the phone's clock sync with this Mac, so it can read a few ms off); fps is frames the phone actually received per second.")
                }
            }
            Spacer()
            // A live session recovers on its own (liveness watchdog, redial,
            // transport failover), so only a failed start gets a button.
            if session.failed {
                Button("Retry") { controller.retry(session) }
                    .controlSize(.small)
                    .help("Start this connection over")
            }
            if session.powerActions.contains(.shutdown) {
                Button {
                    confirmingShutdown = true
                } label: {
                    Image(systemName: "power")
                }
                .controlSize(.small)
                .help("Shut down \(title)")
                .confirmationDialog("Shut down \(title) now?", isPresented: $confirmingShutdown) {
                    Button("Shut Down", role: .destructive) { session.sender.requestPower(.shutdown) }
                } message: {
                    Text("Apps on it with unsaved changes can still stop the shutdown.")
                }
            }
            if !session.displaySizeOutcomes.isEmpty {
                Button {
                    choosingDisplaySize = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .controlSize(.small)
                .help("Display size of \(title)")
                .popover(isPresented: $choosingDisplaySize, arrowEdge: .bottom) {
                    DisplaySizePicker(session: session)
                }
            }
            Button("Disconnect") { controller.disconnect(session) }
                .controlSize(.small)
        }
    }
}

/// The per-device desktop size, macOS Displays style: each choice with the
/// exact desktop it gives underneath, and the stream when it is not 1:1.
@MainActor
struct DisplaySizePicker: View {
    @ObservedObject var session: DeviceSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Device setup").font(.headline)
            if DeviceIdentity.valid(session.deviceID) != nil {
                Picker("Quality for this device", selection: Binding(
                    get: { session.selectedQuality }, set: { session.setQuality($0) })) {
                    ForEach(StreamQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Allow Wi-Fi handoff", isOn: Binding(
                    get: { session.wirelessHandoffAllowed }, set: { session.allowWirelessHandoff($0) }))
                Text("Wi-Fi is not encrypted. Allow only on a trusted network. USB and Wi-Fi must report the same receiver identity.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 300)
                Text("Scaling and position are remembered. Rotation follows the receiver’s current orientation to keep video and touch aligned.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 300)
            }
            Text("Display size").font(.headline)
            Picker("Display size", selection: Binding(
                get: { session.displaySize },
                set: { session.setDisplaySize($0) })) {
                ForEach(session.displaySizeOutcomes, id: \.choice) { outcome in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(outcome.choice.title)
                        Text(caption(for: outcome))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(outcome.choice)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        .padding(14)
        .fixedSize()
        .onAppear { session.refreshDisplaySize() }
    }

    private func caption(for outcome: DisplaySizeOutcome) -> String {
        let sameAsDefault = outcome.choice != .default
            && outcome.desktop == session.displaySizeOutcomes.first(where: { $0.choice == .default })?.desktop
        return outcome.caption + (sameAsDefault ? " (same as Default)" : "")
    }
}

