import SwiftUI

struct ArrangementLayoutPreview: View {
    let topology:PhoneDisplayTopology
    let target:UInt32?
    /// "iPhone" / "iPad": names the receiver the user is holding.
    var deviceKind = "iPhone"
    var body: some View {
        GeometryReader { geometry in
            let union = topology.displays.reduce(CGRect.null) { $0.union($1.frame) }
            let scale = union.width > 0 && union.height > 0 ? min(max(1,geometry.size.width-16)/union.width,max(1,geometry.size.height-16)/union.height) : 1
            ZStack(alignment:.topLeading) {
                ForEach(topology.displays) { display in
                    VStack(spacing:4) {
                        if display.id == topology.main { Capsule().frame(height:3).padding(.horizontal,8) }
                        Spacer(minLength:0)
                        Text(display.id == target ? "This \(deviceKind)" : display.name).font(.caption.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
                        Spacer(minLength:0)
                    }.padding(4)
                        .frame(width:max(1,display.frame.width*scale),height:max(1,display.frame.height*scale))
                        .background(display.id == target ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12),in:RoundedRectangle(cornerRadius:6))
                        .overlay(RoundedRectangle(cornerRadius:6).stroke(display.id == target ? Color.accentColor : .secondary,lineWidth:display.id == target ? 2 : 1))
                        .offset(x:(display.frame.minX-union.minX)*scale+8,y:(display.frame.minY-union.minY)*scale+8)
                        .accessibilityLabel(display.id == target ? "This \(deviceKind) display" : display.name)
                        .accessibilityValue("\(Int(display.frame.width)) by \(Int(display.frame.height)) logical points")
                }
            }
        }.accessibilityElement(children:.contain)
    }
}
