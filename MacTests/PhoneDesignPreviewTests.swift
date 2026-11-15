import XCTest
import SwiftUI

@MainActor final class PhoneDesignPreviewTests:XCTestCase {
    func testCompactAndAccessibleLayoutPolicies() {
        XCTAssertEqual(PhoneLayoutPolicy.columns(width:402,height:874,accessibility:false),1)
        XCTAssertEqual(PhoneLayoutPolicy.columns(width:874,height:402,accessibility:false),2)
        XCTAssertEqual(PhoneLayoutPolicy.columns(width:874,height:402,accessibility:true),1)
        XCTAssertEqual(PhoneLayoutPolicy.columns(width:600,height:320,accessibility:false),1)
    }
    func testHumanErrorCopyKeepsTechnicalDetailsOutOfNormalFlow() {
        XCTAssertTrue(PhoneErrorCopy.summary("Pairing rejected").contains("approved"))
        XCTAssertTrue(PhoneErrorCopy.summary("NWError.posix timeout").contains("awake"))
        XCTAssertFalse(PhoneErrorCopy.summary("NWError -65570 at 192.168.1.1").contains("192.168"))
        XCTAssertTrue(PhoneErrorCopy.summary("Unknown failure").contains("Diagnostics"))
    }
    func testNarrowSpeedControlAndAccessiblePrimaryActionRender() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/build10-ui-fixes-20261111/native-previews")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        for width in [240.0,280.0,330.0,600.0] {
            try render(TrackpadSpeedControl().padding(16).frame(width:width)
                .background(Color(nsColor:.windowBackgroundColor)),to:root.appendingPathComponent("speed-\(Int(width)).png"))
        }
        for size in [DynamicTypeSize.large,.xxxLarge,.accessibility5] {
            try render(PhoneMacChoiceRow(name:"Matthew’s MacBook Pro with a long name",detail:"Ready to connect",actionTitle:"Connect",enabled:true,busy:false,action:{})
                .padding(16).frame(width:320).environment(\.dynamicTypeSize,size)
                .background(Color(nsColor:.windowBackgroundColor)),to:root.appendingPathComponent("connect-\(size).png"))
        }
    }
    func testNativeDirectionPreviewsPortraitLandscapeAndLargeText() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/iphone-ui-polish-20261111/direction")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        for (name,width,height,size) in [("home-portrait",402.0,760.0,DynamicTypeSize.large),("home-landscape",820,340,.large),("home-accessibility",402,1000,.accessibility2)] {
            let header = PhoneWorkspaceHeader(name:"Matthew’s iPhone",title:"Choose your Mac",detail:"Your desktop, with a little more room.",compact:height<540)
            let rows = VStack(alignment:.leading,spacing:12) {
                Text("Available Macs").font(.headline)
                PhoneMacChoiceRow(name:"Matthew’s MacBook Pro",detail:"Ready to connect",actionTitle:"Connect",enabled:true,busy:false,action:{})
                Divider()
                PhoneMacChoiceRow(name:"Studio Mac with a longer name",detail:"Approval required",actionTitle:"Pair & Connect",enabled:true,busy:false,action:{})
            }.padding(20).background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:16))
            let content = Group {
                if height<540 { HStack(alignment:.top,spacing:28) { header.frame(width:260);rows } }
                else { VStack(alignment:.leading,spacing:28) { header;rows;Spacer(minLength:0) } }
            }.padding(24).frame(width:width,height:height,alignment:.top).background(Color(nsColor:.windowBackgroundColor)).environment(\.dynamicTypeSize,size)
            try render(content,to:root.appendingPathComponent(name+".png"))
        }
        for (name,width,height) in [("pairing-portrait",402.0,620.0),("pairing-landscape",820,340)] {
            try render(PhonePairingContent(name:"Matthew’s MacBook Pro",code:"417 829",approved:false,approve:{},cancel:{})
                .frame(width:width,height:height).background(Color(nsColor:.windowBackgroundColor)),to:root.appendingPathComponent(name+".png"))
        }
    }
    private func render<V:View>(_ view:V,to url:URL) throws {
        let renderer = ImageRenderer(content:view);renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url)
    }
}
