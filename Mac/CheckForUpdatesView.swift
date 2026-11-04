import SwiftUI
import Sparkle

/// "Check for Updates…" button wired to Sparkle. Follows Sparkle 2's
/// documented SwiftUI pattern: a small view model publishes the updater's
/// `canCheckForUpdates` so the button disables itself while a check is
/// already running (or the updater isn't ready). Shared by the sender and
/// the receiver app.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUStandardUpdaterController) {
        self.updater = updater.updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater.updater)
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .controlSize(.small)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

/// One connected device: live status, throughput, reconnect + disconnect.

/// Compact navigation keeps the device list separate from persistent preferences.
enum DuoMacPage: String, CaseIterable, Identifiable {
    case devices = "Devices", picture = "Picture", app = "App settings", permissions = "Permissions"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .devices: return "rectangle.on.rectangle"
        case .picture: return "display"
        case .app: return "slider.horizontal.3"
        case .permissions: return "lock.shield"
        }
    }
    var subtitle: String {
        switch self {
        case .devices: return "Your screens, together."
        case .picture: return "Choose how your extra screen looks."
        case .app: return "Set up your everyday workflow."
        case .permissions: return "Everything your connection needs."
        }
    }
}

struct DuoMacCard<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content
    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
}
