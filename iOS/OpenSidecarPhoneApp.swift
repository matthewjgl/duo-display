import SwiftUI
import VideoToolbox
import AVFoundation
import UIKit
import Combine

/// "iPad" or "iPhone" — so UI copy names the device the user is holding.
let deviceKind = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"

/// The name this device announces to the Mac. iOS 16+ only shares the
/// user-assigned name (Settings > General > About > Name) with apps that hold
/// Apple's user-assigned-device-name entitlement; without it
/// `UIDevice.current.name` is just the model. That is detected, never assumed:
/// a generic name is announced as such and the Mac uses its own sources (the
/// cable's lockdown name, or a name set on the Mac).
enum PhoneName {
    /// The name typed into this app's settings ("" = automatic).
    static var appName: String { UserDefaults.standard.string(forKey: "deviceName") ?? "" }

    static func current(appName: String = PhoneName.appName) -> (name: String, source: DeviceNameSource) {
        DeviceNameAnnouncement.choose(appName: appName, systemName: UIDevice.current.name,
                                      model: UIDevice.current.model)
    }

    /// The system name, when iOS shares a personalized one with this app.
    static var personalizedSystemName: String? {
        let name = DeviceNameText.clean(UIDevice.current.name)
        return DeviceNameText.isGeneric(name, kind: UIDevice.current.model) ? nil : name
    }
}

/// Landing page — hosts the Mac app download and explains the two-app setup.
let macAppURL = URL(string: "https://myduodisplay.com/download")!

@main
struct DuoDisplayPhoneApp: App {
    @UIApplicationDelegateAdaptor(DuoPhoneAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let scene = UserDefaults.standard.string(forKey:"DuoUIPreviewScene") {
                PhoneUIPreviewHost(scene:scene)
            } else { ReceiverScreen() }
            #else
            ReceiverScreen()
            #endif
        }
    }
}

// MARK: - Shake to open settings

extension Notification.Name {
    static let deviceDidShake = Notification.Name("deviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}

// MARK: - Root screen

struct ReceiverScreen: View {
    @StateObject private var model = ReceiverModel()
    @AppStorage(ReceiverOrientation.defaultsKey) private var savedOrientation = ReceiverOrientation.automatic.rawValue
    @StateObject private var versionGate = VersionGate()
    @State private var showSettings = false
    @State private var openKeyboardAfterSettings = false
    @ObservedObject private var pairingApproval = PairingApprovalCoordinator.shared
    @State private var showPairingApproval = false
    @AppStorage(PhoneInputMode.defaultsKey) private var inputMode = PhoneInputMode.touch.rawValue
    @State private var showOnboarding = false
    @State private var nagDismissed = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("showAnalytics") private var showAnalytics = false
    @AppStorage("showLatencyHUD") private var showLatencyHUD = false
    @AppStorage("metalRenderer") private var metalRenderer = StreamReceiver.metalRendererDefault
    @AppStorage(MetalVideoRenderer.drawableCountKey) private var metalDrawables = 2
    // First-run onboarding (issue #49): explain the Mac app is required.
    // Shown until either the user dismisses it or the device connects once.
    @AppStorage("hasConnectedBefore") private var hasConnectedBefore = false
    @AppStorage("onboardingDismissed") private var onboardingDismissed = false

    // Streaming = connected and the video format is known. A USB <-> Wi-Fi
    // switch in progress counts too: the video view (and its last frame)
    // stays up under the "Switching to …" dim instead of dropping to the
    // idle screen while the new link comes up.
    private var isStreaming: Bool {
        guard model.receiver.videoSize != .zero else { return false }
        return model.receiver.connected || model.receiver.transportSwitch != nil
    }

    // Below the force floor → present the blocking gate (issue #135). The
    // fullScreenCover binding's setter is a no-op so the user can't dismiss it.
    private var requiredUpdate: VersionGate.Update? {
        if case let .required(update) = versionGate.status { return update }
        return nil
    }

    // Soft nag: shown once per launch, dismissible.
    private var recommendedUpdate: VersionGate.Update? {
        if case let .recommended(update) = versionGate.status, !nagDismissed { return update }
        return nil
    }

    var body: some View {
        AdaptiveNavigation {
            receiverContent
                .onAppear { model.receiver.inputFeedback = { feedback in DispatchQueue.main.async { PhoneHaptics.emit(feedback) } } }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showSettings = true } label: {
                            Label("Settings & help", systemImage: "slider.horizontal.3")
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityHint("Adjust your display, video and touch settings")
                    }
                }
                .navigationTitle(isStreaming ? "" : "SideExtend")
                .navigationBarTitleDisplayMode(.inline)
                .duoStreamingChrome(isStreaming, showSettings: $showSettings)
        }
    }

    private var receiverContent: some View {
        // Kept for its layout (fill the window, top-leading); the panel size
        // comes from WindowObserver below, not from the proxy.
        GeometryReader { _ in
            ZStack {
                if isStreaming {
                    Color.black.ignoresSafeArea()
                    VideoLayerView(displayLayer: model.receiver.displayLayer,
                                   receiver: model.receiver,
                                   useMetal: metalRenderer,
                                   inputMode: model.receiver.macSupportsTrackpad ? (PhoneInputMode(rawValue: inputMode) ?? .touch) : .touch,
                                   inputEnabled: scenePhase == .active && !showSettings && !showPairingApproval && !model.receiver.link.phase.isInTransition)
                        .id("\(metalRenderer)-\(metalDrawables)")   // rebuild the layer tree on toggle
                        .ignoresSafeArea(.container)
                    // Optional latency + FPS HUD, bottom-right corner. OFF by
                    // default: the live numbers now live in the Mac app's menu
                    // bar (the phone reports them over the control channel), so
                    // the phone screen stays clean. Settings → Latency turns this
                    // on for debugging; tap the HUD to hide it again. No gauge
                    // button and no gesture: nothing is drawn while it is off.
                    if showLatencyHUD && !showAnalytics {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            LatencyHUD(live: model.receiver.live,
                                       phase: model.receiver.link.phase,
                                       codec: model.receiver.perf.codec)
                                .onTapGesture { showLatencyHUD = false }
                                .accessibilityHint("Tap to hide.")
                        }
                        .padding(.trailing, 14)
                        .padding(.bottom, 14)
                    }
                    }
                    // Sidecar-style mode transition: the last frame, dimmed (not
                    // hidden), with a centered label while the link changes.
                    // The words are the centered notice below, shared with
                    // the idle screen; this layer only dims.
                    ZStack {
                        if model.receiver.link.phase.isInTransition {
                            TransportSwitchOverlay()
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: model.receiver.link.phase.isInTransition)
                    .allowsHitTesting(false)
                    if showAnalytics {
                        VStack {
                            Spacer()
                            PerfOverlay(stats: model.receiver.perf,
                                        videoSize: model.receiver.videoSize,
                                        phase: model.receiver.link.phase)
                                .padding(.bottom, 10)
                        }
                        .allowsHitTesting(false)   // never block touch input
                    }
                    RemoteKeyboardControls(receiver:model.receiver)
                    #if DEBUG
                    Color.clear.allowsHitTesting(false).onAppear {
                        if UserDefaults.standard.bool(forKey:"DuoUIPreviewKeyboardZoom") {
                            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { model.receiver.showPhoneKeyboard() }
                        }
                    }
                    #endif
                    #if DEBUG
                    if UserDefaults.standard.bool(forKey:"DuoUIPreviewConnected") {
                        Text("UI preview · no live Mac").font(.caption).foregroundStyle(.white.opacity(0.7)).allowsHitTesting(false)
                    }
                    #endif
                } else {
                    IdleView(receiver: model.receiver, showSettings: $showSettings)
                }
                // Brief, centered transport notice. Shown whatever the stats
                // setting; never takes touches.
                ConnectionNoticeView(notice: model.receiver.link.notice)
            }
            // The window, not this view: a sheet, the keyboard or the
            // hidden status bar change the view's frame but not the panel.
            .background(WindowObserver { model.updatePanel(window: $0) })
            .sheet(isPresented: $showOnboarding,onDismiss:{
                if pairingApproval.prompt != nil { showPairingApproval = true }
            }) {
                OnboardingView { onboardingDismissed = true }
            }
        }
        .ignoresSafeArea(.container, edges: isStreaming ? .all : [])
        .statusBarHidden(isStreaming)
        .systemOverlaysHidden(isStreaming)
        .fullScreenCover(isPresented: $showSettings, onDismiss: {
            if pairingApproval.prompt != nil { openKeyboardAfterSettings = false;showPairingApproval = true;return }
            guard openKeyboardAfterSettings else { return }
            openKeyboardAfterSettings = false
            guard model.receiver.connected, model.receiver.macSupportsKeyboard else { return }
            // Wait for actual sheet dismissal, not a fixed delay. The editor
            // can become first responder without competing with the sheet.
            model.receiver.showPhoneKeyboard()
        }) {
            SettingsView(receiver: model.receiver, openKeyboard: {
                openKeyboardAfterSettings = true
                showSettings = false
            })
        }
        .sheet(isPresented:$showPairingApproval,onDismiss:{
            if pairingApproval.prompt != nil { pairingApproval.cancel() }
        }) { PhonePairingSheet(pairing:pairingApproval) }
        .onChange(of:pairingApproval.prompt?.id) { id in
            guard id != nil else { showPairingApproval = false;return }
            model.receiver.hidePhoneKeyboard();model.receiver.resetInputs()
            if showSettings { showSettings = false }
            else if showOnboarding { showOnboarding = false }
            else { showPairingApproval = true }
        }
        // Below the force floor → blocking gate. Setter is a no-op: the user
        // cannot dismiss it, only update.
        .fullScreenCover(item: Binding(get: { requiredUpdate }, set: { _ in })) { update in
            UpdateRequiredView(update: update)
        }
        // At/above the floor but behind the recommended version → soft nag.
        .alert("Update available",
               isPresented: Binding(get: { recommendedUpdate != nil },
                                    set: { if !$0 { nagDismissed = true } })) {
            Button("Update") {
                if let update = recommendedUpdate { UIApplication.shared.open(update.url) }
            }
            Button("Later", role: .cancel) { nagDismissed = true }
        } message: {
            if let update = recommendedUpdate { Text(update.message) }
        }
        .task {
            if ReceiverOrientation.load() != .automatic { ReceiverOrientationController.shared.apply() }
            await versionGate.check()
        }
        .onChange(of: savedOrientation) { _ in ReceiverOrientationController.shared.apply() }
        // Merge the connected Mac's compatibility signal into the same gate.
        .onReceive(model.receiver.$peerSignal) { versionGate.applyPeer($0) }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
            showSettings = true
        }
        .onChange(of: showSettings) { shown in
            if shown && pairingApproval.prompt != nil { showSettings = false;return }
            if shown { model.receiver.hidePhoneKeyboard(); model.receiver.resetInputs() }
        }
        .onChange(of: scenePhase) { phase in
            Log.info("scenePhase -> \(String(describing: phase))")
            switch phase {
            case .active:
                model.sceneDidActivate()
                // The user may have renamed the device in Settings meanwhile.
                model.refreshAnnouncedName()
                PairingDiscovery.shared.recover()
                TrustedConnections.shared.browse(receiver: model.receiver)
                TrustedConnections.shared.recoverAfterEnvironmentChange()
            case .background: model.receiver.hidePhoneKeyboard(); model.receiver.resetInputs(); model.sceneDidBackground()
            case .inactive: model.receiver.hidePhoneKeyboard(); model.receiver.resetInputs()
            @unknown default: break
            }
        }
        // The deliberate "screen off" signal: locking the device makes
        // protected data unavailable (a plain app switch doesn't). This is
        // what separates "put the iPhone to sleep — end the session now"
        // from "peeked at a message — keep the session alive".
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            Log.info("protected data will become unavailable (device locking)")
            model.deviceWillLock()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            Log.info("protected data available again (device unlocked)")
            model.deviceDidUnlock()
        }
        // Swiping the app away in the switcher (while we're still running)
        // grants a ~5s notice — enough for a clean goodbye so the Mac ends
        // the session at once. A kill without notice is covered Mac-side:
        // dead apps stop accepting redials, so the silence grace fires.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willTerminateNotification)) { _ in
            model.appWillTerminate()
        }
        .onChange(of: model.receiver.connected) { isConnected in
            // The first valid connection retires the onboarding hint for good.
            if isConnected {
                hasConnectedBefore = true
                showOnboarding = false
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.start()
            // Show the first-run hint unless the device has connected before
            // or the user already dismissed it.
            if !hasConnectedBefore && !onboardingDismissed {
                showOnboarding = true
            }
        }
    }
}

