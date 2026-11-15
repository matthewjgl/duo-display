import Foundation
import CoreGraphics

struct PhoneDisplay: Codable, Equatable, Identifiable {
    let id: UInt32
    let identity: String
    let name: String
    let frame: CGRect
    let scale: Double
    let rotation: Double
    let mode: UInt32
    let mirrored: Bool
    func moving(to origin: CGPoint) -> Self {
        Self(id:id,identity:identity,name:name,frame:CGRect(origin:origin,size:frame.size),scale:scale,rotation:rotation,mode:mode,mirrored:mirrored)
    }
}
struct PhoneDisplayTopology: Codable, Equatable {
    let main: UInt32
    let displays: [PhoneDisplay]
    func placing(_ target: UInt32, at origin: CGPoint) -> Self {
        Self(main:main,displays:displays.map { $0.id == target ? $0.moving(to:origin) : $0 })
    }
    func sameHardware(as other:Self) -> Bool {
        main == other.main && displays.count == other.displays.count && displays.allSatisfy { item in
            guard let match = other.displays.first(where: { $0.id == item.id }) else { return false }
            return item.identity == match.identity && item.frame.size == match.frame.size && item.mode == match.mode && item.rotation == match.rotation && item.mirrored == match.mirrored && item.scale == match.scale
        }
    }
}
enum PhoneDisplayPlacement: String, Codable, CaseIterable {
    case left, right, above, below
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self { case .left:return "arrow.left"; case .right:return "arrow.right"; case .above:return "arrow.up"; case .below:return "arrow.down" }
    }
}
struct PhoneArrangementReport: Codable, Equatable {
    let revision: String
    let topology: PhoneDisplayTopology
    let target: UInt32?
    let unavailable: String?
    let canUndo: Bool
    let message: String?
    let busy: Bool
    let applied: Bool
    let diagnostic: String?
}
struct PhoneArrangementRequest: Codable {
    enum Action: String, Codable { case subscribe, unsubscribe, place, undo }
    let action: Action
    let requestID: String
    let revision: String?
    let placement: PhoneDisplayPlacement?
}
enum PhoneArrangementGeometry {
    static func valid(_ rect:CGRect) -> Bool {
        [rect.minX,rect.minY,rect.width,rect.height].allSatisfy { $0.isFinite && abs($0) < 1_000_000 } && rect.width > 0 && rect.height > 0
    }
    static func adjacent(_ a:CGRect,_ b:CGRect) -> Bool {
        let x = min(a.maxX,b.maxX)-max(a.minX,b.minX), y = min(a.maxY,b.maxY)-max(a.minY,b.minY)
        return (abs(x) < 0.01 && y > 0.01) || (abs(y) < 0.01 && x > 0.01)
    }
    static func validLayout(_ topology:PhoneDisplayTopology) -> Bool {
        let displays = topology.displays
        guard !displays.isEmpty, Set(displays.map(\.id)).count == displays.count,
              displays.contains(where:{$0.id == topology.main && $0.frame.origin == .zero}), displays.allSatisfy({ valid($0.frame) && !$0.mirrored }) else { return false }
        for i in displays.indices {
            for j in displays.indices where j > i {
                let intersection = displays[i].frame.intersection(displays[j].frame)
                if !intersection.isNull && intersection.width > 0.01 && intersection.height > 0.01 { return false }
            }
        }
        var reached: Set<UInt32> = [topology.main]
        for _ in displays.indices {
            for display in displays where !reached.contains(display.id) {
                if displays.contains(where:{ reached.contains($0.id) && adjacent($0.frame,display.frame) }) { reached.insert(display.id) }
            }
        }
        return reached.count == displays.count
    }
    static func unavailable(_ topology:PhoneDisplayTopology,target:UInt32?) -> String? {
        guard let target, let phone = topology.displays.first(where:{$0.id == target}) else { return "This iPhone’s extended display is not available. Reconnect and try again." }
        guard topology.main != target else { return "This iPhone is the primary display. Choose a Mac display as primary on the Mac first." }
        guard !topology.displays.contains(where: \.mirrored) else { return "Phone arrangement requires an extended desktop. Disable display mirroring on the Mac first." }
        guard valid(phone.frame),validLayout(topology) else { return "The current layout has overlaps or disconnected edges. Correct it on the Mac before arranging from the phone." }
        return nil
    }
    static func origin(_ side:PhoneDisplayPlacement,topology:PhoneDisplayTopology,target:UInt32) -> CGPoint? {
        guard unavailable(topology,target:target) == nil,
              let main = topology.displays.first(where:{$0.id == topology.main})?.frame,
              let phone = topology.displays.first(where:{$0.id == target})?.frame else { return nil }
        let horizontal = side == .left || side == .right
        let length = horizontal ? phone.height : phone.width
        let lower = horizontal ? main.minY : main.minX, upper = horizontal ? main.maxY : main.maxX
        let center = ((lower+upper-length)/2).rounded()
        var candidates = [center,lower,upper-length]
        for display in topology.displays where display.id != target {
            candidates += horizontal ? [display.frame.minY-length,display.frame.maxY] : [display.frame.minX-length,display.frame.maxX]
        }
        let origins = Set(candidates.map { min(max($0,lower-length+1),upper-1).rounded() }).sorted { abs($0-center) == abs($1-center) ? $0 < $1 : abs($0-center) < abs($1-center) }
        for offset in origins {
            let p:CGPoint
            switch side {
            case .left:p = CGPoint(x:main.minX-phone.width,y:offset)
            case .right:p = CGPoint(x:main.maxX,y:offset)
            case .above:p = CGPoint(x:offset,y:main.minY-phone.height)
            case .below:p = CGPoint(x:offset,y:main.maxY)
            }
            let candidate = CGRect(origin:p,size:phone.size)
            if adjacent(candidate,main),validLayout(topology.placing(target,at:p)) { return p }
        }
        return nil
    }
}

