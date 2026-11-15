import SwiftUI

struct PhonePairingSheet:View {
    @ObservedObject var pairing:PairingApprovalCoordinator
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.verticalSizeClass) private var verticalSize
    var body:some View {
        AdaptiveNavigation {
            Group {
                if let prompt = pairing.prompt {
                    PhonePairingContent(name:prompt.name,code:prompt.code,approved:pairing.localApproved,
                        approve:{pairing.approve()},cancel:{pairing.cancel()})
                } else { ProgressView("Finishing pairing…") }
            }.navigationTitle("Pair your Mac").navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(pairing.localApproved)
        .modifier(PairingSheetSize(expanded:textSize.isAccessibilitySize || verticalSize == .compact))
    }
}
private struct PairingSheetSize:ViewModifier {
    let expanded:Bool
    @ViewBuilder func body(content:Content) -> some View {
        if #available(iOS 16,*) { content.presentationDetents(expanded ? [.large] : [.medium,.large]) }
        else { content }
    }
}