// MARK: - Transport switch overlay

/// "Switching to Wi-Fi · wireless mode" / "Switching to USB mode": the stream's
/// last frame stays visible underneath, dimmed to about 40% black.
struct TransportSwitchOverlay: View {
    /// How much black goes over the last frame (0.35 to 0.45 reads as
    /// "still there, paused", not "gone").
    static let dim = 0.4

    var body: some View {
        Color.black.opacity(Self.dim).ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// Sidecar-style status feedback: one small centered capsule that morphs in
/// place (never stacks) and fades. VoiceOver hears each new notice once.
struct ConnectionNoticeView: View {
    let notice: TransitionNotice?

    var body: some View {
        ZStack {
            if let notice {
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        if notice.kind == .progress {
                            ProgressView().progressViewStyle(.circular).tint(.white)
                        }
                        Image(systemName: notice.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(notice.kind == .failure ? .orange : .white)
                        Text(notice.title)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    if let detail = notice.detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: 360)
                // Opaque enough to read over the idle screen's cards as well
                // as over video; the hairline separates it from dark UI.
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(white: 0.09))
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 6))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                .padding(24)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(notice.accessibilityLabel)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: notice)
        .allowsHitTesting(false)
        .onChange(of: notice) { notice in
            guard let notice else { return }
            UIAccessibility.post(notification: .announcement, argument: notice.accessibilityLabel)
        }
    }
}

// MARK: - Idle view (no Mac connected) — regular iOS look, follows light/dark

struct IdleView: View {
    @ObservedObject var receiver: StreamReceiver
    @Binding var showSettings: Bool
    @ObservedObject private var pairingDiscovery = PairingDiscovery.shared
    @ObservedObject private var trusted = TrustedConnections.shared
    @AppStorage("deviceName") private var deviceName = ""
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var selectedOption:String?
    private var previewScene:String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey:"DuoUIPreviewHome")
        #else
        return nil
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            let columns = PhoneLayoutPolicy.columns(width:geometry.size.width,height:geometry.size.height,accessibility:textSize.isAccessibilitySize)
            ScrollView {
                Group {
                    if columns == 2 {
                        HStack(alignment:.top,spacing:28) {
                            welcome(compact:true).frame(width:240)
                            pairing.frame(maxWidth:.infinity)
                        }
                    } else {
                        VStack(alignment:.leading,spacing:28) { welcome(compact:false);pairing }
                    }
                }.padding(24).frame(maxWidth:980).frame(maxWidth:.infinity,alignment:.leading)
            }
        }.background(Color(.systemGroupedBackground)).tint(DuoPhoneTheme.accent)
    }
    private func welcome(compact:Bool) -> some View {
        PhoneWorkspaceHeader(name:PhoneName.current(appName:deviceName).name,
            title:receiver.connected ? "Starting your display" : "Choose your Mac",
            detail:receiver.connected ? "Keep SideExtend open while your Mac gets ready." : "Open SideExtend on your Mac. Use the same Wi-Fi or a USB cable.",compact:compact,deviceKind:deviceKind)
    }
    private var pairing:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text("Available Macs").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action:refreshMacs) { Image(systemName:"arrow.clockwise").frame(width:44,height:44) }
                    .accessibilityLabel("Refresh Macs").disabled(connectionBusy)
            }
            if connectionBusy {
                HStack(spacing:10) {
                    ProgressView()
                    Text(pairingDiscovery.isPairing ? "Waiting for pairing approval" : "Connecting to your Mac…")
                        .font(.subheadline).fixedSize(horizontal:false,vertical:true)
                    Spacer()
                    Button("Cancel") { if pairingDiscovery.isPairing { pairingDiscovery.cancelPairing() } else { trusted.cancel() } }
                        .frame(minHeight:44)
                }.accessibilityElement(children:.contain)
            }
            ForEach(Array(connectionOptions.enumerated()),id:\.element.id) { index,option in
                if index > 0 { Divider() }
                PhoneMacChoiceRow(name:option.name,detail:option.detail,
                    actionTitle:connectionBusy && selectedOption == option.id ? "Connecting…" : option.action.isPairingAction ? "Connect" : option.title,
                    enabled:option.enabled(busy:connectionBusy,connected:receiver.connected),
                    busy:connectionBusy && selectedOption == option.id) { performPrimaryAction(option) }
            }
            if connectionOptions.isEmpty {
                VStack(alignment:.leading,spacing:10) {
                    Label("Looking for Macs",systemImage:"wifi").font(.headline)
                    Text("Keep your Mac awake with SideExtend open.").font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,12)
            }
            if let failure = connectionFailure {
                Label(PhoneErrorCopy.summary(failure),systemImage:"exclamationmark.circle").font(.subheadline).foregroundStyle(.orange)
                Button("Try again",action:refreshMacs).frame(minHeight:44)
            } else if let actionMessage, !connectionBusy {
                Text(actionMessage).font(.footnote).foregroundStyle(.secondary)
            }
            Divider()
            DisclosureGroup("Connection help") {
                VStack(alignment:.leading,spacing:12) {
                    Text("Wi-Fi: keep both apps open on the same local network. Approve matching codes once on both devices for a new pair.")
                    Text("USB: connect your \(deviceKind) with a data cable.")
                    if let guidance = receiver.networkGuidance { Text(guidance.action) }
                }.font(.subheadline).padding(.top,8)
            }.frame(minHeight:44)
            DisclosureGroup("Diagnostics") { PhoneDiagnosticsContent(receiver:receiver) }
                .frame(minHeight:44)
        }.padding(20).background(Color(.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:18))
        .onChange(of:connectionBusy) { busy in if !busy { actionMessage = nil;selectedOption = nil } }
        .onChange(of:connectionOptions) { _ in if !connectionBusy { actionMessage = nil } }
        .onAppear { if previewScene == nil { trusted.browse(receiver:receiver);pairingDiscovery.browse() } }
    }

    @State private var actionMessage: String?
    private var connectionBusy: Bool {
        #if DEBUG
        if previewScene == "connecting" { return true }
        #endif
        return pairingDiscovery.isPairing || trusted.connecting || trusted.awaitingPairedMac != nil
    }
    private var connectionOptions: [MacConnectionOption] {
        #if DEBUG
        if let scene = previewScene {
            if scene == "empty" { return [] }
            return [.init(id:"fixture-mac",name:scene == "long-name" ? "Matthew’s studio MacBook Pro with a very long device name" : "Matthew’s MacBook Pro",detail:scene == "connecting" ? "Connecting…" : "Ready to connect",action:.connect("fixture-mac"))]
        }
        #endif
        return MacConnectionOption.make(remembered:trusted.rememberedPeers,
            available:Set(trusted.rememberedPeers.filter { trusted.result(for:$0.id) != nil }.map(\.id)),
            nearby:pairingDiscovery.macs.compactMap { result in
                guard case .service(let name,_,_,_) = result.endpoint else { return nil }
                return .init(token:String(describing:result.endpoint),name:name)
            }, connected:receiver.connected)
    }
    private func performPrimaryAction(_ option: MacConnectionOption) {
        guard previewScene == nil else { return } // Offline native UI fixture.
        guard !connectionBusy, !receiver.connected else { return }
        selectedOption = option.id
        actionMessage = nil; trusted.clearFailure(); pairingDiscovery.clearFailure()
        // Resolve again at tap time: a rendered row can outlive its discovery result.
        guard let fresh = connectionOptions.first(where: { $0.id == option.id }), fresh.action == option.action else {
            actionMessage = "Discovery changed. Select the refreshed Mac to continue."; refreshMacs(); return
        }
        switch fresh.action {
        case .connect(let peer):
            actionMessage = "Connecting…"
            if !trusted.connectPeer(peer) { actionMessage = nil }
        case .pair(let token):
            guard let mac = pairingDiscovery.macs.first(where: { String(describing:$0.endpoint) == token }) else {
                actionMessage = "Mac is no longer nearby. Refresh and try again."; return
            }
            actionMessage = "Pairing…"
            if !pairingDiscovery.pair(with:mac,name:PhoneName.current().name,onPaired:{ peer in
                trusted.connectAfterPairing(peer,receiver:receiver)
            }) { actionMessage = nil }
        case .search:
            actionMessage = "Searching again. Keep both apps open on the same Wi-Fi."; refreshMacs()
        case .none: break
        }
    }
    private func refreshMacs() {
        guard previewScene == nil else { return }
        pairingDiscovery.clearFailure(); trusted.clearFailure()
        pairingDiscovery.browse(); trusted.retryBrowse(receiver: receiver); receiver.retryDiscovery()
    }
    private var connectionFailure: String? {
        #if DEBUG
        if previewScene == "error" { return "Connection timed out" }
        #endif
        return trusted.lastFailure ?? pairingDiscovery.lastFailure ?? pairingDiscovery.discoveryFailure ?? trusted.discoveryFailure
    }
}

