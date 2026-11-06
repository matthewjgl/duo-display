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
    case devices = "Displays", picture = "Streaming", app = "Preferences", permissions = "Permissions"
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
        case .devices: return "Connect a device. Make room for what’s next."
        case .picture: return "Fine-tune your connected displays."
        case .app: return "Make Duo Display fit your workflow."
        case .permissions: return "Allow capture and control, with clear access status."
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
            .fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
}


enum DuoMacTheme {
    static let accent = Color(nsColor: .systemBlue)
}

struct DuoMacStatusPill: View {
    let title: String
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.09)))
        .accessibilityElement(children: .combine)
    }
}

struct DuoWorkspaceOverview: View {
    let connected: Bool
    let extended: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("Display overview", systemImage: "rectangle.3.group")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(connected ? (extended ? "Extended desktop" : "Mirrored desktop") : "Waiting for a device")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .center, spacing: 24) {
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    Image(systemName: "laptopcomputer").font(.system(size: 56, weight: .ultraLight))
                    Text("This Mac").font(.caption.weight(.medium))
                }
                Image(systemName: connected ? "link" : "plus")
                    .font(.system(size: 19, weight: .light)).foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    Image(systemName: "ipad.landscape").font(.system(size: 45, weight: .ultraLight))
                    Text(connected ? "Your second screen" : "Your next screen").font(.caption.weight(.medium))
                }
                .foregroundStyle(connected ? DuoMacTheme.accent : Color.secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        }
        .padding(20).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(DuoMacTheme.accent.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DuoMacTheme.accent.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }
}
