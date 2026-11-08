import XCTest

final class DeviceNameTextTests: XCTestCase {
    func testCleanTrimsCollapsesAndRejectsBlank() {
        XCTAssertEqual(DeviceNameText.clean("  Ana’s   iPhone \n"), "Ana’s iPhone")
        XCTAssertEqual(DeviceNameText.clean("Line\none\u{0007}bell"), "Line one bell")
        XCTAssertNil(DeviceNameText.clean("   \n\t "))
        XCTAssertNil(DeviceNameText.clean(""))
        XCTAssertNil(DeviceNameText.clean(nil))
    }

    func testCleanKeepsUnicodeIncludingJoinedEmoji() {
        let family = "👩‍👩‍👧 Família iPad 日本"
        XCTAssertEqual(DeviceNameText.clean(family), family)
        XCTAssertEqual(DeviceNameText.clean("Zoë’s iPhone 🏳️‍🌈"), "Zoë’s iPhone 🏳️‍🌈")
    }

    func testLongNamesAreCappedByCharacters() {
        let long = String(repeating: "😀", count: 100)
        let cleaned = DeviceNameText.clean(long)!
        XCTAssertEqual(cleaned.count, DeviceNameText.maxCharacters)
        XCTAssertTrue(cleaned.allSatisfy { $0 == "😀" })
    }

    func testByteTruncationNeverSplitsACharacter() {
        let name = "Ana’s 👩‍👩‍👧 iPhone with a very long name that goes on"
        let fitted = DeviceNameText.truncated(name, maxBytes: DeviceNameText.maxServiceNameBytes)
        XCTAssertLessThanOrEqual(fitted.utf8.count, DeviceNameText.maxServiceNameBytes)
        XCTAssertTrue(name.hasPrefix(fitted))
        XCTAssertEqual(DeviceNameText.truncated("short", maxBytes: 63), "short")
    }

    func testGenericNamesIncludingBonjourConflictSuffix() {
        for name in ["iPhone", "iPad", "iPhone (2)", "ipad (12)", "Duo Display", "iPhone / iPad", "  ", "Mac"] {
            XCTAssertTrue(DeviceNameText.isGeneric(name), name)
        }
        XCTAssertTrue(DeviceNameText.isGeneric("Pixel", kind: "Pixel"))
        for name in ["Ana’s iPhone", "iPhone (Work)", "Kitchen iPad", "Mac Studio"] {
            XCTAssertFalse(DeviceNameText.isGeneric(name), name)
        }
    }
}

final class DeviceNameAnnouncementTests: XCTestCase {
    func testAppNameWinsOverSystemName() {
        let a = DeviceNameAnnouncement.choose(appName: " Desk ", systemName: "Ana’s iPhone", model: "iPhone")
        XCTAssertEqual(a.name, "Desk")
        XCTAssertEqual(a.source, .app)
    }

    func testPersonalizedSystemNameIsUsedWhenIOSSharesIt() {
        let a = DeviceNameAnnouncement.choose(appName: "", systemName: "Ana’s iPhone", model: "iPhone")
        XCTAssertEqual(a.name, "Ana’s iPhone")
        XCTAssertEqual(a.source, .device)
    }

    func testRestrictedSystemNameIsAnnouncedAsGeneric() {
        // iOS 16+ without the entitlement: UIDevice.current.name == model.
        let a = DeviceNameAnnouncement.choose(appName: nil, systemName: "iPhone", model: "iPhone")
        XCTAssertEqual(a.name, "iPhone")
        XCTAssertEqual(a.source, .generic)
        // An app name that is itself generic does not count as a real name.
        XCTAssertEqual(DeviceNameAnnouncement.choose(appName: "iPad", systemName: "iPad", model: "iPad").source, .generic)
    }
}