private enum DuoPhoneTheme {
    static let accent = Color(uiColor: .systemBlue)
}
private extension MacConnectionAction {
    var isPairingAction:Bool { if case .pair = self { return true };return false }
}

private struct DuoConnectionOption: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3.weight(.medium))
                .foregroundStyle(.blue).frame(width: 28, height: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DuoSettingsCard<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            content
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }
}

/// One hint line: the symbol centered in a fixed-width column, so every
/// row's text starts at the same edge whatever the symbol's width, and the
/// text wraps instead of truncating.
struct HintRow: View {
    let text: String
    let systemImage: String
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 24

    init(_ text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: iconWidth)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - First-run onboarding (the Mac app is required to connect)

/// Shown on first launch / while the device has never connected: SideExtend
/// is two apps, and the iOS side is useless without the Mac app running.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    let onClose: () -> Void
    private func finish() { onClose();dismiss() }
    private var introduction:some View {
        VStack(alignment:.leading,spacing:14) {
            Image(systemName:"laptopcomputer.and.iphone").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
            Text("A little more room.").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text("Use your \(deviceKind) as a second display for your Mac.").foregroundStyle(.secondary)
        }.fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
    }
    private var steps:some View {
        VStack(alignment:.leading,spacing:24) {
            VStack(alignment:.leading,spacing:18) {
                HintRow("Open SideExtend on your Mac.",systemImage:"1.circle")
                HintRow("Join the same Wi-Fi, or use a USB data cable.",systemImage:"2.circle")
                HintRow("Choose your Mac. For a new pair, approve matching codes on both devices.",systemImage:"3.circle")
            }
            Button(action:finish) { Text("Find my Mac").font(.headline).frame(maxWidth:.infinity,minHeight:44) }.buttonStyle(.borderedProminent)
            Link(destination:macAppURL) { Label("Need the Mac app?",systemImage:"arrow.down.circle").frame(minHeight:44) }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    var body:some View {
        AdaptiveNavigation {
            GeometryReader { geometry in
                ScrollView {
                    Group {
                        if PhoneLayoutPolicy.columns(width:geometry.size.width,height:geometry.size.height,accessibility:textSize.isAccessibilitySize) == 2 {
                            HStack(alignment:.top,spacing:32) { introduction;steps }
                        } else { VStack(alignment:.leading,spacing:32) { introduction;steps } }
                    }.padding(24).frame(maxWidth:860).frame(maxWidth:.infinity,alignment:.leading)
                }
            }.navigationTitle("Welcome to SideExtend").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Close",action:finish) } }
        }
    }
}

// MARK: - Settings / help sheet

struct SettingsView: View {
    @ObservedObject private var trusted = TrustedConnections.shared
    @ObservedObject var receiver: StreamReceiver
    var openKeyboard: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showAnalytics") private var showAnalytics = false
    @AppStorage("showLatencyHUD") private var showLatencyHUD = false
    @AppStorage(TouchRipple.defaultsKey) private var touchRipple = true
    @AppStorage(PhoneInputMode.defaultsKey) private var inputMode = PhoneInputMode.touch.rawValue
    @AppStorage(PhoneHapticLevel.defaultsKey) private var hapticLevel = PhoneHapticLevel.standard.rawValue

    // Preserve existing preferences, but expose one mutually exclusive choice.
    private var statsMode: Binding<Int> {
        Binding(get: { showAnalytics ? 2 : (showLatencyHUD ? 1 : 0) }, set: { mode in
            showAnalytics = mode == 2
            showLatencyHUD = mode == 1
        })
    }
    private var statsDescription: String {
        if showAnalytics {
            return "A detailed diagnostic panel with latency, FPS, bitrate, frame timing and graphs. Useful for troubleshooting."
        }
        if showLatencyHUD {
            return "A small corner readout of latency and FPS, with a trend graph. Tap the readout to hide it."
        }
        return "Keep your second screen clear. Latency and FPS are still available in the Mac app’s menu bar."
    }
    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "local"
        return "\(version) (\(build))"
    }

    @State private var confirmingDisconnect = false
    @State private var disconnecting = false
    @FocusState private var editingDeviceName:Bool
    var body:some View {
        AdaptiveNavigation {
            // One native scrolling surface in every size class. Two Forms
            // side by side created independently sized/scrolling panels.
            Form { sessionSection;inputSection;keyboardSection;displaySection;helpSection }
            .navigationTitle(receiver.connected ? "Session controls" : "Settings")
            .navigationBarTitleDisplayMode(.inline).tint(DuoPhoneTheme.accent)
            .modifier(PhoneSettingsChrome())
            .modifier(SessionSideRail(done:{dismiss()},disconnect:{confirmingDisconnect = true},canDisconnect:!editingDeviceName && (receiver.connected || receiver.link.phase.isInTransition),disconnecting:disconnecting))
            .toolbar {
                ToolbarItemGroup(placement:.keyboard) {
                    Spacer()
                    Button("Hide keyboard") { editingDeviceName = false }
                }
            }
            .confirmationDialog("Disconnect from your Mac?",isPresented:$confirmingDisconnect,titleVisibility:.visible) {
                Button("Disconnect",role:.destructive) {
                    disconnecting = true
                    receiver.disconnectForUser { disconnecting = false;dismiss() }
                }
                Button("Keep connected",role:.cancel) {}
            } message: { Text("Your paired Macs and preferences will stay saved.") }
            .onAppear { if showAnalytics && showLatencyHUD { showLatencyHUD = false } }
        }.statusBarHidden(false)
    }
    private var sessionSection:some View {
        Section {
            if receiver.connected,let scope = receiver.gestureProfileID,
               let peer = trusted.rememberedPeers.first(where:{scope.split(separator:":").map(String.init).contains($0.id)}) {
                Text(peer.name).font(.headline).fixedSize(horizontal:false,vertical:true)
            }
            VStack(alignment:.leading,spacing:5) {
                Label(receiver.connected ? receiver.link.phase.settingsTitle : "Not connected",systemImage:receiver.link.phase.settingsSymbol).font(.headline)
                if receiver.connected { Text(receiver.link.phase.fullLabel).font(.subheadline).foregroundStyle(.secondary) }
            }.accessibilityElement(children:.combine).accessibilityLabel(receiver.link.phase.accessibilityLabel)
            HStack {
                Text("This \(deviceKind)")
                DeviceNameField(focus:$editingDeviceName) { name in
                    let announced = PhoneName.current(appName:name)
                    receiver.setServiceName(announced.name,source:announced.source.rawValue)
                }.multilineTextAlignment(.trailing).accessibilityLabel("This \(deviceKind)’s device name")
            }
        } header: { Text("Session") }
    }
    private var inputSection:some View {
        Section {
            Picker("Input mode",selection:Binding(get:{receiver.macSupportsTrackpad ? inputMode : PhoneInputMode.touch.rawValue},set:{inputMode = $0})) {
                Text("Touch").tag(PhoneInputMode.touch.rawValue)
                Text("Trackpad").tag(PhoneInputMode.trackpad.rawValue).disabled(!receiver.macSupportsTrackpad)
            }.pickerStyle(.segmented).disabled(!receiver.connected)
                .onChange(of:inputMode) { _ in receiver.resetInputs() }
            if inputMode == PhoneInputMode.trackpad.rawValue && receiver.macSupportsTrackpad {
                TrackpadSpeedControl()
                NavigationLink { TrackpadGestureSettings(receiver:receiver) } label: { Label("Trackpad gestures",systemImage:"hand.draw") }
            }
        } header: { Text("Input") } footer: {
            Text(!receiver.connected ? "Connect to choose how you control your Mac." : inputMode == PhoneInputMode.trackpad.rawValue ? "Move the pointer from where it is. Tap to click; hold, then move to drag." : "Touch the desktop exactly where you want to interact.")
        }
    }
    private var keyboardSection:some View {
        Section {
            Button(action:openKeyboard) { Label("Show keyboard",systemImage:"keyboard") }
                .frame(minHeight:44)
                .disabled(!receiver.connected || !receiver.macSupportsKeyboard || receiver.keyboardPresentation.focus?.allowsTyping != true)
                .accessibilityHint("Close controls and type in the focused Mac field")
            Picker("Haptics",selection:$hapticLevel) {
                ForEach(PhoneHapticLevel.allCases,id:\.rawValue) { level in Text(level.rawValue.capitalized).tag(level.rawValue) }
            }.accessibilityHint("Click and hold feedback in Touch and Trackpad")
        } header: { Text("Keyboard & feedback") } footer: {
            Text(receiver.keyboardPresentation.focus?.kind == .secure ? "Secure input is protected. Use your Mac keyboard." : "The keyboard opens when you select a supported text field. Use Show keyboard for manual access.")
        }
    }
    private var displaySection:some View {
        Section {
            NavigationLink { PhoneArrangementView(receiver:receiver) } label: { Label("Arrange displays",systemImage:"rectangle.3.group") }
                .disabled(!receiver.connected || !receiver.macSupportsArrangement)
            ReceiverOrientationPicker()
            Toggle(isOn:$touchRipple) { Label("Show touch points",systemImage:"hand.tap") }
        } header: { Text("Display") }
    }
    private var helpSection:some View {
        Section {
            NavigationLink("Diagnostics") { PhoneDiagnosticsView(receiver:receiver) }
            NavigationLink("Advanced display settings") {
                Form {
                    Section("On-screen stats") {
                        Picker("Stats",selection:statsMode) { Text("Off").tag(0);Text("Compact").tag(1);Text("Detailed").tag(2) }
                        Text(statsDescription).font(.footnote).foregroundStyle(.secondary)
                    }
                    Section { NavigationLink("Video renderer") { DuoRenderingSettings() } }
                }.navigationTitle("Advanced display")
            }
            Link(destination:macAppURL) { Label("Get the Mac app",systemImage:"arrow.down.circle") }
            NavigationLink("About SideExtend") {
                Form {
                    LabeledRow("Version",value:version)
                    Link("myduodisplay.com",destination:URL(string:"https://myduodisplay.com")!)
                    Link("Source & licenses",destination:URL(string:"https://github.com/matthewjgl/duo-display")!)
                    if AppStore.isPubliclyAvailable { Link("Rate SideExtend",destination:AppStore.reviewURL) }
                }.navigationTitle("About SideExtend")
            }
        } header: { Text("Help & more") }
    }
}

private struct SessionSideRail:ViewModifier {
    var done:()->Void
    var disconnect:()->Void
    var canDisconnect:Bool
    var disconnecting:Bool
    func body(content:Content)->some View {
        content.safeAreaInset(edge:.trailing,spacing:0) {
            VStack(spacing:16) {
                Button(action:done) {
                    Image(systemName:"checkmark").font(.title3.weight(.semibold)).frame(width:48,height:48)
                        .foregroundStyle(.white).background(Color.accentColor,in:Circle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("Done").accessibilityHint("Return to your display")
                if canDisconnect {
                    Button(role:.destructive,action:disconnect) {
                        Image(systemName:"xmark").font(.title3.weight(.semibold)).frame(width:48,height:48)
                            .foregroundStyle(.red).background(Color.red.opacity(0.14),in:Circle())
                    }.buttonStyle(.plain).disabled(disconnecting)
                        .accessibilityLabel("Disconnect").accessibilityHint("Ask to end this display session")
                }
            }.padding(.horizontal,12).frame(maxHeight:.infinity)
        }.sessionRailSafeArea()
    }
}

// Extend only into Duo's reserved vertical rail. Ordinary iPhones keep
// their notch/home-indicator safe areas, including in landscape.
@available(iOS 27.1,*)
private struct SessionRailSafeArea:ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var edge
    func body(content:Content)->some View {
        content.ignoresSafeArea(.container,edges:edge == .trailing ? .trailing : [])
    }
}
private extension View {
    @ViewBuilder func sessionRailSafeArea()->some View {
        if #available(iOS 27.1,*) { modifier(SessionRailSafeArea()) }
        else { self }
    }
}

private struct PhoneSettingsChrome:ViewModifier {
    @ViewBuilder func body(content:Content) -> some View {
        if #available(iOS 16,*) {
            content.toolbar(.visible,for:.navigationBar)
                .toolbarBackground(.visible,for:.navigationBar)
        } else { content.navigationBarHidden(false) }
    }
}

private struct PhoneDiagnosticsView:View {
    @ObservedObject var receiver:StreamReceiver
    var body:some View {
        Form {
            Section("Connection") { PhoneDiagnosticsContent(receiver:receiver) }
            if receiver.videoSize != .zero {
                Section("Stream") {
                    LabeledRow("Resolution",value:"\(Int(receiver.videoSize.width)) × \(Int(receiver.videoSize.height))")
                    LabeledRow("Frame rate",value:"\(receiver.fps) FPS")
                    Text(receiver.trackpadTimingSummary).font(.caption)
                }
            }
            Section { TrustedMacManagement() }
        }.navigationTitle("Diagnostics")
    }
}
private struct PhoneDiagnosticsContent:View {
    @ObservedObject var receiver:StreamReceiver
    @ObservedObject private var trusted = TrustedConnections.shared
    @ObservedObject private var pairing = PairingDiscovery.shared
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(receiver.status)
            Text(trusted.status)
            Text(pairing.status)
            Text(receiver.discoveryDiagnostic)
            Text(trusted.browserDiagnostic)
            Text(pairing.diagnostics)
            Text("No devices found does not by itself mean permission was denied.")
            Button("Open Local Network settings") {
                if let url = URL(string:UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }.frame(minHeight:44)
            NavigationLink("Connection log") { DiagnosticsLogView() }
        }.font(.caption).textSelection(.enabled).padding(.vertical,8)
    }
}
private struct TrustedMacManagement:View {
    @ObservedObject private var trusted = TrustedConnections.shared
    @State private var pending:TrustedPeerRegistry.Record?
    var body:some View {
        DisclosureGroup("Paired Macs") {
            ForEach(trusted.rememberedPeers) { peer in
                HStack { Text(peer.name);Spacer();Button("Forget",role:.destructive) { pending = peer }.frame(minHeight:44) }
            }
            Text("Forgetting a Mac removes its pairing key. You will need to approve matching codes again.").font(.footnote)
        }
        .confirmationDialog("Forget this Mac?",isPresented:Binding(get:{pending != nil},set:{if !$0 { pending = nil }}),titleVisibility:.visible) {
            Button("Forget Mac",role:.destructive) { if let peer = pending { trusted.revoke(peer.id) };pending = nil }
            Button("Cancel",role:.cancel) { pending = nil }
        }
    }
}


