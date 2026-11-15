import SwiftUI

struct PhoneArrangementView: View {
    @ObservedObject var receiver: StreamReceiver
    @Environment(\.scenePhase) private var scenePhase
    @State private var placement: PhoneDisplayPlacement?
    @State private var previewRevision: String?
    private var report: PhoneArrangementReport? { receiver.phoneArrangement }
    private var proposed: PhoneDisplayTopology? {
        guard let report,let target = report.target,let placement,let origin = PhoneArrangementGeometry.origin(placement,topology:report.topology,target:target) else { return nil }
        return report.topology.placing(target,at:origin)
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                if let report {
                    Text(placement == nil ? "Current layout" : "Preview — not applied").font(.headline)
                    ArrangementLayoutPreview(topology:proposed ?? report.topology,target:report.target)
                        .frame(height:240)
                    Text("Blue identifies this iPhone. The top bar marks the main display.").font(.caption).foregroundStyle(.secondary)
                    if let reason = report.unavailable {
                        Label(reason,systemImage:"info.circle").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("Place this iPhone beside your Mac’s main display.").font(.subheadline).foregroundStyle(.secondary)
                        LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:12) {
                            ForEach(PhoneDisplayPlacement.allCases,id: \.self) { side in
                                let available = report.target.flatMap { PhoneArrangementGeometry.origin(side,topology:report.topology,target:$0) } != nil
                                Button {
                                    placement = side; previewRevision = report.revision
                                } label: {
                                    Label(side.title,systemImage:side.symbol).frame(maxWidth:.infinity,minHeight:44)
                                }.buttonStyle(.bordered)
                                    .tint(placement == side ? .accentColor : .secondary)
                                    .disabled(!available || receiver.arrangementPending || report.busy)
                                    .accessibilityHint(available ? "Preview this placement before applying" : "This edge is occupied or would separate another display")
                            }
                        }
                        if PhoneDisplayPlacement.allCases.contains(where:{ side in report.target.flatMap{PhoneArrangementGeometry.origin(side,topology:report.topology,target:$0)} == nil }) {
                            Text("Unavailable edges would overlap or separate another display.").font(.caption).foregroundStyle(.secondary)
                        }
                        Button {
                            guard let placement,let previewRevision else { return }
                            receiver.arrangePhone(placement,revision:previewRevision)
                        } label: {
                            HStack { if receiver.arrangementPending || report.busy { ProgressView() };Text(receiver.arrangementPending || report.busy ? "Applying…" : "Apply placement") }
                                .frame(maxWidth:.infinity,minHeight:44)
                        }.buttonStyle(.borderedProminent)
                            .disabled(proposed == nil || proposed == report.topology || previewRevision != report.revision || receiver.arrangementPending || report.busy || !receiver.connected)
                        Button { receiver.arrangePhone(undo:true,revision:report.revision) } label: {
                            Label("Undo last arrangement",systemImage:"arrow.uturn.backward").frame(maxWidth:.infinity,minHeight:44)
                        }.buttonStyle(.bordered)
                            .disabled(!report.canUndo || receiver.arrangementPending || report.busy || !receiver.connected)
                    }
                    if let message = report.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    if let diagnostic = report.diagnostic {
                        DisclosureGroup("Diagnostics") { Text(diagnostic).font(.caption.monospaced()).textSelection(.enabled) }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if !receiver.connected {
                    Label("Not connected",systemImage:"display.trianglebadge.exclamationmark")
                } else if !receiver.macSupportsArrangement {
                    Text("Update and securely pair the Mac app to arrange this extended display.")
                } else {
                    ProgressView("Reading Mac display layout…").frame(maxWidth:.infinity)
                }
                if let error = receiver.arrangementError { Label(error,systemImage:"exclamationmark.circle").font(.footnote).foregroundStyle(.orange) }
                if !receiver.connected { Text("Reconnect to arrange your iPhone’s extended display.").font(.footnote) }
                Button("Refresh layout") { placement = nil; previewRevision = nil; receiver.watchPhoneArrangement(true) }
                    .disabled(!receiver.connected || !receiver.macSupportsArrangement || receiver.arrangementPending || report?.busy == true)
                Text("Other displays and the primary display stay in place. macOS may briefly fade the screens while applying. Undo expires if the display topology changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth:600).frame(maxWidth:.infinity)
        }
        .navigationTitle("Arrange Displays").navigationBarTitleDisplayMode(.inline)
        .onAppear { receiver.watchPhoneArrangement(true) }
        .onDisappear { receiver.watchPhoneArrangement(false) }
        .onChange(of: report?.revision) { _ in placement = nil; previewRevision = nil }
        .onChange(of: receiver.connected) { _ in placement = nil; previewRevision = nil }
        .onChange(of: scenePhase) { phase in
            if phase == .active { receiver.watchPhoneArrangement(true) }
            else if phase == .background { receiver.watchPhoneArrangement(false) }
        }
        .onChange(of: receiver.macSupportsArrangement) { ready in if ready && receiver.connected { receiver.watchPhoneArrangement(true) } }
    }
}