final class DeviceNameStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "DeviceNameStoreTests"
    private let phoneA = "11111111-AAAA-4000-8000-00000000A1F3"
    private let phoneB = "22222222-BBBB-4000-8000-00000000B7C9"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func record(_ id: String) -> DeviceNameStore.Record? { DeviceNameStore.load(id, from: defaults) }

    // MARK: Persistence

    func testCustomNamePersistsAcrossRelaunch() {
        XCTAssertTrue(DeviceNameStore.setCustomName("  Studio iPhone ", for: phoneA, in: defaults))
        // A relaunch reads the same domain with a fresh UserDefaults.
        let relaunched = UserDefaults(suiteName: suite)!
        let resolved = DeviceNaming.resolve(DeviceNameStore.load(phoneA, from: relaunched))
        XCTAssertEqual(resolved.name, "Studio iPhone")
        XCTAssertTrue(resolved.isCustom)
        XCTAssertEqual(DeviceNameStore.allIDs(in: relaunched), [phoneA])
    }

    func testBlankRenameIsRejectedAndKeepsThePreviousName() {
        DeviceNameStore.setCustomName("Desk", for: phoneA, in: defaults)
        XCTAssertFalse(DeviceNameStore.setCustomName("   \n", for: phoneA, in: defaults))
        XCTAssertEqual(record(phoneA)?.customName, "Desk")
        XCTAssertFalse(DeviceNameStore.setCustomName("Desk", for: nil, in: defaults), "no identity, no rename")
    }

    func testRenameNeverTouchesConnectionSettings() {
        DeviceSetupStore.update(phoneA, in: defaults) { $0.wirelessAllowed = true; $0.reconnectAtLaunch = true; $0.quality = "fast" }
        let before = DeviceSetupStore.load(phoneA, from: defaults)
        DeviceNameStore.setCustomName("Desk", for: phoneA, in: defaults)
        DeviceNameStore.resetCustomName(for: phoneA, in: defaults)
        DeviceNameStore.remove(phoneA, in: defaults)
        XCTAssertEqual(DeviceSetupStore.load(phoneA, from: defaults), before)
    }

    // MARK: Automatic name and fallback

    func testAutomaticNameOrder() {
        var r = DeviceNameStore.Record(kind: "iPhone")
        XCTAssertEqual(DeviceNaming.resolve(r).name, "iPhone", "kind is the last resort")
        XCTAssertEqual(DeviceNaming.resolve(nil).name, "Device")
        XCTAssertEqual(DeviceNaming.resolve(r, live: ["iPhone (2)", "Ana’s iPhone"]).name, "Ana’s iPhone",
                       "live names beat the kind, generic ones are skipped")
        DeviceNameStore.applyReported("Ana’s iPhone", source: "device", kind: "iPhone", to: &r)
        XCTAssertEqual(DeviceNaming.resolve(r).name, "Ana’s iPhone")
        DeviceNameStore.applyCableName("Ana’s iPhone 15", kind: "iPhone", to: &r)
        XCTAssertEqual(DeviceNaming.resolve(r).name, "Ana’s iPhone 15", "cable Settings name beats the shared system name")
        DeviceNameStore.applyReported("Desk phone", source: "app", kind: "iPhone", to: &r)
        XCTAssertEqual(DeviceNaming.resolve(r).name, "Desk phone", "a name typed into the phone app wins")
    }

    func testRestrictedNameFallsBackWithoutPretending() {
        var r = DeviceNameStore.Record(kind: "iPhone")
        DeviceNameStore.applyReported("iPhone", source: "generic", kind: "iPhone", to: &r)
        XCTAssertNil(r.reportedName)
        XCTAssertEqual(DeviceNaming.resolve(r).name, "iPhone")
        XCTAssertFalse(DeviceNaming.resolve(r).isCustom)
    }

    func testGenericAnnouncementForgetsAStaleReportedName() {
        var r = DeviceNameStore.Record(kind: "iPhone")
        DeviceNameStore.applyReported("Desk phone", source: "app", kind: "iPhone", to: &r)
        DeviceNameStore.applyReported("iPhone", source: "generic", kind: "iPhone", to: &r)
        XCTAssertNil(r.reportedName)
        XCTAssertNil(r.reportedSource)
    }

    func testOlderReceiverServiceNameIsUsedOnlyWhenNothingBetterIsKnown() {
        var r = DeviceNameStore.Record(kind: "iPhone")
        DeviceNameStore.applyReported("iPhone (2)", source: nil, kind: "iPhone", to: &r)
        XCTAssertNil(r.reportedName, "a Bonjour conflict name is not a name")
        DeviceNameStore.applyReported("Ana’s phone", source: nil, kind: "iPhone", to: &r)
        XCTAssertEqual(r.reportedSource, "service")
        DeviceNameStore.applyReported("Desk", source: "app", kind: "iPhone", to: &r)
        DeviceNameStore.applyReported("Something else", source: nil, kind: "iPhone", to: &r)
        XCTAssertEqual(r.reportedName, "Desk", "a legacy service name never overwrites an announced one")
    }

    func testAutomaticNameRefreshesOnlyWithoutCustomName() {
        DeviceNameStore.update(phoneA, in: defaults) { DeviceNameStore.applyCableName("Old Name", kind: "iPhone", to: &$0) }
        DeviceNameStore.update(phoneA, in: defaults) { DeviceNameStore.applyCableName("New Name", kind: "iPhone", to: &$0) }
        XCTAssertEqual(DeviceNaming.resolve(record(phoneA)).name, "New Name")
        DeviceNameStore.setCustomName("Desk", for: phoneA, in: defaults)
        DeviceNameStore.update(phoneA, in: defaults) { DeviceNameStore.applyCableName("Newer Name", kind: "iPhone", to: &$0) }
        let resolved = DeviceNaming.resolve(record(phoneA))
        XCTAssertEqual(resolved.name, "Desk")
        XCTAssertEqual(resolved.automatic, "Newer Name")
    }

    // MARK: Reset

    func testResetReturnsToTheCurrentAutomaticName() {
        DeviceNameStore.update(phoneA, in: defaults) { DeviceNameStore.applyCableName("Ana’s iPhone", kind: "iPhone", to: &$0) }
        DeviceNameStore.setCustomName("Desk", for: phoneA, in: defaults)
        DeviceNameStore.resetCustomName(for: phoneA, in: defaults)
        let resolved = DeviceNaming.resolve(record(phoneA))
        XCTAssertEqual(resolved.name, "Ana’s iPhone")
        XCTAssertFalse(resolved.isCustom)
        XCTAssertEqual(record(phoneA)?.cableName, "Ana’s iPhone", "reset keeps the record and its facts")
    }

    func testRenamingToTheAutomaticNameIsAReset() {
        DeviceNameStore.update(phoneA, in: defaults) { DeviceNameStore.applyCableName("Ana’s iPhone", kind: "iPhone", to: &$0) }
        DeviceNameStore.setCustomName("Desk", for: phoneA, in: defaults)
        DeviceNameStore.setCustomName("Ana’s iPhone", for: phoneA, in: defaults)
        XCTAssertNil(record(phoneA)?.customName)
    }

    func testResetNeverCreatesARecord() {
        DeviceNameStore.resetCustomName(for: phoneB, in: defaults)
        XCTAssertFalse(DeviceNameStore.hasRecord(phoneB, in: defaults))
    }

    // MARK: Transport handoff

    func testSameKeyOnUSBAndWiFi() {
        // The install id is the key whichever transport the device is on;
        // its cable serial, IP or service name never enter it.
        let overUSB = DeviceNameKey.make(installID: phoneA, udid: "00008110-000A1B2C3D4E")
        let overWiFi = DeviceNameKey.make(installID: phoneA, udid: nil)
        XCTAssertEqual(overUSB, phoneA)
        XCTAssertEqual(overWiFi, phoneA)
        XCTAssertEqual(DeviceNameKey.make(installID: nil, udid: "00008110-000A1B2C3D4E"), "usb:00008110-000A1B2C3D4E")
        XCTAssertNil(DeviceNameKey.make(installID: nil, udid: nil))
        XCTAssertNil(DeviceNameKey.make(installID: " padded", udid: nil))
    }

    func testNameSetOverUSBBeforeIdentityFollowsTheDeviceOntoWiFi() {
        let udid = "00008110-000A1B2C3D4E"
        let usbKey = DeviceNameKey.make(installID: nil, udid: udid)
        DeviceNameStore.setCustomName("Desk", for: usbKey, in: defaults)
        DeviceNameStore.update(usbKey, in: defaults) { DeviceNameStore.applyCableName("Ana’s iPhone", kind: nil, to: &$0) }
        // The first hello teaches the install id.
        XCTAssertTrue(DeviceNameStore.adopt(udid: udid, into: phoneA, in: defaults))
        XCTAssertFalse(DeviceNameStore.hasRecord(usbKey, in: defaults), "no duplicate entry")
        XCTAssertEqual(DeviceNameStore.allIDs(in: defaults), [phoneA])
        let overWiFi = DeviceNaming.resolve(DeviceNameStore.load(DeviceNameKey.make(installID: phoneA, udid: nil), from: defaults))
        XCTAssertEqual(overWiFi.name, "Desk")
        XCTAssertEqual(overWiFi.automatic, "Ana’s iPhone")
        XCTAssertFalse(DeviceNameStore.adopt(udid: udid, into: phoneA, in: defaults), "idempotent")
    }

    func testAdoptionKeepsAnExistingInstallIDName() {
        let udid = "00008110-000A1B2C3D4E"
        DeviceNameStore.setCustomName("From Wi-Fi", for: phoneA, in: defaults)
        DeviceNameStore.setCustomName("From USB", for: DeviceNameKey.make(installID: nil, udid: udid), in: defaults)
        DeviceNameStore.adopt(udid: udid, into: phoneA, in: defaults)
        XCTAssertEqual(record(phoneA)?.customName, "From Wi-Fi")
    }

    func testNewerSchemaIsLeftAlone() throws {
        let newer = try JSONSerialization.data(withJSONObject: ["schema": 2, "customName": "Future"])
        defaults.set(newer, forKey: DeviceNameStore.key(phoneA))
        XCTAssertFalse(DeviceNameStore.update(phoneA, in: defaults) { $0.customName = "Now" })
        XCTAssertEqual(defaults.data(forKey: DeviceNameStore.key(phoneA)), newer)
    }

    func testUnchangedUpdateDoesNotWrite() {
        DeviceNameStore.update(phoneA, in: defaults) { $0.kind = "iPhone" }
        XCTAssertFalse(DeviceNameStore.update(phoneA, in: defaults) { $0.kind = "iPhone" })
    }
}

