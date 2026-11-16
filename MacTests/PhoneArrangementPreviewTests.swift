import XCTest
import SwiftUI

@MainActor
final class PhoneArrangementPreviewTests:XCTestCase {
    func testRenderActualPreviewComponentForFourPlacements() throws {
        let main = PhoneDisplay(id:1,identity:"main",name:"Mac main display",frame:CGRect(x:0,y:0,width:1000,height:800),scale:2,rotation:0,mode:1,mirrored:false)
        let phone = PhoneDisplay(id:2,identity:"phone",name:"Phone",frame:CGRect(x:1000,y:0,width:400,height:600),scale:2,rotation:0,mode:1,mirrored:false)
        let topology = PhoneDisplayTopology(main:1,displays:[main,phone])
        let content = VStack {
            ForEach([0,1],id: \.self) { row in
                HStack {
                    ForEach([0,1],id: \.self) { column in
                        let side = PhoneDisplayPlacement.allCases[row*2+column]
                        VStack(alignment:.leading) {
                            Text(side.title+" preview").font(.headline)
                            ArrangementLayoutPreview(topology:topology.placing(2,at:PhoneArrangementGeometry.origin(side,topology:topology,target:2)!),target:2).frame(width:290,height:210)
                        }.padding(12)
                    }
                }
            }
        }.padding(16).background(Color(nsColor:.windowBackgroundColor))
        let renderer = ImageRenderer(content:content); renderer.scale = 2
        let bitmap = try XCTUnwrap(renderer.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        let path = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/phone-arrangement-20261111/four-placements.png")
        try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
        try png.write(to:path)
    }
}
