import Foundation

/// The identity a device's name is stored under. The receiver's install id
/// is the paired-device identity that already survives USB/Wi-Fi switching;
/// a cabled device that has not announced one yet falls back to its USB
/// hardware serial, and the record moves to the install id once it is learned
/// (`DeviceNameStore.adopt`). Never an IP address, a Bonjour service name, a
/// display name or a position in a list.
enum DeviceNameKey {
    static let usbPrefix = "usb:"

    static func make(installID: String?, udid: String?) -> String? {
        if let id = DeviceIdentity.valid(installID) { return id }
        guard let udid = DeviceIdentity.valid(udid) else { return nil }
        return usbPrefix + udid
    }

    /// A short, stable code that tells apart devices with the same name.
    static func shortCode(_ key: String, length: Int = 4) -> String {
        let body = key.hasPrefix(usbPrefix) ? String(key.dropFirst(usbPrefix.count)) : key
        let characters = body.uppercased().filter { $0.isLetter || $0.isNumber }
        return String(characters.suffix(length))
    }
}

/// Per-device names, persisted on the Mac. Separate from `DeviceSetupStore`
/// so renaming never touches quality, wireless or reconnect settings.
enum DeviceNameStore {
    struct Record: Codable, Equatable {
        var schema = 1
        /// The user's name for this device, set on this Mac. Wins over all else.
        var customName: String?
        /// What the device announced about itself (hello `name` or TXT `n`).
        var reportedName: String?
        /// `DeviceNameSource` raw value, or "service" for an older receiver's
        /// Bonjour service name.
        var reportedSource: String?
        /// The name usbmuxd's lockdown service reports over the cable: the one
        /// from Settings > General > About > Name.
        var cableName: String?
        /// "iPhone" / "iPad" / "Mac" from the hello.
        var kind: String?
        var lastSeen: Date?
    }

    static let prefix = "duo.deviceName.v1."
    static func key(_ id: String) -> String { prefix + id }

    static func hasRecord(_ id: String?, in defaults: UserDefaults = .standard) -> Bool {
        guard let id else { return false }
        return defaults.object(forKey: key(id)) != nil
    }

    static func load(_ id: String?, from defaults: UserDefaults = .standard) -> Record? {
        guard let id, let data = defaults.data(forKey: key(id)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.schema == 1 else { return nil }
        return record
    }

    /// Applies `edit` and writes only when something changed. Returns whether
    /// the stored record changed. A record from a newer schema is left alone.
    @discardableResult
    static func update(_ id: String?, in defaults: UserDefaults = .standard,
                       createIfMissing: Bool = true, _ edit: (inout Record) -> Void) -> Bool {
        guard let id else { return false }
        if let data = defaults.data(forKey: key(id)),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let schema = object["schema"] as? Int, schema != 1 { return false }
        let existing = load(id, from: defaults)
        guard existing != nil || createIfMissing else { return false }
        var record = existing ?? Record()
        edit(&record)
        guard record != existing, let data = try? JSONEncoder().encode(record) else { return false }
        defaults.set(data, forKey: key(id))
        return true
    }

    static func remove(_ id: String, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(id))
    }

    /// Every stored device, for the list of remembered devices.
    static func allIDs(in defaults: UserDefaults = .standard) -> [String] {
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .sorted()
    }

    /// A USB-keyed record (renamed before the device announced an install id)
    /// joins the install-id record. Facts the install-id record already holds
    /// win; the custom name carries over unless one was set there too.
    @discardableResult
    static func adopt(udid: String, into installID: String,
                      in defaults: UserDefaults = .standard) -> Bool {
        guard let id = DeviceIdentity.valid(installID),
              let legacyKey = DeviceNameKey.make(installID: nil, udid: udid),
              let legacy = load(legacyKey, from: defaults) else { return false }
        update(id, in: defaults) { record in
            record.customName = record.customName ?? legacy.customName
            record.cableName = record.cableName ?? legacy.cableName
            record.reportedName = record.reportedName ?? legacy.reportedName
            record.reportedSource = record.reportedSource ?? legacy.reportedSource
            record.kind = record.kind ?? legacy.kind
            record.lastSeen = [record.lastSeen, legacy.lastSeen].compactMap { $0 }.max()
        }
        remove(legacyKey, in: defaults)
        return true
    }

    // MARK: - Writes from the sources

    /// The user renamed the device. Blank or whitespace input is rejected
    /// (returns false); use `resetCustomName` to go back to automatic. A name
    /// identical to the automatic one is stored as "no custom name", so later
    /// automatic updates keep flowing in.
    @discardableResult
    static func setCustomName(_ raw: String, for id: String?,
                              in defaults: UserDefaults = .standard) -> Bool {
        guard let id, let name = DeviceNameText.clean(raw) else { return false }
        update(id, in: defaults) { record in
            let automatic = DeviceNaming.automaticName(record)
            record.customName = automatic == name ? nil : name
            if record.lastSeen == nil { record.lastSeen = Date() }
        }
        return true
    }

