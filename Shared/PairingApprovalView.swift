import SwiftUI

struct PairingApprovalPresenter: ViewModifier {
    @ObservedObject var pairing = PairingApprovalCoordinator.shared
    func body(content: Content) -> some View {
        content.overlay {
            if let prompt = pairing.prompt {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 18) {
                        Label("Pair with \(prompt.name)", systemImage: "lock.shield")
                            .font(.title2.bold())
                        Text("Confirm that this code matches the code on the other device.")
                            .multilineTextAlignment(.center)
                        Text(prompt.code).font(.system(size: 36, weight: .semibold, design: .monospaced))
                            .accessibilityLabel("Pairing code " + prompt.code.map(String.init).joined(separator: " "))
                        Text(pairing.status).font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            Button("Cancel", role: .cancel) { pairing.cancel() }
                            Spacer()
                            Button("Codes match") { pairing.approve() }.buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(24).frame(maxWidth: 400)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                    .padding(24)
                    .accessibilityAddTraits(.isModal)
                }
            }
        }
    }
}