private struct DuoRenderingSettings: View {
    @AppStorage("metalRenderer") private var metalRenderer = StreamReceiver.metalRendererDefault
    @AppStorage(MetalVideoRenderer.drawableCountKey) private var metalDrawables = 2

    private var renderer: Binding<Int> {
        Binding(get: { metalRenderer ? 0 : 1 }, set: { metalRenderer = $0 == 0 })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Start with the default settings. Change these only if the picture needs a little help.")
                    .font(.subheadline).foregroundStyle(.secondary)
                DuoSettingsCard("Video renderer") {
                    Picker("Video renderer", selection: renderer) {
                        Text("Metal").tag(0)
                        Text("iOS player").tag(1)
                    }.pickerStyle(.segmented)
                    if metalRenderer {
                        Text("Metal draws decoded video frames directly. This is SideExtend’s default renderer.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("The iOS player lets the system present the video. Try it if Metal shows a blank picture or unstable playback.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if metalRenderer {
                    DuoSettingsCard("Frame buffering") {
                        Picker("Frame buffering", selection: $metalDrawables) {
                            Text("2 buffers").tag(2)
                            Text("3 buffers").tag(3)
                        }.pickerStyle(.segmented)
                        Text("2 buffers keep a smaller pool of frames available for drawing. This is the current default.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("3 buffers give the renderer an extra frame to work with. This may smooth uneven playback, but can add delay.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("The best choice depends on your device. Changing either setting restarts the video view.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(20).frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Advanced video")
        .navigationBarTitleDisplayMode(.inline)
    }
}


// Use the system rail on Duo, without adding a top bar over video on other phones.
@available(iOS 27.1, *)
private struct DuoStreamingChrome: ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    let streaming: Bool
    @Binding var showSettings: Bool
    func body(content: Content) -> some View {
        content
            .toolbar(streaming && verticalEdge == nil ? .hidden : .visible, for: .navigationBar)
            .overlay {
                if streaming && verticalEdge == nil {
                    DuoFloatingSettings(showSettings: $showSettings)
                }
            }
    }
}

private struct DuoFloatingSettings: View {
    @Binding var showSettings: Bool
    var body: some View {
        GeometryReader { geometry in
            VStack {
                HStack {
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.body.weight(.medium)).foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Settings & help")
                }
                Spacer()
            }
            .padding(.top, geometry.safeAreaInsets.top + 8)
            .padding(.trailing, geometry.safeAreaInsets.trailing + 12)
        }
    }
}

extension View {
    @ViewBuilder
    fileprivate func duoStreamingChrome(_ streaming: Bool, showSettings: Binding<Bool>) -> some View {
        if #available(iOS 27.1, *) {
            modifier(DuoStreamingChrome(streaming: streaming, showSettings: showSettings))
        } else {
            navigationBarHidden(streaming)
                .overlay { if streaming { DuoFloatingSettings(showSettings: showSettings) } }
        }
    }
}

/// `NavigationStack` where it exists (iOS 16), a single-column
/// `NavigationView` on the iOS 15 floor. Both sheets here are one level deep,
/// so the two behave the same; this keeps the modern API where it is available.
struct AdaptiveNavigation<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 16, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }
                .navigationViewStyle(.stack)
        }
    }
}

/// `LabeledContent` where it exists (iOS 16, with its VoiceOver pairing of
/// label and value); the equivalent HStack on the iOS 15 floor.
struct LabeledRow: View {
    let title: String
    let value: String
    init(_ title: String, value: String) { self.title = title; self.value = value }
    var body: some View {
        if #available(iOS 16, *) {
            LabeledContent(title, value: value)
        } else {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

extension View {
    /// Hide the home indicator while streaming. `persistentSystemOverlays`
    /// is iOS 16; on iOS 15 the indicator simply stays, which is what the
    /// app did before it existed.
    @ViewBuilder
    func systemOverlaysHidden(_ hidden: Bool) -> some View {
        if #available(iOS 16, *) {
            persistentSystemOverlays(hidden ? .hidden : .automatic)
        } else {
            self
        }
    }
}

/// The device-name editor, deliberately kept out of any high-frequency
/// @ObservedObject so streaming updates can't rebuild it and steal focus.
private struct DeviceNameField: View {
    @AppStorage("deviceName") private var deviceName = ""
    let focus:FocusState<Bool>.Binding
    let onChange: (String) -> Void

    var body: some View {
        TextField("Device name", text: $deviceName,
                  prompt: Text(PhoneName.personalizedSystemName ?? "Automatic"))
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .focused(focus)
            .onChange(of: deviceName) { name in onChange(name) }
    }
}

// MARK: - Model

@MainActor
final class ReceiverModel: ObservableObject {
    let receiver: StreamReceiver
    private let decodesHEVC: Bool
    private var started = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Offer HEVC wherever the hardware decodes it (A9 and later; the A8/A8X
        // iPads stay on H.264). Panels here fit H.264's raster anyway, so HEVC
        // buys quality per bit, which matters most over WiFi.
        var decodesHEVC = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        #if DEBUG
        // The simulator has no hardware decoder; -forceHEVCOffer YES exercises
        // the HEVC receive path there with software decode.
        if UserDefaults.standard.bool(forKey: "forceHEVCOffer") { decodesHEVC = true }
        #endif
        self.decodesHEVC = decodesHEVC
        receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(),
                                  deviceKind: deviceKind,
                                  fallbackServiceName: UIDevice.current.name)
        // Seed with the whole screen in landscape; the view replaces it with
        // its window size on first layout, before any Mac connects.
        let native = UIScreen.main.nativeBounds.size   // portrait pixels
        applyPanel(pixelsWide: Int(max(native.width, native.height)),
                   pixelsHigh: Int(min(native.width, native.height)),
                   scale: Double(UIScreen.main.nativeScale),
                   displayMaxFrameRate: UIScreen.main.maximumFramesPerSecond)
        if let budget = DecodeBudget.maxPixelsPerSecond(model: DecodeBudget.currentModel) {
            receiver.setDecodeBudget(maxPixelsPerSecond: budget)
        }
        let announced = PhoneName.current()
        receiver.setInitialName(announced.name, source: announced.source.rawValue)
        #if DEBUG
        // Simulator UI harness: offline before anything can start a listener.
        if UserDefaults.standard.string(forKey: "DuoPreviewLink") != nil { receiver.debugGoOffline() }
        #endif
        receiver.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    #if DEBUG
    /// `-DuoPreviewLink usb|wifi|unplug|plugin|nowifi|usbfail` (optionally
    /// `-DuoPreviewSteps N`) runs the simulator UI harness instead of
    /// listening. DEBUG builds only.
    func runPreviewScenarioIfRequested() -> Bool {
        guard let name = UserDefaults.standard.string(forKey: "DuoPreviewLink") else { return false }
        // Launch arguments arrive as strings; integer(forKey:) parses them.
        let rawSteps = UserDefaults.standard.integer(forKey: "DuoPreviewSteps")
        let steps: Int? = rawSteps > 0 ? rawSteps : nil
        let native = UIScreen.main.bounds.size
        receiver.debugRunLinkScenario(name, steps: steps, panel: native)
        return true
    }
    #endif

