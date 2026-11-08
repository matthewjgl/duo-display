import Foundation
import Security
import CryptoKit

/// Peer secrets stay local to this installation. Call only after both sides
/// explicitly approve the matching verification code; legacy device IDs alone
/// never authorize saving a key.
enum SecurePairingKeyStore {
    private static let service = "com.matthewjgl.duodisplay.paired-peers.v1"
    enum StoreError: Error { case invalidPeer, invalidKey, keychain(OSStatus) }

    private static func query(peerID: String) throws -> [String: Any] {
        guard !peerID.isEmpty, peerID.utf8.count <= 256 else { throw StoreError.invalidPeer }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: peerID]
    }

    static func save(_ key: SymmetricKey, peerID: String) throws {
        let bytes = key.withUnsafeBytes { Data($0) }
        guard bytes.count == 32 else { throw StoreError.invalidKey }
        let base = try query(peerID: peerID)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if status == errSecSuccess { remember(peerID); return }
        guard status == errSecItemNotFound else { throw StoreError.keychain(status) }
        var item = base
        item[kSecValueData as String] = bytes
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw StoreError.keychain(added) }
        remember(peerID)
    }

    private static func remember(_ peer: String) {
        var peers = Set(UserDefaults.standard.stringArray(forKey: "duo.securePeers.v1") ?? [])
        peers.insert(peer)
        UserDefaults.standard.set(Array(peers), forKey: "duo.securePeers.v1")
        NotificationCenter.default.post(name: .init("DuoPairSaved"), object: nil)
    }

    static func load(peerID: String) throws -> SymmetricKey? {
        var item = try query(peerID: peerID)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        guard let data = result as? Data, data.count == 32 else { throw StoreError.invalidKey }
        return SymmetricKey(data: data)
    }

    static func remove(peerID: String) throws {
        let status = SecItemDelete(try query(peerID: peerID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.keychain(status) }
    }
}
