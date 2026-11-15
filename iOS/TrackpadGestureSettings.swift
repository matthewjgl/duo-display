import SwiftUI
import UIKit

/// Public UIKit feedback only; UIKit may suppress it on unsupported devices or
/// under system restrictions. Input is submitted first, haptics never gate it.
@MainActor enum PhoneHaptics {
    private static var light = UIImpactFeedbackGenerator(style:.light)
    private static var medium = UIImpactFeedbackGenerator(style:.medium)
    private static var strong = UIImpactFeedbackGenerator(style:.heavy)
    private static var hold = UIImpactFeedbackGenerator(style:.rigid)
    static func emit(_ feedback:PhoneInputFeedback) {
        let level = PhoneHapticLevel.load();guard let intensity = PhoneHapticPolicy.intensity(level),UIApplication.shared.applicationState == .active else { return }
        if feedback == .hold { // Distinct confirmation only when a hold engages.
            // Use a different public impact style, with intensity set by preference.
            hold.impactOccurred(intensity:intensity)
        } else {
            switch level {
            case .off:break
            case .light:light.impactOccurred(intensity:0.45)
            case .standard:medium.impactOccurred(intensity:0.75)
            case .strong:strong.impactOccurred(intensity:1)
            }
        }
    }
}
struct TrackpadGestureSettings:View {
    @ObservedObject var receiver:StreamReceiver
    @State private var preferences = TrackpadGesturePreferences.load()
    var body:some View {
        Form {
            Section {
                Toggle("Enable shortcut gestures",isOn:$preferences.enabled)
                    .disabled(!receiver.macSupportsShortcutGestures || receiver.gestureProfileID == nil)
                Text("These send keyboard shortcuts, not native trackpad animations. Review each shortcut against this Mac’s Keyboard Shortcuts settings before enabling. System settings are never changed.")
                    .font(.footnote).foregroundStyle(.secondary)
                if !receiver.macSupportsShortcutGestures { Text("Connect to the matching updated Mac app to use shortcut gestures.").font(.footnote) }
                if receiver.gestureProfileID == nil { Text("Pair and connect over Wi-Fi to review shortcuts for this specific Mac. USB pointer, clicks and scrolling remain available.").font(.footnote) }
            }
            ForEach([3,4],id:\.self) { count in
                Section("\(count)-finger swipes") {
                    ForEach(TrackpadSwipeDirection.allCases,id:\.self) { direction in
                        Picker(direction.rawValue.capitalized,selection:Binding(get:{preferences.mappings["\(count).\(direction.rawValue)"] ?? .none},set:{preferences.mappings["\(count).\(direction.rawValue)"] = $0})) {
                            ForEach(TrackpadSystemAction.allCases,id:\.self) { action in Text(action.title).tag(action) }
                        }
                    }
                }
            }
            Section("Shortcut mappings") {
                ForEach(TrackpadSystemAction.allCases.filter{$0 != .none},id:\.self) { action in
                    NavigationLink(action.title) { ShortcutEditor(action:action,preferences:$preferences) }
                }
                Text("Four-finger left/right and up are suggested; three-finger actions and App Exposé start off. Change finger counts and directions above. A disabled or conflicting global shortcut cannot be overridden here.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Limitations") {
                Text("Use deliberate swipes away from screen edges. Lift all fingers before the next gesture. iOS may reserve three-finger editing gestures or edge swipes and cancel delivery; SideExtend does not bypass them. Pinch, spread, force-click and continuous Space animations are not synthesized.")
                    .font(.footnote)
            }
            if let status = receiver.gestureStatus { Section { Text(status).font(.footnote) } }
            DisclosureGroup("Input diagnostics") { Text(receiver.trackpadTimingSummary).font(.caption) }
        }
        .navigationTitle("Trackpad gestures")
        .onAppear { preferences = TrackpadGesturePreferences.load(scope:receiver.gestureProfileID) }
        .onChange(of:receiver.gestureProfileID) { _ in preferences = TrackpadGesturePreferences.load(scope:receiver.gestureProfileID) }
        .onChange(of:preferences) { value in receiver.resetInputs();if let scope = receiver.gestureProfileID { value.save(scope:scope) } }
    }
}
private struct ShortcutEditor:View {
    let action:TrackpadSystemAction
    @Binding var preferences:TrackpadGesturePreferences
    private var chord:TrackpadShortcut { preferences.shortcuts[action.rawValue] ?? .init(key:126,modifiers:TrackpadShortcut.control) }
    private func flag(_ flag:UInt64) -> Binding<Bool> {
        Binding(get:{chord.modifiers & flag != 0},set:{on in var value = chord;value.modifiers = on ? value.modifiers|flag : value.modifiers & ~flag;preferences.shortcuts[action.rawValue] = value})
    }
    var body:some View {
        Form {
            Picker("Key",selection:Binding(get:{chord.key},set:{var value = chord;value.key = $0;preferences.shortcuts[action.rawValue] = value})) {
                ForEach(TrackpadShortcut.keys.keys.sorted(),id:\.self) { key in Text(TrackpadShortcut.keys[key]!).tag(key) }
            }
            Toggle("Control ⌃",isOn:flag(TrackpadShortcut.control))
            Toggle("Option ⌥",isOn:flag(TrackpadShortcut.option))
            Toggle("Shift ⇧",isOn:flag(TrackpadShortcut.shift))
            Toggle("Command ⌘",isOn:flag(TrackpadShortcut.command))
            Text("Match the enabled shortcut in Mac System Settings → Keyboard → Keyboard Shortcuts → Mission Control. Arrow, Space, Tab and Escape mappings require a modifier. No shortcut is changed on your Mac.").font(.footnote)
            if !chord.valid { Text("Choose a modifier or a supported function key.").foregroundStyle(.orange) }
        }.navigationTitle(action.title)
    }
}
