import XCTest
import SwiftUI
import CryptoKit

@MainActor
final class PairingApprovalSnapshotTests: XCTestCase {
    func testNativePairingApprovalPreviewAndWaitingState() throws {
        let coordinator = PairingApprovalCoordinator(ownID: "preview-phone", save: { _,_ in XCTFail("Preview must never grant trust") })
        let a = P256.KeyAgreement.PrivateKey(), b = P256.KeyAgreement.PrivateKey()
        let material = try SecurePairing.derive(privateKey: a, peerPublicKey: b.publicKey,
            initiator: a.publicKey, responder: b.publicKey,
            initiatorNonce: Data(repeating:1,count:32), responderNonce: Data(repeating:2,count:32))
        try coordinator.begin(peerID:"preview-mac",name:"Matthew’s Mac",material:material)
        defer { coordinator.cancel() }
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ui-input-local-20261111/previews")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for approved in [false,true] {
            if approved { coordinator.approve() }
            let renderer = ImageRenderer(content: Color(nsColor:.windowBackgroundColor)
                .frame(width:580,height:480).modifier(PairingApprovalPresenter(pairing:coordinator)))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
            try png.write(to:folder.appendingPathComponent(approved ? "pairing-waiting.png" : "pairing-approval.png"))
        }
        XCTAssertTrue(coordinator.localApproved)
        XCTAssertNotNil(coordinator.prompt, "One approval must not grant trust or skip the other device")
    }
    func testTrackpadSpeedControlNativeRender() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/followup-input-20261111")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        for width in [320.0,430.0] {
            let renderer = ImageRenderer(content:TrackpadSpeedControl().padding(20)
                .frame(width:width).background(Color(nsColor:.windowBackgroundColor)))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("speed-\(Int(width)).png"))
        }
    }

}