final class DeviceNameDisambiguationTests: XCTestCase {
    private let a = "11111111-AAAA-4000-8000-00000000A1F3"
    private let b = "22222222-BBBB-4000-8000-00000000B7C9"

    func testUniqueNamesGetNoDetail() {
        let details = DeviceNaming.distinguishingDetails([
            .init(key: a, name: "Ana’s iPhone", kind: "iPhone"),
            .init(key: b, name: "Ben’s iPhone", kind: "iPhone"),
        ])
        XCTAssertEqual(details, [nil, nil])
    }

    func testIdenticalNamesGetAStableShortCode() {
        let items: [DeviceNaming.Item] = [
            .init(key: a, name: "iPhone", kind: "iPhone"),
            .init(key: b, name: "IPHONE", kind: "iPhone"),
            .init(key: nil, name: "Other", kind: nil),
        ]
        let details = DeviceNaming.distinguishingDetails(items)
        XCTAssertEqual(details, ["ID A1F3", "ID B7C9", nil])
        XCTAssertEqual(DeviceNaming.distinguishingDetails(items.reversed()), [nil, "ID B7C9", "ID A1F3"],
                       "a device's detail does not depend on list order")
    }

    func testDifferentKindsUseTheKind() {
        let details = DeviceNaming.distinguishingDetails([
            .init(key: a, name: "Ana", kind: "iPhone"),
            .init(key: b, name: "Ana", kind: "iPad"),
        ])
        XCTAssertEqual(details, ["iPhone", "iPad"])
    }

