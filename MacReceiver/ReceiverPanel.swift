import SwiftUI

// MARK: - Receiver panel (issues #82/#17)

/// The receiver-mode sections of the panel: live status, the advertised
/// name, and how-to copy, grouped into the Duo Display card layout.
struct ReceiverSections: View {
    @ObservedObject var controller: ReceiverController
    @AppStorage("showAnalytics") private var showAnalytics = false

    var body: some View {
        // The receiver exists only while receiver mode is on; observed in a
        // subview because nested ObservableObjects don't republish.
        if let receiver = controller.receiver {
            ReceiverStatusSection(receiver: receiver, controller: controller)
        }

        DuoMacCard("This Mac’s name", symbol: "desktopcomputer") {
            ReceiverNameField { controller.setAdvertisedName($0) }
                .textFieldStyle(.roundedBorder)
            Text("Shown in the other Mac’s Devices list.")
                .font(.caption).foregroundStyle(.secondary)
        }

        DuoMacCard("While streaming", symbol: "waveform.path.ecg") {
            Toggle("Performance overlay", isOn: $showAnalytics)
                .toggleStyle(.switch)
            Text("Show FPS, bitrate, frame timing, and latency graphs at the bottom of the video window.")
                .font(.caption).foregroundStyle(.secondary)
        }

        DuoMacCard("Three steps to more room", symbol: "point.3.connected.trianglepath.dotted") {
            Label("Open Duo Display on the Mac you want to extend.", systemImage: "1.circle")
            Label("Join the same network, then choose this Mac and click Connect.", systemImage: "2.circle")
            Label("Use the green window button here for full screen.", systemImage: "3.circle")
        }
        .font(.subheadline)
    }
}

/// Live state of the running receiver: connection, stream format, and any
/// compatibility signal from the connected Mac.
private struct ReceiverStatusSection: View {
    @ObservedObject var receiver: StreamReceiver
    let controller: ReceiverController

    var body: some View {
        DuoMacCard("Connection", symbol: "antenna.radiowaves.left.and.right") {
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(receiver.connected ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(receiver.connected ? "Connected" : "Waiting for a computer…")
                    // The port matters on a Mac (firewall prompts), so the
                    // idle caption names it instead of repeating the status.
                    Text(receiver.connected || receiver.status != "Ready to connect"
                         ? receiver.status : "Listening on port 9000")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if controller.streaming {
                    Button("Show Window") { controller.showWindow() }
                        .controlSize(.small)
                        .help("Bring the video window back if you closed it — the stream keeps running either way.")
                }
            }
            if receiver.videoSize != .zero {
                // Not LabeledContent: that is macOS 13, the app runs on 12.
                HStack {
                    Text("Stream")
                    Spacer()
                    Text("\(Int(receiver.videoSize.width))×\(Int(receiver.videoSize.height)) @ \(receiver.fps) fps")
                        .foregroundColor(.secondary)
                }
            }
            if let message = peerMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Compatibility copy from the sender (issue #132) — surfaced inline;
    /// update guidance stays inline rather than interrupting the stream.
    private var peerMessage: String? {
        switch receiver.peerSignal {
        case let .updateReceiver(message, _): return duoMessage(message)
        case let .updateMac(message): return duoMessage(message)
        case nil: return nil
        }
    }

    private func duoMessage(_ message: String) -> String {
        message.replacingOccurrences(of: "OpenDisplay", with: "Duo Display", options: .caseInsensitive)
            .replacingOccurrences(of: "Open Display", with: "Duo Display", options: .caseInsensitive)
    }
}

/// The advertised-name editor — kept out of any high-frequency observed
/// object so streaming updates can't rebuild it mid-edit (same reasoning as
/// the iOS DeviceNameField).
private struct ReceiverNameField: View {
    @AppStorage("receiverName") private var name = Host.current().localizedName ?? "Mac"
    let onChange: (String) -> Void

    var body: some View {
        TextField("Name", text: $name)
            // The single-value onChange: the two-value form is macOS 14.
            .onChange(of: name, perform: onChange)
    }
}
