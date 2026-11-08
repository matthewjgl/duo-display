import Foundation

/// Install IDs are routing continuity hints, not cryptographic credentials.
/// Never infer permission to change transports from a human-readable name.
enum DeviceIdentity {
    static func valid(_ id: String?) -> String? {
        guard let id, !id.isEmpty, id.count <= 256,
              id == id.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return id
    }

    static func helloID(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "hello",
              let info = try? JSONDecoder().decode(PhoneInfo.self, from: data) else { return nil }
        return valid(info.id)
    }

    static func matches(_ first: String?, _ second: String?) -> Bool {
        guard let first = valid(first), let second = valid(second) else { return false }
        return first == second
    }
}

struct PeerIdentityGate {
    private(set) var pinnedID: String?
    init(expected: String? = nil) { pinnedID = DeviceIdentity.valid(expected) }

    mutating func accept(_ id: String?) -> Bool {
        if let pinnedID { return DeviceIdentity.matches(pinnedID, id) }
        pinnedID = DeviceIdentity.valid(id)
        return true // Explicit initial connections remain compatible with legacy receivers.
    }
}

/// Small, versioned local preference record. Existing scaling/arrangement keys
/// stay authoritative; no bulk migration or deletion of earlier preferences.
enum DeviceSetupStore {
    struct Record: Codable, Equatable {
        var schema = 1
        var quality: String?
        var wirelessAllowed = false
        var reconnectAtLaunch = false
    }
    static func key(_ id: String) -> String { "duo.deviceSetup.v1." + id }
    static func hasRecord(_ id: String?, in defaults: UserDefaults = .standard) -> Bool {
        guard let id = DeviceIdentity.valid(id) else { return false }
        return defaults.object(forKey: key(id)) != nil
    }
    static func load(_ id: String?, from defaults: UserDefaults = .standard) -> Record {
        guard let id = DeviceIdentity.valid(id), let data = defaults.data(forKey: key(id)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.schema == 1 else { return Record() }
        return record
    }
    @discardableResult
    static func update(_ id: String?, in defaults: UserDefaults = .standard,
                       _ edit: (inout Record) -> Void) -> Bool {
        guard let id = DeviceIdentity.valid(id) else { return false }
        if let data = defaults.data(forKey: key(id)),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let schema = object["schema"] as? Int, schema != 1 { return false }
        var record = load(id, from: defaults)
        edit(&record)
        guard let data = try? JSONEncoder().encode(record) else { return false }
        defaults.set(data, forKey: key(id))
        return true
    }
    static func quality(_ id: String?, fallback: StreamQuality,
                        from defaults: UserDefaults = .standard) -> StreamQuality {
        load(id, from: defaults).quality.flatMap(StreamQuality.init(rawValue:)) ?? fallback
    }
}

/// The complete automatic wireless selection rule, independent of Bonjour APIs.
enum AutomaticHandoff {
    static func wirelessIndex(expectedID: String?, advertisedIDs: [String?], allowed: Bool) -> Int? {
        guard allowed, DeviceIdentity.valid(expectedID) != nil else { return nil }
        let matches = advertisedIDs.indices.filter { DeviceIdentity.matches(expectedID, advertisedIDs[$0]) }
        return matches.count == 1 ? matches[0] : nil
    }
}