/// Transaction coordinator with injected hardware functions. Tests never invoke
/// the default CoreGraphics backend or alter the user's actual display layout.
@MainActor
final class PhoneArrangementController {
    struct Context: Equatable { let session:String; let target:UInt32?; let unavailable:String? }
    private let read: () -> PhoneDisplayTopology
    private let configure: (PhoneDisplayTopology,PhoneDisplayTopology) async throws -> Void
    private let persist: (PhoneDisplay) -> Void
    private let settle: UInt64
    private var context: Context?
    private var observed: PhoneDisplayTopology?
    private var revision = UUID().uuidString
    private var undo: (before:PhoneDisplayTopology,after:PhoneDisplayTopology)?
    private(set) var busy = false
    private var requests = Set<String>()
    init(read:@escaping () -> PhoneDisplayTopology, configure:@escaping (PhoneDisplayTopology,PhoneDisplayTopology) async throws -> Void,
         settleNanoseconds:UInt64 = 150_000_000, persist:@escaping (PhoneDisplay)->Void = {_ in}) {
        self.read = read; self.configure = configure; self.persist = persist; self.settle = settleNanoseconds
    }
    func snapshot(_ context:Context,message:String? = nil,applied:Bool = false,diagnostic:String? = nil) -> PhoneArrangementReport {
        let topology = read()
        if self.context != context || observed != topology {
            if self.context != context || undo?.after != topology { undo = nil }
            if self.context != context { requests.removeAll() }
            self.context = context; observed = topology; revision = UUID().uuidString
        }
        return .init(revision:revision,topology:topology,target:context.target,
            unavailable:context.unavailable ?? PhoneArrangementGeometry.unavailable(topology,target:context.target),
            canUndo:undo?.after == topology,message:message,busy:busy,applied:applied,diagnostic:diagnostic)
    }
    func handle(_ request:PhoneArrangementRequest,context:Context,stillCurrent:() -> Bool) async -> PhoneArrangementReport {
        var current = snapshot(context)
        guard !busy else { return snapshot(context,message:"An arrangement is already being applied.") }
        guard stillCurrent(), request.revision == current.revision else { return snapshot(context,message:"The connection or layout changed. Review the refreshed layout and preview again.") }
        guard !requests.contains(request.requestID) else { return snapshot(context,message:"That request was already handled. Review the current layout.") }
        requests.insert(request.requestID)
        if requests.count > 128 { return snapshot(context,message:"Too many arrangement requests. Close Arrange Displays and reconnect before trying again.") }
        guard current.unavailable == nil, let target = context.target else { return current }
        let before = current.topology
        let desired:PhoneDisplayTopology
        switch request.action {
        case .place:
            guard let side = request.placement, let origin = PhoneArrangementGeometry.origin(side,topology:before,target:target) else { return snapshot(context,message:"That edge is occupied or would disconnect another display. Choose another placement.") }
            desired = before.placing(target,at:origin)
        case .undo:
            guard let undo,undo.after == before else { return snapshot(context,message:"Undo expired because the display layout changed.") }
            desired = undo.before
        default:return current
        }
        if desired == before { return snapshot(context,message:"This iPhone is already in that position.") }
        guard PhoneArrangementGeometry.validLayout(desired), desired.main == before.main else { return snapshot(context,message:"The proposed layout is no longer safe. Preview another placement.") }
        busy = true
        defer { busy = false }
        do {
            guard stillCurrent(),read() == before else { throw Failure.changed }
            try await configure(before,desired)
            if settle > 0 { try await Task.sleep(nanoseconds:settle) }
            let actual = read()
            guard stillCurrent(), actual == desired else { throw Failure.readback }
            observed = actual; revision = UUID().uuidString
            if request.action == .undo { undo = nil } else { undo = (before,actual) }
            if let display = actual.displays.first(where:{$0.id == target}) { persist(display) }
            busy = false
            return snapshot(context,message:request.action == .undo ? "Previous arrangement restored." : "Arrangement applied.",applied:true)
        } catch {
            var diagnostic = String(describing:error)
            let actual = read()
            var message = "macOS could not apply this arrangement. The actual current layout is shown. Try again after the displays settle."
            // Roll back only our target, and only if unrelated hardware/origins
            // are unchanged. Never overwrite an external topology/user change.
            let unaffected = actual.sameHardware(as:before) && actual.displays.filter{$0.id != target} == before.displays.filter{$0.id != target}
            if unaffected, actual != before, stillCurrent() {
                do { try await configure(actual,before); if settle > 0 { try await Task.sleep(nanoseconds:settle) }
                    if read() == before { message = "macOS did not keep the requested position. Your previous layout was restored." }
                    else {
                        diagnostic += "; rollback readback differed"
                        message = "The previous position could not be confirmed after rollback. Review the actual layout shown or use Mac display settings."
                    }
                } catch {
                    diagnostic += "; rollback: " + String(describing:error)
                    message = "macOS rejected the change and rollback could not be confirmed. Check the actual layout shown, or use Mac display settings."
                }
            } else if actual != before { message = "The topology changed during the request. No unrelated displays were overwritten; review the actual layout before retrying." }
            undo = nil; busy = false; current = snapshot(context,message:message,diagnostic:diagnostic); return current
        }
    }
    enum Failure: Error { case changed,readback }
}
