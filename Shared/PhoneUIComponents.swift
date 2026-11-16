import SwiftUI

/// Compact-height layouts use a short leading column, not a scaled portrait
/// card. Accessibility sizes always stack and scroll without clipping.
enum PhoneLayoutPolicy {
    static func columns(width:Double,height:Double,accessibility:Bool) -> Int {
        !accessibility && width >= 640 && (height < 540 || width >= 900) ? 2 : 1
    }
}
struct PhoneWorkspaceHeader:View {
    let name:String
    let title:String
    let detail:String
    let compact:Bool
    var deviceKind = "iPhone"
    var body:some View {
        VStack(alignment:.leading,spacing:compact ? 10 : 14) {
            Image(systemName:"display.2").font(compact ? .title2 : .largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
            Text(title).font(compact ? .title2.bold() : .largeTitle.bold()).fixedSize(horizontal:false,vertical:true).accessibilityAddTraits(.isHeader)
            Text(detail).font(.body).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Label(name,systemImage:deviceKind == "iPad" ? "ipad" : "iphone").font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal:false,vertical:true).accessibilityLabel("This \(deviceKind): "+name)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
struct PhoneMacChoiceRow:View {
    let name:String,detail:String,actionTitle:String
    let enabled:Bool,busy:Bool
    var action:()->Void
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo:.title2) private var iconWidth:CGFloat = 32
    private var stacksAction:Bool { textSize >= .xxxLarge }
    private var identity:some View {
        HStack(alignment:.top,spacing:12) {
            Image(systemName:"desktopcomputer").font(.title2).foregroundStyle(.tint).frame(width:iconWidth).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:5) {
                Text(name).font(.headline).fixedSize(horizontal:false,vertical:true)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    private var button:some View {
        Button(action:action) {
            HStack(spacing:8) {
                if busy { ProgressView().controlSize(.small) }
                Text(actionTitle).fixedSize(horizontal:!stacksAction,vertical:true)
            }
            .padding(.horizontal,16)
            .frame(minWidth:112,maxWidth:stacksAction ? .infinity : nil,minHeight:48)
        }.buttonStyle(.borderedProminent).disabled(!enabled)
            .fixedSize(horizontal:!stacksAction,vertical:false)
            .layoutPriority(1)
            .accessibilityLabel(actionTitle+" to "+name)
            .accessibilityHint(detail)
    }
    var body:some View {
        Group {
            if stacksAction { VStack(alignment:.leading,spacing:12) { identity;button } }
            else { HStack(spacing:12) { identity;button } }
        }.padding(.vertical,8)
    }
}
struct PhonePairingContent:View {
    let name:String,code:String,approved:Bool
    var deviceKind = "iPhone"
    var approve:()->Void
    var cancel:()->Void
    @Environment(\.dynamicTypeSize) private var textSize
    private var identity:some View {
        VStack(alignment:.leading,spacing:12) {
            Label("Secure pairing",systemImage:"lock.shield").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Text(name).font(.title2.bold()).fixedSize(horizontal:false,vertical:true).accessibilityAddTraits(.isHeader)
            Text(code).font(.system(.largeTitle,design:.monospaced).weight(.semibold))
                .tracking(3).minimumScaleFactor(0.8)
                .accessibilityLabel("Pairing code "+code.map(String.init).joined(separator:" "))
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private var actions:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(approved ? "Waiting for approval on your Mac." : "Make sure this code matches your Mac, then approve on both devices.")
                .font(.body).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Button(action:approve) {
                Label(approved ? "Approved on this \(deviceKind)" : "Codes match — approve",systemImage:approved ? "checkmark.circle.fill" : "checkmark.shield")
                    .frame(maxWidth:.infinity,minHeight:44)
            }.buttonStyle(.borderedProminent).disabled(approved)
            Button(role:.cancel,action:cancel) {
                Text("Cancel pairing").frame(minHeight:44).contentShape(Rectangle())
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    var body:some View {
        GeometryReader { geometry in
            ScrollView {
                Group {
                    if PhoneLayoutPolicy.columns(width:geometry.size.width,height:geometry.size.height,accessibility:textSize.isAccessibilitySize) == 2 {
                        HStack(alignment:.center,spacing:32) { identity;actions }
                    } else { VStack(alignment:.leading,spacing:24) { identity;actions } }
                }.padding(24).frame(maxWidth:760).frame(maxWidth:.infinity,alignment:.leading)
            }
        }
    }
}

enum PhoneErrorCopy {
    static func summary(_ detail:String) -> String {
        let value = detail.lowercased()
        if value.contains("update sideextend on both devices") { return "Update SideExtend on both devices to pair securely." }
        if value.contains("already paired") { return "Already paired. Use Connect, or forget the pairing on both devices to pair again." }
        if value.contains("pairing verification failed") { return "Codes couldn’t be verified. Cancel on both devices and try again." }
        if value.contains("policy denied") || value.contains("policydenied") || value.contains("local network access denied") { return "Local discovery is blocked. Check Local Network access in Settings." }
        if value.contains("rejected") || value.contains("not approved") { return "Pairing wasn’t approved. You can try again." }
        if value.contains("timed out") || value.contains("timeout") || value.contains("expired") { return "Your Mac didn’t respond. Keep it awake and try again." }
        return "Couldn’t connect. Try again or check Diagnostics."
    }
}
