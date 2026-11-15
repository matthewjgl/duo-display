import AppKit
import ApplicationServices
import Carbon

/// Samples role/focus metadata only. Never reads AXValue, selected text, titles,
/// clipboard, passwords or editor contents. Used only during an authenticated stream.
final class KeyboardFocusMonitor {
    var streamBounds:CGRect?
    private var element: AXUIElement?
    private var pid: pid_t = 0
    private var token = UUID().uuidString
    private var interaction = 0
    private var settleUntil = 0.0
    private var intentUntil = 0.0
    private var clickPoint:CGPoint?
    private var clickEvidence = KeyboardClickEvidence()
    func cancelPhoneIntent() { clickPoint = nil;clickEvidence.reset() }
    func resetSession() { interaction = 0; settleUntil = 0; intentUntil = 0; token = UUID().uuidString; element = nil; pid = 0;clickPoint = nil;clickEvidence.reset() }
    func notePhoneClick(intent:Int,point:CGPoint? = nil) {
        interaction = max(interaction,intent);let now = ProcessInfo.processInfo.systemUptime
        settleUntil = now+0.12;intentUntil = now+1.5;clickPoint = point;clickEvidence.begin(now:now)
    }
    func sample(settledOnly: Bool = true) -> KeyboardFocusReport? {
        guard !settledOnly || ProcessInfo.processInfo.systemUptime >= settleUntil else { return nil }
        let app = NSWorkspace.shared.frontmostApplication
        let currentPID = app?.processIdentifier ?? 0
        guard AXIsProcessTrusted() else {
            return report(.permissionRequired,pid:currentPID,element:nil)
        }
        guard currentPID > 0 else { return report(.unavailable,pid:currentPID,element:nil) }
        guard !IsSecureEventInputEnabled() else { return report(.secure,pid:currentPID,element:nil) }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system,0.08)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system,kAXFocusedUIElementAttribute as CFString,&value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return report(.unavailable,pid:currentPID,element:nil)
        }
        let focused = unsafeBitCast(value,to:AXUIElement.self)
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focused,&focusedPID) == .success, focusedPID == currentPID else { return report(.unavailable,pid:currentPID,element:nil) }
        AXUIElementSetMessagingTimeout(focused,0.08)
        func string(_ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(focused,attribute as CFString,&value) == .success else { return nil }
            return value as? String
        }
        let role = string(kAXRoleAttribute), subrole = string(kAXSubroleAttribute)
        if subrole == kAXSecureTextFieldSubrole || role == "AXSecureTextField" { return report(.secure,pid:currentPID,element:focused) }
        func writable(_ attribute: String) -> Bool {
            var settable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(focused,attribute as CFString,&settable) == .success && settable.boolValue
        }
        var enabled: CFTypeRef?
        AXUIElementCopyAttributeValue(focused,kAXEnabledAttribute as CFString,&enabled)
        let kind = KeyboardFocusPolicy.kind(role:role,subrole:subrole,
            writable:writable(kAXValueAttribute) || writable(kAXSelectedTextAttribute),
            enabled:enabled as? Bool != false,secureInput:IsSecureEventInputEnabled(),permission:true)
        return report(kind,pid:currentPID,element:focused)
    }
    private func report(_ kind: KeyboardFocusReport.Kind, pid: pid_t, element: AXUIElement?) -> KeyboardFocusReport {
        let same = self.element == nil && element == nil || (self.element != nil && element != nil && CFEqual(self.element!,element!))
        if self.pid != pid || !same { token = UUID().uuidString; self.pid = pid; self.element = element }
        var hitMatches = false
        if kind == .editable,ProcessInfo.processInfo.systemUptime < intentUntil,let point = clickPoint,let element {
            var hit:AXUIElement?
            let system = AXUIElementCreateSystemWide();AXUIElementSetMessagingTimeout(system,0.05)
            if AXUIElementCopyElementAtPosition(system,Float(point.x),Float(point.y),&hit) == .success {
                for _ in 0..<4 {
                    guard let current = hit else { break }
                    if CFEqual(current,element) { hitMatches = true;break }
                    var parent:CFTypeRef?
                    guard AXUIElementCopyAttributeValue(current,kAXParentAttribute as CFString,&parent) == .success,
                          let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                    hit = unsafeBitCast(parent,to:AXUIElement.self)
                }
            }
        }
        let deliberate = clickEvidence.confirms(token:token,editable:kind == .editable,hitMatches:hitMatches,now:ProcessInfo.processInfo.systemUptime)
        var region:CGRect?
        if kind == .editable,let element,let bounds = streamBounds,bounds.width > 0,bounds.height > 0 {
            var position:CFTypeRef?,size:CFTypeRef?
            if AXUIElementCopyAttributeValue(element,kAXPositionAttribute as CFString,&position) == .success,
               AXUIElementCopyAttributeValue(element,kAXSizeAttribute as CFString,&size) == .success,
               let position,let size,CFGetTypeID(position) == AXValueGetTypeID(),CFGetTypeID(size) == AXValueGetTypeID() {
                var origin = CGPoint.zero,dimensions = CGSize.zero
                if AXValueGetValue(unsafeBitCast(position,to:AXValue.self),.cgPoint,&origin),
                   AXValueGetValue(unsafeBitCast(size,to:AXValue.self),.cgSize,&dimensions) {
                    let clipped = CGRect(origin:origin,size:dimensions).intersection(bounds)
                    if !clipped.isNull,!clipped.isEmpty {
                        region = CGRect(x:(clipped.minX-bounds.minX)/bounds.width,y:(clipped.minY-bounds.minY)/bounds.height,
                                        width:clipped.width/bounds.width,height:clipped.height/bounds.height)
                    }
                }
            }
        }
        return .init(token:token,kind:kind,interaction:interaction,phoneIntent:deliberate,region:region)
    }
    /// Re-check foreground identity immediately before posting; never activate it.
    func destination(for report: KeyboardFocusReport) -> pid_t? {
        guard report.allowsTyping, !IsSecureEventInputEnabled(), let fresh = sample(settledOnly:false), fresh.token == report.token, fresh.kind == report.kind,
              pid > 0, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        return pid
    }
}
