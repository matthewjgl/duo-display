import Foundation
import CoreGraphics

struct KeyboardFocusReport: Codable, Equatable {
    enum Kind: String, Codable { case editable, notEditable, unsupported, secure, permissionRequired, unavailable }
    let token: String
    let kind: Kind
    let interaction: Int
    let phoneIntent: Bool
    /// Normalized geometry only, never field contents. Optional for older peers.
    let region: CGRect?
    init(token:String,kind:Kind,interaction:Int,phoneIntent:Bool = false,region:CGRect? = nil) {
        self.token = token; self.kind = kind; self.interaction = interaction; self.phoneIntent = phoneIntent; self.region = region
    }
    var allowsTyping: Bool { kind == .editable || kind == .unsupported || kind == .notEditable }
    var guidance: String? {
        switch kind {
        case .editable: return nil
        case .secure: return "Secure input is protected. Use the Mac’s keyboard for this field."
        case .unavailable: return "The Mac cannot verify editing focus in this app. Use the Mac keyboard until focus is available."
        case .permissionRequired: return "Automatic keyboard needs Accessibility access. On the Mac, enable Automatic phone keyboard in SideExtend → Permissions, or use the Mac keyboard."
        default: return "This app does not expose an editable field. Focus the field on your Mac, then open Keyboard manually."
        }
    }
}
struct KeyboardPresentationState: Equatable {
    private(set) var focus: KeyboardFocusReport?
    private(set) var visible = false
    private(set) var manual = false
    private var handledInteraction = 0
    private var latestLocalInteraction = 0
    mutating func recordInteraction(_ id:Int) { latestLocalInteraction = max(latestLocalInteraction,id) }
    mutating func receive(_ report: KeyboardFocusReport) {
        let deliberate = report.phoneIntent && report.interaction > handledInteraction
        let changed = focus?.token != report.token
        if deliberate && report.kind == .editable { handledInteraction = report.interaction }
        if !report.allowsTyping || (changed && !deliberate) { visible = false; manual = false }
        if deliberate && report.kind == .editable { visible = true; manual = false }
        focus = report
    }
    mutating func dismiss() { visible = false; manual = false; handledInteraction = max(handledInteraction,max(latestLocalInteraction,focus?.interaction ?? 0)) }
    mutating func openManually() { visible = focus?.allowsTyping == true; manual = visible }
    mutating func disconnect() { self = Self() }
}
struct KeyboardCommand: Codable, Equatable {
    enum Action: String, Codable { case text, backspace, enter }
    let sequence: Int
    let focus: String
    let action: Action
    let text: String?
    let manual: Bool
    init(sequence:Int,focus:String,action:Action,text:String?,manual:Bool = false) {
        self.sequence = sequence; self.focus = focus; self.action = action; self.text = text; self.manual = manual
    }
}
struct KeyboardAdmission {
    private var lastSequence = 0
    mutating func accept(_ command: KeyboardCommand, focus: KeyboardFocusReport, authenticated: Bool) -> Bool {
        guard authenticated, focus.allowsTyping, (focus.kind == .editable || command.manual), command.focus == focus.token,
              command.sequence > lastSequence, command.sequence > 0 else { return false }
        if command.action == .text {
            guard let text = command.text, !text.isEmpty, text.utf16.count <= 4096,
                  !text.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" }) else { return false }
        } else if command.text != nil { return false }
        lastSequence = command.sequence
        return true
    }
}
enum KeyboardText {
    static let sentinel = "\u{200B}"
    /// UIKit retains only active marked text. Never transmit partial IME updates.
    static func committed(_ text: String, marked: Bool) -> String? {
        guard !marked else { return nil }
        let value = text.hasPrefix(sentinel) ? String(text.dropFirst()) : text
        return value.isEmpty ? nil : value
    }
    /// Public CGEvent Unicode payloads, never split a surrogate pair.
    static func chunks(_ text: String, maxUnits: Int = 20) -> [[UniChar]] {
        var chunks: [[UniChar]] = [], current: [UniChar] = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if current.count + units.count > max(2,maxUnits) { chunks.append(current); current = [] }
            current += units
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
/// Used by both video layout and touch normalization when keyboard safe areas resize.
enum ReceiverViewport {
    /// A docked software keyboard reserves substantial space below the video.
    /// A home indicator or a hardware-keyboard accessory alone must not zoom.
    static func hasSoftwareKeyboard(window:CGRect,viewport:CGRect)->Bool {
        window.maxY-viewport.maxY > 100
    }
    static func rect(video: CGSize, in bounds: CGRect) -> CGRect? {
        guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width/video.width,bounds.height/video.height)
        let size = CGSize(width:video.width*scale,height:video.height*scale)
        return CGRect(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2,width:size.width,height:size.height)
    }
}

enum KeyboardFocusPolicy {
    static func kind(role:String?,subrole:String?,writable:Bool,enabled:Bool,secureInput:Bool,permission:Bool) -> KeyboardFocusReport.Kind {
        guard permission else { return .permissionRequired }
        if secureInput || subrole == "AXSecureTextField" || role == "AXSecureTextField" { return .secure }
        let textRole = ["AXTextField","AXTextArea","AXComboBox"].contains(role ?? "")
        if textRole && writable && enabled { return .editable }
        return textRole || role == nil ? .unsupported : .notEditable
    }
}

/// Focus alone is not typing intent: the click must hit that same editable
/// element and its focus must settle. Window title-bar drags fail this gate.
struct KeyboardClickEvidence {
    private var expires:Double = 0
    private var settle:Double = 0
    private var candidate:String?
    private var candidateSince:Double = 0
    mutating func begin(now:Double) { expires = now+1.5;settle = now+0.12;candidate = nil }
    mutating func reset() { self = Self() }
    mutating func confirms(token:String,editable:Bool,hitMatches:Bool,now:Double) -> Bool {
        guard now >= settle,now < expires,editable,hitMatches else { candidate = nil;return false }
        guard candidate == token else { candidate = token;candidateSince = now;return false }
        return now-candidateSince >= 0.06
    }
}

/// A transient message that clears itself. Each new message gets a fresh token,
/// so an older expiry can never hide a newer message.
struct ExpiringNotice: Equatable {
    static let lifetime: TimeInterval = 6
    private(set) var text: String?
    private(set) var token = 0
    /// Returns the token to expire later, or nil when the notice was cleared.
    mutating func show(_ message: String?) -> Int? {
        token &+= 1; text = message
        return message == nil ? nil : token
    }
    mutating func expire(_ expected: Int) { if expected == token { text = nil } }
}

/// Delivery metadata only: never retains text. No automatic resend can duplicate
/// text after an uncertain network failure; the user gets an explicit warning.
struct KeyboardDeliveryLedger {
    private var pending: [Int:String] = [:]
    var count: Int { pending.count }
    mutating func register(_ sequence:Int,focus:String) -> Bool {
        guard pending.count < 128, pending[sequence] == nil else { return false }
        pending[sequence] = focus; return true
    }
    mutating func complete(_ sequence:Int,focus:String) -> Bool {
        guard pending[sequence] == focus else { return false }
        pending.removeValue(forKey:sequence); return true
    }
    mutating func reset() { pending.removeAll() }
}

/// Small synchronization gate; AX calls never run while holding this lock.
final class KeyboardSessionGuard {
    private let lock = NSLock()
    private var active: UUID?
    func begin() -> UUID { lock.lock(); defer { lock.unlock() }; let id = UUID(); active = id; return id }
    func invalidate() { lock.lock(); active = nil; lock.unlock() }
    func current() -> UUID? { lock.lock(); defer { lock.unlock() }; return active }
    func matches(_ id:UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return active == id }
    func perform(_ id:UUID,expires:Double,_ action:() -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active == id, ProcessInfo.processInfo.systemUptime < expires else { return false }
        return action()
    }
}

/// Local keyboard viewport. Uniform scaling keeps text/touch coordinates aligned;
/// clamping always covers the available area, with no delayed motion queue.
struct KeyboardZoomViewport {
    private(set) var zoom:CGFloat = 1
    private(set) var center = CGPoint(x:0.5,y:0.5)
    mutating func focus(_ region:CGRect?,fallback:CGPoint) {
        zoom = 1
        if let region,region.minX.isFinite,region.minY.isFinite,region.width.isFinite,region.height.isFinite,
           region.width > 0,region.height > 0,CGRect(x:0,y:0,width:1,height:1).intersects(region) {
            center = CGPoint(x:region.midX,y:region.midY)
        } else { center = fallback }
    }
    func rect(video:CGSize,in bounds:CGRect)->CGRect? {
        guard video.width > 0,video.height > 0,bounds.width > 0,bounds.height > 0 else { return nil }
        let scale = max(bounds.width/video.width,bounds.height/video.height)*zoom
        let size = CGSize(width:video.width*scale,height:video.height*scale)
        let x = min(bounds.minX,max(bounds.maxX-size.width,bounds.midX-center.x*size.width))
        let y = min(bounds.minY,max(bounds.maxY-size.height,bounds.midY-center.y*size.height))
        return CGRect(origin:CGPoint(x:x,y:y),size:size)
    }
    mutating func pan(_ delta:CGPoint,video:CGSize,in bounds:CGRect) {
        guard let rect = rect(video:video,in:bounds) else { return }
        center = CGPoint(x:(bounds.midX-rect.minX-delta.x)/rect.width,y:(bounds.midY-rect.minY-delta.y)/rect.height)
        clamp(video:video,in:bounds)
    }
    mutating func pinch(_ factor:CGFloat,at point:CGPoint,video:CGSize,in bounds:CGRect) {
        guard factor.isFinite,factor > 0,let before = rect(video:video,in:bounds) else { return }
        let anchor = CGPoint(x:(point.x-before.minX)/before.width,y:(point.y-before.minY)/before.height)
        zoom = min(6,max(1,zoom*factor))
        guard let after = rect(video:video,in:bounds) else { return }
        center = CGPoint(x:anchor.x+(bounds.midX-point.x)/after.width,y:anchor.y+(bounds.midY-point.y)/after.height)
        clamp(video:video,in:bounds)
    }
    private mutating func clamp(video:CGSize,in bounds:CGRect) {
        guard let rect = rect(video:video,in:bounds) else { return }
        center = CGPoint(x:(bounds.midX-rect.minX)/rect.width,y:(bounds.midY-rect.minY)/rect.height)
    }
}
