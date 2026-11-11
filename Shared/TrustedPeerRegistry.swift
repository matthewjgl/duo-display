import Foundation

/// Names are presentation metadata. Only the Keychain peer key grants trust.
enum TrustedPeerRegistry {
    struct Record: Identifiable, Equatable {
        let id: String
        let name: String
    }
    static func records(peers: [String], defaults: UserDefaults = .standard) -> [Record] {
        let names = defaults.dictionary(forKey: "duo.securePeerNames.v1") as? [String: String] ?? [:]
        return peers.sorted().map { Record(id: $0, name: names[$0] ?? "Paired device (\($0.prefix(6)))") }
    }
    static func rememberName(_ name: String, peer: String, defaults: UserDefaults = .standard) {
        var names = defaults.dictionary(forKey: "duo.securePeerNames.v1") as? [String: String] ?? [:]
        names[peer] = DeviceNameText.truncated(DeviceNameText.clean(name) ?? "Paired device", maxBytes: 128)
        defaults.set(names, forKey: "duo.securePeerNames.v1")
    }
    static func isRevoked(_ peer: String, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: "duo.revokedPeers.v1") ?? []).contains(peer)
    }
    static func markRevoked(_ peer: String, defaults: UserDefaults = .standard) {
        var revoked = Set(defaults.stringArray(forKey: "duo.revokedPeers.v1") ?? [])
        revoked.insert(peer); defaults.set(Array(revoked), forKey: "duo.revokedPeers.v1")
        defaults.set((defaults.stringArray(forKey: "duo.securePeers.v1") ?? []).filter { $0 != peer }, forKey: "duo.securePeers.v1")
        var names = defaults.dictionary(forKey: "duo.securePeerNames.v1") as? [String: String] ?? [:]
        names.removeValue(forKey: peer); defaults.set(names, forKey: "duo.securePeerNames.v1")
    }
    static func approvedAgain(_ peer: String, defaults: UserDefaults = .standard) {
        defaults.set((defaults.stringArray(forKey: "duo.revokedPeers.v1") ?? []).filter { $0 != peer }, forKey: "duo.revokedPeers.v1")
    }
}