    /// Re-announce the name if the Settings name became available or changed.
    func refreshAnnouncedName() {
        let announced = PhoneName.current()
        receiver.setServiceName(announced.name, source: announced.source.rawValue)
    }

    /// The window this app renders into, kept to re-read on activation.
    private weak var panelWindow: UIWindow?

    /// Announce the window this app renders into. A rotation, a fold or
    /// unfold (iPhone Duo) and a multitasking resize all land here, so the
    /// Mac always builds its virtual display for what is on screen.
    func updatePanel(window: UIWindow) {
        panelWindow = window
        // The window's own screen: an iPhone Duo's outer and inner screens
        // differ in size, and may in refresh rate. nativeScale, not scale:
        // the Plus phones render at 3x and downsample, and the Mac should
        // size for the pixels the panel actually has.
        // A background scene is laid out for the app switcher's snapshot,
        // possibly in another orientation; nobody sees it, so the Mac keeps
        // its desktop. sceneDidActivate re-reads the window on return.
        guard let scene = window.windowScene,
              scene.activationState != .background,
              scene.activationState != .unattached else { return }
        let screen = scene.screen
        guard let panel = ReceiverPanelGeometry(window: window.bounds.size,
                                                screen: screen.bounds.size,
                                                nativePixels: screen.nativeBounds.size,
                                                nativeScale: screen.nativeScale)
        else { return }
        applyPanel(pixelsWide: panel.pixelsWide, pixelsHigh: panel.pixelsHigh,
                   scale: panel.scale, displayMaxFrameRate: screen.maximumFramesPerSecond)
    }

    private func applyPanel(pixelsWide w: Int, pixelsHigh h: Int, scale: Double,
                            displayMaxFrameRate: Int) {
        // HEVC is bounded by the window in either orientation, so a large
        // mirrored Mac display is scaled to what this window can show
        // instead of sent in full.
        let longSide = max(w, h)
        let limitsChanged = receiver.setDecodeLimits(
            maxEncodeWide: nil, maxEncodeHigh: nil,
            hevc: decodesHEVC
                ? VideoCapability(codec: "hevc", maxWidth: longSide, maxHeight: longSide,
                                  maxFrameRate: 60)
                : nil)
        receiver.setPanel(pixelsWide: w, pixelsHigh: h, scale: scale,
                          displayMaxFrameRate: displayMaxFrameRate,
                          limitsChanged: limitsChanged)
    }

    func start() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey:"DuoUIPreviewConnected") { receiver.debugGoOffline();receiver.debugConfigureUIControls();return }
        #endif
        guard !started else { return }
        started = true
        #if DEBUG
        if runPreviewScenarioIfRequested() { return }   // harness: no listener
        #endif
        receiver.start(port: 9000)
    }

    // MARK: - Lock vs app switch vs app quit

    // A plain app switch keeps the session (and the Mac's virtual display,
    // and therefore the user's window arrangement) alive INDEFINITELY. The
    // assertion buys ~30s of live pings; after iOS suspends us the kernel
    // still accepts the Mac's redials, so the session survives untouched
    // until we return. Only a device lock (deliberate "screen off") or the
    // app being quit ends the session. Known hole: a lock that happens
    // after we're already suspended is undetectable — no code runs and the
    // kernel behaves identically — so the display stays up until the user
    // returns or the app dies.
    private var backgroundToken: UIBackgroundTaskIdentifier = .invalid

    func sceneDidBackground() {
        // Known limitation: lock detection rides the protected-data signal,
        // which only fires when a passcode is set AND "Require Passcode" is
        // Immediately (the Face ID default). Other configurations make a
        // lock indistinguishable from an app switch, so those keep the
        // session like a backgrounded app would.
        if !UIApplication.shared.isProtectedDataAvailable {
            // Backgrounded because the device locked, not an app switch.
            Log.info("backgrounded by device lock — sleeping now")
            goToSleep()
            return
        }
        Log.info("app switched away — keeping the session, rendering paused")
        beginBackgroundAssertion()
        receiver.setRenderingPaused(true)
    }

    func sceneDidActivate() {
        endBackgroundAssertion()
        receiver.setRenderingPaused(false)
        // A fold while the app was in the background: announce the screen it
        // came back on before a redialing Mac rebuilds for the old one.
        if let panelWindow { updatePanel(window: panelWindow) }
        receiver.ensureListening()
    }

    func deviceWillLock() {
        Log.info("device locking — sleeping now")
        goToSleep()
    }

    /// Unlock arrives via the protected-data notification, which also fires
    /// when the user unlocks into ANOTHER app while we sit in the background
    /// — don't re-arm the listener or unpause rendering off-screen there;
    /// the real return still comes through scenePhase.
    func deviceDidUnlock() {
        guard UIApplication.shared.applicationState == .active else {
            Log.info("unlocked while backgrounded — staying dormant")
            return
        }
        sceneDidActivate()
    }

    /// User swiped the app away (or iOS terminates us while still running):
    /// ~5s of runtime remain, plenty for the "closing" goodbye that lets the
    /// Mac end the session immediately instead of after its silence grace.
    func appWillTerminate() {
        Log.info("app terminating — closing session")
        receiver.shutDown()
    }

    private func goToSleep() {
        receiver.enterSleep { [weak self] in
            DispatchQueue.main.async { self?.endBackgroundAssertion() }
        }
    }

    private func beginBackgroundAssertion() {
        guard backgroundToken == .invalid else { return }
        backgroundToken = UIApplication.shared.beginBackgroundTask { [weak self] in
            // Suspension takes us now; the session stays up by design (the
            // kernel keeps accepting for us) — just release the assertion.
            self?.endBackgroundAssertion()
        }
    }

    private func endBackgroundAssertion() {
        guard backgroundToken != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundToken)
        backgroundToken = .invalid
    }
}

// MARK: - Touch sampling

extension UIEvent {
    /// Every position UIKit recorded for `touch` in this update, oldest first.
    ///
    /// The panel samples faster than UIKit delivers, so a single `touchesMoved`
    /// stands for several real positions. This batch is that whole history and
    /// its *last* entry is `touch` itself, so forward the list as it comes:
    /// sending `touch` alongside it puts the newest sample ahead of its own
    /// history and emits it twice, which reads as backtracking on fast strokes.
    /// Falls back to the touch alone when UIKit coalesced nothing.
    func samples(for touch: UITouch) -> [UITouch] {
        let batch = coalescedTouches(for: touch) ?? []
        return batch.isEmpty ? [touch] : batch
    }
}

// MARK: - Window size

/// Reports the window it sits in when attached and on every layout. It
/// fills the root view, so a rotation, a fold or a multitasking resize lays
/// it out; reports of an unchanged window cost nothing (setPanel ignores
/// them).
private struct WindowObserver: UIViewRepresentable {
    let onLayout: (UIWindow) -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        view.onLayout = onLayout
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.onLayout = onLayout
    }

    final class ObserverView: UIView {
        var onLayout: ((UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { onLayout?(window) }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let window { onLayout?(window) }
        }
    }
}

// MARK: - Video layer host view

