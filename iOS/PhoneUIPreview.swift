#if DEBUG
import SwiftUI
import AVFoundation
import CryptoKit

/// Isolated simulator fixture. This host never starts listeners, connects to a
/// Mac, posts input, changes display arrangements, or persists a pairing key.
struct PhoneUIPreviewHost:View {
    let scene:String
    @StateObject private var receiver = StreamReceiver(displayLayer:AVSampleBufferDisplayLayer(),deviceKind:"iPhone",fallbackServiceName:"UI Preview")
    @StateObject private var pairing = PairingApprovalCoordinator(ownID:"preview-phone",save:{_,_ in throw SecurePairingKeyStore.StoreError.invalidPeer})
    @State private var showing = true
    var body:some View {
        Color(.systemGroupedBackground).ignoresSafeArea()
            .overlay { Text("SideExtend UI preview\nNo live connection").multilineTextAlignment(.center).foregroundStyle(.secondary) }
            .sheet(isPresented:Binding(get:{showing && scene != "settings"},set:{showing = $0})) {
                if scene == "welcome" { OnboardingView(onClose:{showing = false}) }
                else if scene == "pairing" { PhonePairingSheet(pairing:pairing) }
                else if scene == "arrangement" { AdaptiveNavigation { PhoneArrangementView(receiver:receiver) } }
                else { SettingsView(receiver:receiver,openKeyboard:{showing = false}) }
            }
            .fullScreenCover(isPresented:Binding(get:{showing && scene == "settings"},set:{showing = $0})) {
                SettingsView(receiver:receiver,openKeyboard:{showing = false})
            }
            .onAppear {
                receiver.debugGoOffline();receiver.debugConfigureUIControls()
                if scene == "pairing" {
                    try? pairing.begin(peerID:"preview-mac",name:"Matthew’s MacBook Pro",material:.init(key:SymmetricKey(data:Data(repeating:1,count:32)),verificationCode:"417829"))
                }
            }
    }
}
#endif