    static func resetCustomName(for id: String?, in defaults: UserDefaults = .standard) {
        update(id, in: defaults, createIfMissing: false) { $0.customName = nil }
    }

    /// The device's own announcement (hello or TXT). `source` nil means an
    /// older receiver that does not say where its name came from: only a
    /// non-generic Bonjour service name is worth keeping then.
    static func applyReported(_ raw: String?, source: String?, kind: String?,
                              to record: inout Record) {
        switch source.flatMap(DeviceNameSource.init(rawValue:)) {
        case .app?, .device?:
            if let name = DeviceNameText.clean(raw), !DeviceNameText.isGeneric(name, kind: kind) {
                record.reportedName = name
                record.reportedSource = source
            } else {
                record.reportedName = nil
                record.reportedSource = nil
            }
        case .generic?:
            record.reportedName = nil
            record.reportedSource = nil
        case nil:
            guard source == nil, record.reportedSource == nil || record.reportedSource == "service",
                  let name = DeviceNameText.clean(raw),
                  !DeviceNameText.isGeneric(name, kind: kind) else { return }
            record.reportedName = name
            record.reportedSource = "service"
        }
    }

    static func applyCableName(_ raw: String?, kind: String?, to record: inout Record) {
        guard let name = DeviceNameText.clean(raw), !DeviceNameText.isGeneric(name, kind: kind) else { return }
        record.cableName = name
    }
}

struct ResolvedDeviceName: Equatable {
    /// What the UI shows.
    let name: String
    let isCustom: Bool
    /// What the device would be called without the custom name.
    let automatic: String
}

enum DeviceNaming {
    /// Best automatic name: a name the user typed into the phone app, then the
    /// cable's Settings name, then the system name the phone shared, then an
    /// older receiver's service name.
    static func automaticName(_ record: Record?) -> String? {
        guard let record else { return nil }
        if record.reportedSource == DeviceNameSource.app.rawValue, let name = record.reportedName {
            return name
        }
        return record.cableName ?? record.reportedName
    }
    typealias Record = DeviceNameStore.Record

    /// `live` holds names seen right now that are not persisted (a device with
    /// no stable identity yet), best first. The final fallback is the kind.
    static func resolve(_ record: Record?, live: [String?] = [], kind: String? = nil) -> ResolvedDeviceName {
        let kind = DeviceNameText.clean(record?.kind) ?? DeviceNameText.clean(kind)
        let liveName = live.lazy.compactMap { DeviceNameText.clean($0) }
            .first { !DeviceNameText.isGeneric($0, kind: kind) }
        let automatic = automaticName(record) ?? liveName ?? kind
            ?? live.lazy.compactMap { DeviceNameText.clean($0) }.first ?? "Device"
        if let custom = DeviceNameText.clean(record?.customName) {
            return ResolvedDeviceName(name: custom, isCustom: true, automatic: automatic)
        }
        return ResolvedDeviceName(name: automatic, isCustom: false, automatic: automatic)
    }

    /// One row of a list to disambiguate: its key (nil = no identity) and kind.
    struct Item {
        let key: String?
        let name: String
        let kind: String?
    }

    /// For rows whose names a person would read as the same, a small detail
    /// that tells them apart: the kind when that differs within the group,
    /// otherwise a short stable code from the device identity. nil for rows
    /// with a unique name.
    static func distinguishingDetails(_ items: [Item]) -> [String?] {
        var details = [String?](repeating: nil, count: items.count)
        var groups: [[Int]] = []
        for index in items.indices {
            if let g = groups.firstIndex(where: {
                DeviceNameText.sameForDisplay(items[$0[0]].name, items[index].name)
            }) {
                groups[g].append(index)
            } else {
                groups.append([index])
            }
        }
        for group in groups where group.count > 1 {
            let kinds = group.map { DeviceNameText.clean(items[$0].kind)?.lowercased() }
            let kindsDistinct = !kinds.contains(nil) && Set(kinds).count == group.count
            var length = 4
            while length < 12 {
                let codes = group.compactMap { items[$0].key.map { DeviceNameKey.shortCode($0, length: length) } }
                if Set(codes).count == codes.count { break }
                length += 2
            }
            for index in group {
                if kindsDistinct, let kind = DeviceNameText.clean(items[index].kind) {
                    details[index] = kind
                } else if let key = items[index].key {
                    details[index] = "ID " + DeviceNameKey.shortCode(key, length: length)
                } else {
                    details[index] = "not yet identified"
                }
            }
        }
        return details
    }
}