/// UIView whose backing layer is the AVSampleBufferDisplayLayer.
/// Forwards touches as normalized video-space coordinates (touchscreen mode).
struct VideoLayerView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    let receiver: StreamReceiver
    let useMetal: Bool
    let inputMode: PhoneInputMode
    let inputEnabled: Bool

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.backgroundColor = .black
        view.clipsToBounds = true   // a held frame can be larger than a folded screen
        view.isMultipleTouchEnabled = true
        view.receiver = receiver

        Log.info("video view: metal=\(useMetal)")
        if useMetal, let renderer = MetalVideoRenderer() {
            Log.info("metal renderer active")
            view.metalRenderer = renderer
            view.layer.addSublayer(renderer.metalLayer)
            receiver.onDecodedFrame = { [weak renderer] pixelBuffer, captureMs in
                renderer?.render(pixelBuffer, captureMs: captureMs)
            }
            renderer.onPresented = { [weak receiver] presentedTime, captureMs in
                receiver?.recordPresented(presentedTime: presentedTime, captureMs: captureMs)
            }
        } else {
            receiver.onDecodedFrame = nil   // route frames back to AVSBDL
            displayLayer.frame = view.bounds
            view.layer.addSublayer(displayLayer)
        }

        view.inputEngine.normalize = { [weak view] point in view?.normalized(point) }
        view.inputEngine.onPencil = { [weak receiver] phase, x, y, pressure, azimuth, altitude in
            receiver?.sendPencil(phase: phase, x: x, y: y,
                                 pressure: pressure, azimuth: azimuth,
                                 altitude: altitude)
        }
        view.inputEngine.onProximity = { [weak receiver] entering, x, y in
            receiver?.sendProximity(entering: entering, x: x, y: y)
        }
        view.inputEngine.install(on: view)

        let pan = UIPanGestureRecognizer(target: view, action: #selector(VideoView.didTwoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(pan)
        view.directPan = pan
        let secondary = UITapGestureRecognizer(target:view,action:#selector(VideoView.didSecondaryTap(_:)))
        secondary.numberOfTouchesRequired = 2;secondary.require(toFail:pan)
        view.addGestureRecognizer(secondary);view.directSecondary = secondary
        view.installKeyboardViewportGestures()
        view.configureInput(mode: inputMode, enabled: inputEnabled)

        // Local cursor echo: position updates ride the ~2ms control path
        // instead of the ~30ms video path, so the pointer feels native.
        receiver.onCursor = { [weak view] x, y, visible in
            view?.moveCursor(x: x, y: y, visible: visible)
        }
        receiver.onCursorImage = { [weak view] image, anchor, normSize in
            view?.setCursorSprite(image, anchor: anchor, normSize: normSize)
        }
        // Replay the sprite/position that arrived before this view existed
        // (first frames land after the connect-time sprite) or that the
        // previous view held (metal-renderer toggle rebuilds the view tree).
        if let sprite = receiver.cursorSprite {
            view.setCursorSprite(sprite.image, anchor: sprite.anchor, normSize: sprite.normSize)
        }
        let state = receiver.cursorState
        view.moveCursor(x: state.x, y: state.y, visible: state.visible)
        return view
    }

    func updateUIView(_ uiView: VideoView, context: Context) {
        // videoSize arrives after the format description — re-fit the layers.
        uiView.configureInput(mode: inputMode, enabled: inputEnabled)
        uiView.refreshKeyboardViewport()
        uiView.setNeedsLayout()
    }
    static func dismantleUIView(_ view: VideoView, coordinator: ()) { view.cancelActiveInput() }

    final class VideoView: UIView, UIGestureRecognizerDelegate {
        weak var receiver: StreamReceiver?
        var metalRenderer: MetalVideoRenderer?
        let inputEngine = InputCaptureEngine()
        var directPan: UIPanGestureRecognizer?
        var directSecondary:UITapGestureRecognizer?
        private var keyboardZoom = KeyboardZoomViewport()
        private var zoomingForKeyboard = false
        private var softwareKeyboardVisible = false
        private var zoomFocusToken:String?
        private var keyboardObserver:NSObjectProtocol?
        private var keyboardTransitionUntil:Double = 0
        private var zoomPinch:UIPinchGestureRecognizer?
        private var zoomPan:UIPanGestureRecognizer?
        private var localViewportTouches = false
        func installKeyboardViewportGestures() {
            let pinch = UIPinchGestureRecognizer(target:self,action:#selector(pinchViewport(_:)))
            let pan = UIPanGestureRecognizer(target:self,action:#selector(panViewport(_:)))
            pan.minimumNumberOfTouches = 2;pan.maximumNumberOfTouches = 2
            for recognizer in [pinch,pan] { recognizer.delegate = self;recognizer.isEnabled = false;addGestureRecognizer(recognizer) }
            zoomPinch = pinch;zoomPan = pan
            keyboardObserver = NotificationCenter.default.addObserver(forName:UIResponder.keyboardWillChangeFrameNotification,object:nil,queue:.main) { [weak self] notification in
                guard let self,let window = self.window,let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let frame = window.convert(end,from:window.screen.coordinateSpace)
                self.keyboardTransitionUntil = ProcessInfo.processInfo.systemUptime+0.7
                self.softwareKeyboardVisible = window.bounds.intersection(frame).height > 100
                self.refreshKeyboardViewport()
            }
        }
        deinit { if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) } }
        func refreshKeyboardViewport() {
            let active = softwareKeyboardVisible && receiver?.keyboardPresentation.visible == true
            let token = receiver?.keyboardPresentation.focus?.token
            if active != zoomingForKeyboard || (active && token != zoomFocusToken) {
                cancelActiveInput()
                if active {
                    keyboardZoom.focus(receiver?.keyboardPresentation.focus?.region,fallback:cursorNorm)
                }
                zoomingForKeyboard = active;zoomFocusToken = active ? token : nil
                // Keyboard resizing is local, not a display topology change.
                settledBounds = .zero;releaseHold()
            }
            zoomPinch?.isEnabled = active && acceptsInput
            zoomPan?.isEnabled = active && acceptsInput
            directPan?.isEnabled = !active && mode == .touch && acceptsInput
            directSecondary?.isEnabled = !active && mode == .touch && acceptsInput
            setNeedsLayout()
        }
        func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith other:UIGestureRecognizer)->Bool {
            (gestureRecognizer === zoomPan && other === zoomPinch) || (gestureRecognizer === zoomPinch && other === zoomPan)
        }
        @objc private func pinchViewport(_ recognizer:UIPinchGestureRecognizer) {
            guard zoomingForKeyboard,let video = receiver?.videoSize else { return }
            keyboardZoom.pinch(recognizer.scale,at:recognizer.location(in:self),video:video,in:bounds)
            recognizer.scale = 1;setNeedsLayout()
        }
        @objc private func panViewport(_ recognizer:UIPanGestureRecognizer) {
            guard zoomingForKeyboard,let video = receiver?.videoSize else { return }
            keyboardZoom.pan(recognizer.translation(in:self),video:video,in:bounds)
            recognizer.setTranslation(.zero,in:self);setNeedsLayout()
        }
        private var mode: PhoneInputMode = .touch
        private var acceptsInput = true
        private var trackpad = TrackpadGestureState()
        private var trackpadTouches: [ObjectIdentifier: UITouch] = [:]
        private var trackpadHold: DispatchWorkItem?
        private var blockedUntilLift = false
        private var inputBounds = CGRect.zero
        // The streamed desktop is not a UIKit text editor. Opt this surface
        // out of the public three-finger editing HUD in Trackpad mode; actual
        // keyboard editors and system edge/home gestures keep their behavior.
        override var editingInteractionConfiguration:UIEditingInteractionConfiguration {
            mode == .trackpad ? .none : .default
        }

        func configureInput(mode: PhoneInputMode, enabled: Bool) {
            guard self.mode != mode || acceptsInput != enabled else { return }
            blockedUntilLift = trackpad.contactCount > 0 || downSent || pendingDown != nil
            cancelActiveInput()
            self.mode = mode; acceptsInput = enabled
            directPan?.isEnabled = mode == .touch && enabled
            directSecondary?.isEnabled = mode == .touch && enabled
            refreshKeyboardViewport()
        }
        func cancelActiveInput() {
            trackpadHold?.cancel(); trackpadHold = nil
            for command in trackpad.cancel() { receiver?.sendTrackpad(command) }
            trackpadTouches.removeAll(); discardPendingDown(); twoFingerActive = false
            inputEngine.cancel()
            receiver?.resetInputs()
        }
        private func trackpadTouchesChanged(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?) {
            trackpadHold?.cancel(); trackpadHold = nil
            for touch in touches {
                if phase == "ended" || phase == "cancelled" { trackpadTouches.removeValue(forKey: ObjectIdentifier(touch)) }
                else { trackpadTouches[ObjectIdentifier(touch)] = touch }
            }
            if phase == "cancelled" { cancelActiveInput(); return }
            let commands = trackpad.update(points: trackpadTouches.values.map { $0.location(in: self) },
                                            time: ProcessInfo.processInfo.systemUptime)
            for command in commands { receiver?.sendTrackpad(command) }
            if trackpad.contactCount == 1 {
                let hold = DispatchWorkItem { [weak self] in
                    guard let self, self.acceptsInput, self.mode == .trackpad else { return }
                    for command in self.trackpad.advance(time: ProcessInfo.processInfo.systemUptime) { self.receiver?.sendTrackpad(command) }
                }
                trackpadHold = hold
                DispatchQueue.main.asyncAfter(deadline: .now() + TrackpadGestureState.holdDelay, execute: hold)
            }
        }

        private let cursorLayer: CALayer = {
            let layer = CALayer()
            layer.isHidden = true
            layer.zPosition = 10
            // Position updates arrive at 120Hz — implicit animations would
            // smear the cursor behind every move.
            layer.actions = ["position": NSNull(), "contents": NSNull(),
                             "bounds": NSNull(), "hidden": NSNull()]
            return layer
        }()
        private var cursorNormSize = CGSize.zero
        private var cursorNorm = CGPoint(x: 0.5, y: 0.5)
        private var cursorVisible = false

        #if DEBUG
        private lazy var viewportPreview:CALayer = {
            let preview = CALayer();preview.zPosition = 1
            preview.actions = ["bounds":NSNull(),"position":NSNull()]
            preview.contents = UIGraphicsImageRenderer(size:CGSize(width:900,height:1440)).image { context in
                UIColor.systemIndigo.setFill();context.fill(CGRect(x:0,y:0,width:900,height:1440))
                for y in stride(from:0,to:1440,by:120) {
                    ("Desktop row \(y/120)" as NSString).draw(at:CGPoint(x:30,y:y),withAttributes:[.font:UIFont.systemFont(ofSize:30),.foregroundColor:UIColor.white])
                }
                UIColor.secondarySystemBackground.setFill();context.fill(CGRect(x:180,y:1080,width:585,height:86))
                ("Message · sample field" as NSString).draw(at:CGPoint(x:200,y:1100),withAttributes:[.font:UIFont.systemFont(ofSize:28),.foregroundColor:UIColor.label])
            }.cgImage
            return preview
        }()
        #endif

        private var lastLoggedLayout = ""

        // Between a resize (rotation, fold, Split View) and the first frame of
        // the desktop the Mac rebuilds for it, the last frame is scaled to
        // cover the new shape and blurred; once the new desktop arrives it
        // swaps in under the blur, which then clears to reveal it.
        private var lastVideoSize = CGSize.zero
        private var settledBounds = CGRect.zero   // the bounds the current video was sized for
        private var holdingStaleFrame = false
        private var holdRelease: DispatchWorkItem?
        private var holdArmedFor = CGRect.zero   // the bounds the fallback reveal was armed for
        private let blurView: UIVisualEffectView = {
            let view = UIVisualEffectView(effect: nil)
            view.isUserInteractionEnabled = false
            view.layer.zPosition = 20   // above the video and the cursor
            return view
        }()

        /// Returns whether a hold just began, so the caller animates into it.
        private func updateHold() -> Bool {
            let video = receiver?.videoSize ?? .zero
            if zoomingForKeyboard || ProcessInfo.processInfo.systemUptime < keyboardTransitionUntil { lastVideoSize = video;settledBounds = bounds;releaseHold();return false }
            if video != lastVideoSize || video == .zero || settledBounds == .zero
                || bounds == settledBounds {
                lastVideoSize = video
                settledBounds = bounds
                releaseHold()
                return false
            }
            let began = !holdingStaleFrame
            holdingStaleFrame = true
            // A Mac that never sends a new desktop (an older sender, mirror
            // mode, a fixed Display size, or the size settled back on one it
            // already streams) must not leave the picture blurred: reveal
            // what there is. Armed per window shape, not per layout pass:
            // every receiver publish relayouts, and re-arming there would
            // push the reveal out forever.
            if began || bounds != holdArmedFor {
                holdArmedFor = bounds
                holdRelease?.cancel()
                let release = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.settledBounds = self.bounds
                    self.releaseHold()
                    self.setNeedsLayout()
                }
                holdRelease = release
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: release)
            }
            if began {
                UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState]) {
                    self.blurView.effect = UIBlurEffect(style: .dark)
                }
            }
            return began
        }

        private func releaseHold() {
            holdRelease?.cancel()
            holdRelease = nil
            guard holdingStaleFrame else { return }
            holdingStaleFrame = false
            // A beat for the first new frame to decode under the blur.
            UIView.animate(withDuration: 0.4, delay: 0.08,
                           options: [.beginFromCurrentState, .curveEaseOut]) {
                self.blurView.effect = nil
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let window {
                // SwiftUI owns keyboard avoidance on the hosting view, not on
                // UIWindow's keyboardLayoutGuide (which can stay empty).
                // Re-measure the real remaining viewport after every rotation.
                let visible = ReceiverViewport.hasSoftwareKeyboard(window:window.bounds,viewport:convert(bounds,to:window))
                if visible != softwareKeyboardVisible {
                    softwareKeyboardVisible = visible
                    refreshKeyboardViewport()
                }
            }
            if inputBounds != .zero && inputBounds.size != bounds.size {
                blockedUntilLift = trackpad.contactCount > 0 || downSent || pendingDown != nil
                cancelActiveInput()
            }
            inputBounds = bounds
            let holdBegan = updateHold()
            if blurView.superview == nil { addSubview(blurView) }
            blurView.frame = bounds
            CATransaction.begin()
            if holdBegan {
                CATransaction.setAnimationDuration(0.25)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            } else {
                CATransaction.setDisableActions(true)
            }
            // Both renderers draw into the video rect; the metal layer scales
            // its drawable to fill its frame, AVSBDL aspect-fits.
            if let renderer = metalRenderer {
                renderer.metalLayer.frame = videoRect() ?? bounds
            } else {
                layer.sublayers?.first?.frame = videoRect() ?? bounds
            }
            #if DEBUG
            if UserDefaults.standard.bool(forKey:"DuoUIPreviewKeyboardZoom") {
                if viewportPreview.superlayer == nil { layer.addSublayer(viewportPreview) }
                viewportPreview.frame = videoRect() ?? bounds
            }
            #endif
            CATransaction.commit()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if cursorLayer.superlayer == nil { layer.addSublayer(cursorLayer) }
            updateCursorLayout()
            CATransaction.commit()
            // Rotation diagnostics — one line per layout change.
            let video = receiver?.videoSize ?? .zero
            let line = "layout: bounds=\(Int(bounds.width))x\(Int(bounds.height))"
                + " video=\(Int(video.width))x\(Int(video.height))"
                + " layer=\(Int(layer.sublayers?.first?.frame.width ?? -1))x\(Int(layer.sublayers?.first?.frame.height ?? -1))"
            #if DEBUG
            if UserDefaults.standard.bool(forKey:"DuoUIPreviewKeyboardZoom") {
                accessibilityIdentifier = "keyboard-viewport-preview"
                accessibilityLabel = "Keyboard viewport preview"
                accessibilityValue = "active=\(zoomingForKeyboard),software=\(softwareKeyboardVisible),presentation=\(receiver?.keyboardPresentation.visible == true),bounds=\(bounds),window=\(window?.bounds ?? .zero)"
                isAccessibilityElement = true
            }
            #endif
            if line != lastLoggedLayout {
                lastLoggedLayout = line
                Log.info(line)
            }
        }

        /// Aspect-fit rect of the video inside the view (inverse of normalized()),
        /// or, while a stale frame is held, the rect that covers the view.
        private func videoRect() -> CGRect? {
            guard let video = receiver?.videoSize, video != .zero,
                  bounds.width > 0, bounds.height > 0 else { return nil }
            if zoomingForKeyboard { return keyboardZoom.rect(video:video,in:bounds) }
            if !holdingStaleFrame { return ReceiverViewport.rect(video:video,in:bounds) }
            let fit = min(bounds.width / video.width, bounds.height / video.height)
            let cover = max(bounds.width / video.width, bounds.height / video.height)
            let scale = holdingStaleFrame ? cover : fit
            let size = CGSize(width: video.width * scale, height: video.height * scale)
            return CGRect(x: (bounds.width - size.width) / 2,
                          y: (bounds.height - size.height) / 2,
                          width: size.width, height: size.height)
        }

        func moveCursor(x: Double, y: Double, visible: Bool) {
            cursorNorm = CGPoint(x: x, y: y)
            cursorVisible = visible
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.isHidden = !visible || cursorLayer.contents == nil
            updateCursorLayout()
            CATransaction.commit()
        }

        func setCursorSprite(_ image: CGImage, anchor: CGPoint, normSize: CGSize) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.contents = image
            cursorLayer.anchorPoint = anchor
            cursorNormSize = normSize
            cursorLayer.isHidden = !cursorVisible
            updateCursorLayout()
            CATransaction.commit()
        }

        private func updateCursorLayout() {
            guard let rect = videoRect(), cursorNormSize != .zero else { return }
            cursorLayer.bounds = CGRect(x: 0, y: 0,
                                        width: cursorNormSize.width * rect.width,
                                        height: cursorNormSize.height * rect.height)
            cursorLayer.position = CGPoint(x: rect.minX + cursorNorm.x * rect.width,
                                           y: rect.minY + cursorNorm.y * rect.height)
        }

        // The video is aspect-fit inside the view; map view coords into the
        // displayed video rect and normalize to [0,1].
        fileprivate func normalized(_ point: CGPoint) -> (x: Double, y: Double)? {
            guard let rect = videoRect() else { return nil }
            let x = (point.x - rect.minX) / rect.width
            let y = (point.y - rect.minY) / rect.height
            return (min(max(x, 0), 1), min(max(y, 0), 1))
        }

        private func isFinger(_ touch: UITouch) -> Bool {
            switch touch.type {
            case .direct, .indirectPointer: return true
            default: return false
            }
        }

        private func isPencil(_ touch: UITouch) -> Bool {
            touch.type == .pencil
        }

        private var twoFingerActive = false
        private var lastPan = CGPoint.zero
        private var lastNorm: (x: Double, y: Double) = (0.5, 0.5)

        @objc func didTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let video = receiver?.videoSize, video != .zero else { return }
            switch recognizer.state {
            case .began:
                twoFingerActive = true
                lastPan = .zero
                // macOS delivers scroll to whatever sits under the cursor, and
                // the cursor no longer follows the fingers now that a press is
                // withheld until it commits. Put it on the gesture once, up
                // front, so the scroll lands on the window being touched. Once
                // only: a real trackpad does not drag the cursor while
                // scrolling, and moving it mid-gesture would change the target.
                if let n = normalized(recognizer.location(in: self)) {
                    lastNorm = n
                    receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                }
            case .changed:
                let t = recognizer.translation(in: self)
                let scale = (videoRect()?.width ?? bounds.width) / video.width
                // Deltas in video pixels, natural-scrolling direction.
                receiver?.sendScroll(dx: (t.x - lastPan.x) / scale,
                                     dy: (t.y - lastPan.y) / scale)
                lastPan = t
            default:
                twoFingerActive = false
            }
        }
        @objc func didSecondaryTap(_ recognizer:UITapGestureRecognizer) {
            guard mode == .touch,acceptsInput,recognizer.state == .ended,
                  let n = normalized(recognizer.location(in:self)) else { return }
            cancelActiveInput()
            receiver?.sendTouch(phase:"moved",x:n.x,y:n.y)
            receiver?.sendTrackpad(.secondaryClick)
        }

        // A press is only a click once we know a second finger is not coming.
        // Sending `began` on contact posted a mouse-down we then had to take
        // back, and taking it back only works when UIKit happens to deliver
        // `cancelled`; when the pan recognizer misses and we get a plain
        // `ended` instead, that down/up pair *is* a click, which is why every
        // other two-finger scroll opened whatever sat under the first finger.
        // So hold the down until the gesture commits to being one.
        private var pendingDown: (x: Double, y: Double)?
        private var downSent = false
        private var holdTimer: DispatchWorkItem?

        /// Movement (in points) that turns a held press into a drag.
        private let dragSlop: CGFloat = 10
        /// A press this long with no second finger is a deliberate hold, so
        /// commit it: press-and-hold menus and drag handles need the button.
        private let holdDelay: TimeInterval = 0.12
        private var pendingDownPoint: CGPoint = .zero
        private var directTyping = PointerTypingIntent()
        private var directHoldFeedback:DispatchWorkItem?
        private var directFeedback = DirectTouchFeedbackState()
        private func confirmDirectHold() {
            guard downSent,acceptsInput,receiver?.connected == true,
                  let feedback = directFeedback.engage(accepted:true) else { return }
            receiver?.hidePhoneKeyboard();receiver?.inputFeedback?(feedback)
        }

        /// Emit the withheld `began`, at the point the finger first landed so a
        /// drag starts where the user touched rather than where slop was crossed.
        private func commitPendingDown() {
            guard let p = pendingDown, !downSent else { return }
            downSent = true
            holdTimer?.cancel()
            holdTimer = nil
            downSent = receiver?.sendTouch(phase: "began", x: p.x, y: p.y) == true
        }

        /// Drop the press without a trace. Nothing reached the Mac, so there is
        /// no button to release and no click to suppress.
        private func discardPendingDown() {
            directHoldFeedback?.cancel();directHoldFeedback = nil;directFeedback.cancel();directTyping.cancel()
            pendingDown = nil
            downSent = false
            holdTimer?.cancel()
            holdTimer = nil
        }

        private func send(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?) {
            let fingers = touches.filter { isFinger($0) }
            guard !fingers.isEmpty else { return }
            // Ignore single-finger events while a two-finger gesture runs,
            // and end the click if a second finger joins mid-press.
            if twoFingerActive || (event?.allTouches?.filter { isFinger($0) }.count ?? 1) > 1 {
                if downSent {
                    receiver?.sendTouch(phase: "cancelled", x: lastNorm.x, y: lastNorm.y)
                }
                discardPendingDown()
                return
            }
            guard let touch = fingers.first,
                  let norm = normalized(touch.location(in: self)) else { return }
            lastNorm = norm

            switch phase {
            case "began":
                let location = touch.location(in: self)
                pendingDown = norm
                pendingDownPoint = location
                downSent = false
                directFeedback.cancel()
                directTyping.begin(location,time:ProcessInfo.processInfo.systemUptime)
                let feedback = DispatchWorkItem { [weak self] in self?.confirmDirectHold() }
                directHoldFeedback = feedback
                DispatchQueue.main.asyncAfter(deadline:.now()+0.4,execute:feedback)
                let work = DispatchWorkItem { [weak self] in self?.commitPendingDown() }
                holdTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
                return
            case "ended":
                let tap = directTyping.end(touch.location(in:self),time:ProcessInfo.processInfo.systemUptime)
                // A tap: nothing was posted yet, so post the whole click now.
                if pendingDown != nil, !downSent { commitPendingDown() }
                // No down means the press was already discarded (a second
                // finger took it), so there is nothing to release.
                let accepted = downSent && receiver?.sendTouch(phase: "ended", x: norm.x, y: norm.y,typingIntent:tap) == true
                if let feedback = directFeedback.complete(tap:tap,accepted:accepted) { receiver?.inputFeedback?(feedback) }
                discardPendingDown()
                return
            case "cancelled":
                if downSent {
                    receiver?.sendTouch(phase: "cancelled", x: norm.x, y: norm.y)
                }
                discardPendingDown()
                return
            case "moved":
                directTyping.move(touch.location(in:self))
                if hypot(touch.location(in:self).x-pendingDownPoint.x,touch.location(in:self).y-pendingDownPoint.y) > dragSlop {
                    if pendingDown != nil,!downSent { commitPendingDown() }
                    confirmDirectHold()
                }
                if pendingDown != nil, !downSent {
                    let moved = hypot(touch.location(in: self).x - pendingDownPoint.x,
                                      touch.location(in: self).y - pendingDownPoint.y)
                    // Below slop the finger is still deciding: track the cursor
                    // (the Mac turns a move without a down into mouseMoved) but
                    // keep the button up so a second finger can still cancel.
                    if moved > dragSlop { commitPendingDown() }
                }
            default:
                break
            }

            if phase == "moved", let event {
                // Forward every coalesced sample so the Mac gets the full-rate
                // drag, then UIKit's predicted touch so the cursor leads toward
                // where the finger will be (~1 frame of perceived latency back;
                // corrected by the next real sample).
                for t in event.samples(for: touch) {
                    if let n = normalized(t.location(in: self)) {
                        lastNorm = n
                        receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                    }
                }
                if let predicted = event.predictedTouches(for: touch)?.last,
                   let n = normalized(predicted.location(in: self)) {
                    receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                }
                return
            }
            receiver?.sendTouch(phase: phase, x: norm.x, y: norm.y)
        }

        private func sendPencilAsTouch(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?) {
            guard let touch = touches.first,
                  let norm = normalized(touch.location(in: self)) else { return }
            lastNorm = norm
            if phase == "moved", let event {
                for t in event.samples(for: touch) {
                    if let n = normalized(t.location(in: self)) {
                        lastNorm = n
                        receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                    }
                }
                if let predicted = event.predictedTouches(for: touch)?.last,
                   let n = normalized(predicted.location(in: self)) {
                    receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                }
                return
            }
            receiver?.sendTouch(phase: phase, x: norm.x, y: norm.y)
        }

        private func routeTouches(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?, ended: Bool) {
            if !acceptsInput || blockedUntilLift {
                if ended, event?.allTouches?.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) != false { blockedUntilLift = false }
                return
            }
            if zoomingForKeyboard {
                let contacts = event?.allTouches?.filter { isFinger($0) && $0.phase != .ended && $0.phase != .cancelled }.count ?? 0
                if contacts >= 2 || localViewportTouches {
                    if !localViewportTouches { cancelActiveInput();localViewportTouches = true }
                    if ended && contacts == 0 { localViewportTouches = false }
                    return
                }
            }
            let pencil = touches.filter { isPencil($0) }
            let finger = touches.filter { isFinger($0) }
            let usePencilWire = receiver?.macSupportsPencilWire ?? false

            if !pencil.isEmpty {
                if usePencilWire {
                    inputEngine.handle(pencil, event: event, ended: ended)
                } else {
                    sendPencilAsTouch(phase, pencil, event)
                }
            }
            // Palm rejection: ignore resting fingers while the pen is down.
            if !finger.isEmpty && !inputEngine.hasActivePen {
                if mode == .trackpad, receiver?.macSupportsTrackpad == true { trackpadTouchesChanged(phase, finger, event) }
                else if mode == .touch { send(phase, finger, event) }
            }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if mode == .touch && acceptsInput && TouchRipple.isEnabled {
                for touch in touches where touch.type == .direct {
                    TouchRipple.show(in: layer, at: touch.location(in: self))
                }
            }
            routeTouches("began", touches, event, ended: false)
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            routeTouches("moved", touches, event, ended: false)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            routeTouches("ended", touches, event, ended: true)
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            routeTouches("cancelled", touches, event, ended: true)
        }
    }
}