    func testColludingShortCodesGrow() {
        let x = "AAAA-0000-1234"
        let y = "BBBB-9999-1234"
        let details = DeviceNaming.distinguishingDetails([
            .init(key: x, name: "Desk", kind: "iPhone"),
            .init(key: y, name: "Desk", kind: "iPhone"),
        ])
        XCTAssertNotEqual(details[0], details[1])
        XCTAssertEqual(details[0], "ID 001234")
    }

    func testDeviceWithoutIdentityIsLabelledHonestly() {
        let details = DeviceNaming.distinguishingDetails([
            .init(key: a, name: "iPhone", kind: "iPhone"),
            .init(key: nil, name: "iPhone", kind: "iPhone"),
        ])
        XCTAssertEqual(details, ["ID A1F3", "not yet identified"])
    }

    func testHelloCarriesTheAnnouncedName() throws {
        let json = #"{"type":"hello","pixelsWide":2556,"pixelsHigh":1179,"scale":3,"device":"iPhone","id":"x","name":"Ana’s iPhone","nameSource":"device"}"#
        let info = try JSONDecoder().decode(PhoneInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.name, "Ana’s iPhone")
        XCTAssertEqual(info.nameSource, "device")
        let legacy = #"{"type":"hello","pixelsWide":2556,"pixelsHigh":1179,"scale":3}"#
        XCTAssertNil(try JSONDecoder().decode(PhoneInfo.self, from: Data(legacy.utf8)).nameSource)
    }
}
