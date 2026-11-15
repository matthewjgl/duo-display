import SwiftUI

struct TrackpadSpeedControl: View {
    @AppStorage(TrackpadSpeed.defaultsKey) private var level = TrackpadSpeed.defaultLevel
    var body: some View {
        VStack(spacing:8) {
            HStack(alignment:.firstTextBaseline) {
                Text("Pointer speed · \(TrackpadSpeed.normalized(level)) of 7").font(.subheadline)
                    .fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:12)
                Button { level = TrackpadSpeed.defaultLevel } label: {
                    Text("Reset to Default").font(.subheadline)
                        .fixedSize(horizontal:false,vertical:true)
                        .frame(minWidth:44,minHeight:44).contentShape(Rectangle())
                }.disabled(TrackpadSpeed.normalized(level) == TrackpadSpeed.defaultLevel)
                    .accessibilityLabel("Reset pointer speed to default level 4")
            }
            HStack {
                Image(systemName:"tortoise.fill").accessibilityLabel("Slower pointer speed")
                Spacer()
                Image(systemName:"hare.fill").accessibilityLabel("Faster pointer speed")
            }
            .font(.system(size:22,weight:.medium)).foregroundStyle(.secondary)
            .frame(height:28)
            // End symbols stay outside the level layout. Never scroll or force
            // a width beyond the Form row. Narrow rows wrap all seven levels
            // rather than hiding the fast end or shrinking touch targets.
            if #available(iOS 16, macOS 13, *) {
                ViewThatFits(in:.horizontal) {
                    HStack(spacing:1) { levels(1...7) }
                    wrappedLevels
                }
            } else { wrappedLevels }
        }.padding(.vertical,4)
    }
    private var wrappedLevels:some View {
        VStack(spacing:3) {
            HStack(spacing:3) { levels(1...4) }
            HStack(spacing:3) { levels(5...7) }
        }
    }
    private func levels(_ range:ClosedRange<Int>) -> some View {
        ForEach(range,id:\.self) { item in
            Button { level = item } label: {
                RoundedRectangle(cornerRadius:3)
                    .fill(item == TrackpadSpeed.normalized(level) ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(height:CGFloat(10+item*2))
                    .frame(minWidth:44,maxWidth:.infinity,minHeight:48)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("Trackpad speed, level \(item) of 7")
                .accessibilityAddTraits(item == TrackpadSpeed.normalized(level) ? .isSelected : [])
        }
    }
}
