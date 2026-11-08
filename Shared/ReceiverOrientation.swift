import Foundation

/// Stored on the receiver installation (its stable device identity), not under
/// its editable Bonjour name. No preference means existing automatic behavior.
enum ReceiverOrientation: String, CaseIterable {
    case automatic, portrait, landscape
    static let defaultsKey = "duo.receiverOrientation.v1"
    var title: String {
        switch self {
        case .automatic: return "Follow device"
        case .portrait: return "Portrait"
        case .landscape: return "Landscape"
        }
    }
    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .automatic
    }
}
