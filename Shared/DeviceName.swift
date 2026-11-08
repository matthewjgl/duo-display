import Foundation

/// Device-name rules shared by the receivers (what to announce) and the
/// sender (what to show). Pure functions: no UIKit, no UserDefaults.
///
/// Apple only hands an app the user-assigned name ("Ana's iPhone") from
/// `UIDevice.current.name` on iOS 15 and earlier, or when the app holds the
/// `com.apple.developer.device-information.user-assigned-device-name`
/// entitlement, which Apple grants on request. Without it iOS 16+ returns
/// the model ("iPhone"). Nothing here assumes either case: a name that is just
/// a model or a placeholder is "generic" and never wins over a real one.
enum DeviceNameText {
    /// Longest name kept, in user-perceived characters (grapheme clusters).
    static let maxCharacters = 64
    /// Bonjour service names are at most 63 bytes of UTF-8.
    static let maxServiceNameBytes = 63
    /// TXT values ride in a 255-byte key=value string.
    static let maxTXTBytes = 200

    /// Trimmed, single-line and length-capped, or nil when nothing is left.
    /// Control characters and line breaks become spaces and runs of
    /// whitespace collapse; format characters (the joiners inside emoji
    /// sequences, direction marks) are kept so Unicode names survive intact.
    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            scalars.append(scalar.properties.generalCategory == .control ? " " : scalar)
        }
        let words = String(scalars).components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        let joined = words.joined(separator: " ")
        guard joined.count > maxCharacters else { return joined }
        return String(joined.prefix(maxCharacters)).trimmingCharacters(in: .whitespaces)
    }

    /// The longest prefix that fits in `maxBytes` of UTF-8 without splitting
    /// a character.
    static func truncated(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > maxBytes { break }
            result.append(character)
            used += size
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Placeholders that say nothing about which device this is: a bare
    /// model, the app's own name, or the sender's fallbacks. A Bonjour
    /// conflict suffix ("iPhone (2)") is still generic.
    static func isGeneric(_ name: String?, kind: String? = nil) -> Bool {
        guard let name = clean(name) else { return true }
        var base = name.lowercased()
        if let range = base.range(of: #" \(\d+\)$"#, options: .regularExpression) {
            base.removeSubrange(range)
        }
        if let kind = clean(kind)?.lowercased(), base == kind { return true }
        return genericNames.contains(base)
    }

    private static let genericNames: Set<String> = [
        "iphone", "ipad", "ipod", "ipod touch", "mac", "android", "android device",
        "device", "duo display", "opendisplay", "iphone / ipad", "wifi device",
        "wi-fi device", "localhost", "unknown",
    ]

    /// Two names a person would read as the same.
    static func sameForDisplay(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
    }
}

/// Where a receiver's announced name came from (`hello.nameSource`, TXT `ns`).
enum DeviceNameSource: String {
    /// Typed into the receiver app's own settings.
    case app
    /// The operating system's user-assigned device name.
    case device
    /// Only a model / placeholder was available: the sender should forget
    /// any name this device announced earlier and use its own sources.
    case generic
}

/// What a receiver announces as its name. The app's own setting wins, then a
/// personalized system name; otherwise the model, flagged as generic.
enum DeviceNameAnnouncement {
    static func choose(appName: String?, systemName: String?, model: String)
        -> (name: String, source: DeviceNameSource) {
        if let app = DeviceNameText.clean(appName), !DeviceNameText.isGeneric(app, kind: model) {
            return (app, .app)
        }
        if let system = DeviceNameText.clean(systemName),
           !DeviceNameText.isGeneric(system, kind: model) {
            return (system, .device)
        }
        return (DeviceNameText.clean(appName) ?? DeviceNameText.clean(systemName) ?? model, .generic)
    }
}
