import XCTest
import SwiftUI

/// Offline layout matrix for the Shared phone components at real device point
/// sizes. ImageRenderer on macOS, not an iOS simulator or device: it checks
/// wrapping/column decisions, not safe areas, keyboards or system chrome.
@MainActor
final class PhoneLayoutMatrixTests: XCTestCase {
    struct Device { let name: String; let portrait: CGSize }
    static let devices = [
        Device(name: "iPhoneSE", portrait: CGSize(width: 375, height: 667)),
        Device(name: "iPhone17Pro", portrait: CGSize(width: 402, height: 874)),
        Device(name: "iPhone17ProMax", portrait: CGSize(width: 440, height: 956)),
        Device(name: "iPadMini", portrait: CGSize(width: 744, height: 1133)),
        Device(name: "iPad13", portrait: CGSize(width: 1032, height: 1376)),
    ]

    func testColumnPolicyAtRealDeviceSizes() {
        func columns(_ s: CGSize, _ a: Bool = false) -> Int { PhoneLayoutPolicy.columns(width: s.width, height: s.height, accessibility: a) }
        for d in Self.devices where d.name.hasPrefix("iPhone") {
            XCTAssertEqual(columns(d.portrait), 1, "\(d.name) portrait stacks")
            XCTAssertEqual(columns(CGSize(width: d.portrait.height, height: d.portrait.width)), 2, "\(d.name) landscape uses a short leading column")
            XCTAssertEqual(columns(CGSize(width: d.portrait.height, height: d.portrait.width), true), 1, "accessibility sizes always stack")
        }
        XCTAssertEqual(columns(CGSize(width: 744, height: 1133)), 1, "iPad mini portrait")
        XCTAssertEqual(columns(CGSize(width: 1032, height: 1376)), 2, "iPad 13 portrait")
        XCTAssertEqual(columns(CGSize(width: 1376, height: 1032)), 2, "iPad 13 landscape")
        XCTAssertEqual(columns(CGSize(width: 320, height: 568)), 1, "narrow Split View")
    }

    func testRenderSharedComponentMatrix() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/review-impl-20261115/layout")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var rendered = 0
        for device in Self.devices {
            for landscape in [false, true] {
                let size = landscape ? CGSize(width: device.portrait.height, height: device.portrait.width) : device.portrait
                let kind = device.name.hasPrefix("iPad") ? "iPad" : "iPhone"
                for (label, type) in [("large", DynamicTypeSize.large), ("xxxl", .xxxLarge), ("ax3", .accessibility3)] {
                    for dark in [false, true] where !(dark && type != .large) {
                        let columns = PhoneLayoutPolicy.columns(width: size.width, height: size.height, accessibility: type.isAccessibilitySize)
                        let header = PhoneWorkspaceHeader(name: "Matthew’s \(kind) with a long name", title: "Choose your Mac",
                            detail: "Open SideExtend on your Mac. Use the same Wi-Fi or a USB cable.", compact: columns == 2, deviceKind: kind)
                        let rows = VStack(alignment: .leading, spacing: 12) {
                            Text("Available Macs").font(.headline)
                            PhoneMacChoiceRow(name: "Matthew’s studio MacBook Pro with a very long device name", detail: "Ready to connect",
                                              actionTitle: "Connect", enabled: true, busy: false, action: {})
                            Divider()
                            PhoneMacChoiceRow(name: "Mac mini", detail: "Approval required", actionTitle: "Pair & Connect", enabled: true, busy: true, action: {})
                            TrackpadSpeedControl()
                        }.padding(20).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
                        let content = Group {
                            if columns == 2 { HStack(alignment: .top, spacing: 28) { header.frame(width: 240); rows } }
                            else { VStack(alignment: .leading, spacing: 28) { header; rows } }
                        }
                        .padding(24).frame(width: size.width, alignment: .topLeading)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.dynamicTypeSize, type)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        let name = "\(device.name)-\(landscape ? "land" : "port")-\(label)\(dark ? "-dark" : "")"
                        let image = try render(content, to: root.appendingPathComponent(name + ".png"))
                        // The content may scroll vertically, but must never exceed the width.
                        XCTAssertLessThanOrEqual(image.width, size.width + 0.5, name)
                        rendered += 1
                    }
                }
                let pairing = PhonePairingContent(name: "Matthew’s MacBook Pro", code: "417 829", approved: true, deviceKind: kind, approve: {}, cancel: {})
                    .frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor))
                _ = try render(pairing, to: root.appendingPathComponent("\(device.name)-\(landscape ? "land" : "port")-pairing.png"))
            }
        }
        XCTAssertEqual(rendered, Self.devices.count * 2 * 4)
    }

    @discardableResult
    private func render<V: View>(_ view: V, to url: URL) throws -> CGSize {
        let renderer = ImageRenderer(content: view); renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return image.size
    }
}
