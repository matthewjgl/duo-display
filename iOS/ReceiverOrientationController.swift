import UIKit
import SwiftUI

final class DuoPhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ReceiverOrientation.load().mask
    }
}

extension ReceiverOrientation {
    var mask: UIInterfaceOrientationMask {
        switch self {
        case .automatic: return .all
        case .portrait: return .portrait
        case .landscape: return .landscape
        }
    }
}

@MainActor
final class ReceiverOrientationController: ObservableObject {
    static let shared = ReceiverOrientationController()
    @Published private(set) var guidance: String?

    func apply() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) else {
            guidance = "Open Duo Display full screen, then retry orientation."; return
        }
        guard #available(iOS 16.0, *) else {
            // Never force KVC device orientation. Older iOS follows physical
            // rotation; touch coordinates continue to use actual panel geometry.
            guidance = "On iOS 15, rotate the phone and check system rotation lock. The saved preference takes effect on the next supported presentation."
            UIViewController.attemptRotationToDeviceOrientation()
            return
        }
        guidance = nil
        scene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: ReceiverOrientation.load().mask)) { [weak self] _ in
            Task { @MainActor in
                self?.guidance = "iOS could not apply this orientation in the current window. Try full screen or rotate the device. Video and touch continue to follow the actual window."
            }
        }
    }
}

struct ReceiverOrientationPicker: View {
    @AppStorage(ReceiverOrientation.defaultsKey) private var saved = ReceiverOrientation.automatic.rawValue
    @ObservedObject private var controller = ReceiverOrientationController.shared
    var body: some View {
        Picker("Orientation", selection: $saved) {
            ForEach(ReceiverOrientation.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
        }
        if let guidance = controller.guidance {
            Text(guidance).font(.footnote).foregroundStyle(.secondary)
            Button("Retry orientation") { controller.apply() }
        }
    }
}