// MARK: - Touch ripple

/// A brief soft ring where a finger lands. Local and cosmetic: nothing is sent
/// to the Mac, and it never touches hit-testing or the touch path.
enum TouchRipple {
    static let defaultsKey = "touchRipple"

    /// On unless the user switched it off.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) == nil
            || UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func show(in host: CALayer, at point: CGPoint) {
        let diameter: CGFloat = 56
        let ring = CAShapeLayer()
        ring.path = UIBezierPath(ovalIn: CGRect(x: -diameter / 2, y: -diameter / 2,
                                                width: diameter, height: diameter)).cgPath
        ring.position = point
        ring.fillColor = UIColor.white.withAlphaComponent(0.14).cgColor
        ring.strokeColor = UIColor.white.withAlphaComponent(0.38).cgColor
        ring.lineWidth = 1.5
        ring.opacity = 0
        ring.zPosition = 15   // above the video and cursor, below the resize blur
        host.addSublayer(ring)

        let duration = 0.45
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.45
        scale.toValue = 1.0
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 1.0, 0.0]
        fade.keyTimes = [0.0, 0.18, 1.0]
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
    }
}

// MARK: - Apple Pencil capture

/// Captures Apple Pencil hover and stroke on a host view.
/// Finger touches stay on VideoView's existing `touch` wire path.
///
/// TODO: Capture Apple Pencil Pro barrel roll (UIKit rollAngle, iOS 17.5+) once
/// hardware is available for testing.
final class InputCaptureEngine: NSObject {
    var onPencil: ((_ phase: String, _ x: Double, _ y: Double,
                    _ pressure: Double, _ azimuth: Double, _ altitude: Double) -> Void)?
    var onProximity: ((_ entering: Bool, _ x: Double, _ y: Double) -> Void)?

    /// True while at least one pen contact is on the glass (palm rejection).
    var hasActivePen: Bool { !activePens.isEmpty }

    /// Map a point in the host view to normalized video coordinates.
    var normalize: ((CGPoint) -> (x: Double, y: Double)?)?

    private weak var hostView: UIView?
    private var activePens: Set<UInt64> = []
    private var proximityActive = false

    func install(on view: UIView) {
        hostView = view
        view.isMultipleTouchEnabled = true

        // Hover tilt/azimuth on the recognizer is iOS 16.4. Pencil hover needs
        // an M2 iPad Pro or newer, which never runs anything older, so
        // skipping the recognizer below 16.4 loses nothing on those devices.
        if #available(iOS 16.4, *) {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
            hover.allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
            view.addGestureRecognizer(hover)
        }
    }

    @objc private func hoverChanged(_ gr: UIHoverGestureRecognizer) {
        guard #available(iOS 16.4, *) else { return }
        guard activePens.isEmpty, let view = hostView else { return }
        guard let n = normalize?(gr.location(in: view)) else { return }
        switch gr.state {
        case .began:
            openProximity(x: n.x, y: n.y)
            fallthrough
        case .changed:
            let azimuth = Double(gr.azimuthAngle(in: view))
            let altitude = Double(gr.altitudeAngle)
            onPencil?("hover", n.x, n.y, 0, azimuth, altitude)
        case .ended, .cancelled, .failed:
            guard activePens.isEmpty else { return }
            closeProximity(x: n.x, y: n.y)
        default:
            break
        }
    }

    func cancel() {
        activePens.removeAll()
        if proximityActive { proximityActive = false; onProximity?(false, 0, 0) }
    }
    func handle(_ touches: Set<UITouch>, event: UIEvent?, ended: Bool) {
        guard hostView != nil else { return }
        for touch in touches where touch.type == .pencil {
            emitPen(touch, event: event, ended: ended)
        }
    }

    private func openProximity(x: Double, y: Double) {
        guard !proximityActive else { return }
        proximityActive = true
        onProximity?(true, x, y)
    }

    private func closeProximity(x: Double, y: Double) {
        guard proximityActive else { return }
        proximityActive = false
        onProximity?(false, x, y)
    }

    private func emitPen(_ touch: UITouch, event: UIEvent?, ended: Bool) {
        guard let view = hostView else { return }
        let id = UInt64(bitPattern: Int64(ObjectIdentifier(touch).hashValue))
        let loc = touch.location(in: view)
        guard let n = normalize?(loc) else { return }
        let (nx, ny) = (n.x, n.y)

        let pressure = min(Double(touch.force), 1.0)
        let azimuth = Double(touch.azimuthAngle(in: view))
        let altitude = Double(touch.altitudeAngle)

        if !ended && !activePens.contains(id) {
            activePens.insert(id)
            openProximity(x: nx, y: ny)
            emitPencil("down", x: nx, y: ny, pressure: pressure,
                       azimuth: azimuth, altitude: altitude)
            return
        }

        if !ended {
            for c in event?.samples(for: touch) ?? [touch] {
                guard let cn = normalize?(c.location(in: view)) else { continue }
                emitPencil("move", x: cn.x, y: cn.y,
                           pressure: min(Double(c.force), 1.0),
                           azimuth: Double(c.azimuthAngle(in: view)),
                           altitude: Double(c.altitudeAngle))
            }
            return
        }

        defer { activePens.remove(id) }
        emitPencil("up", x: nx, y: ny, pressure: 0,
                   azimuth: azimuth, altitude: altitude)
        closeProximity(x: nx, y: ny)
    }

    private func emitPencil(_ phase: String, x: Double, y: Double,
                            pressure: Double, azimuth: Double, altitude: Double) {
        onPencil?(phase, x, y, pressure, azimuth, altitude)
    }
}
