import Foundation
import CoreGraphics

enum PhoneInputMode: String, CaseIterable {
    case touch, trackpad
    static let defaultsKey = "duo.phoneInputMode.v1"
    var title: String { self == .touch ? "Touch" : "Trackpad" }
}

enum TrackpadCommand: Equatable {
    case move(Double, Double)
    case scroll(Double, Double)
    case click(Int)
    case secondaryClick
    case dragBegan
    case dragEnded
    case swipe(Int, TrackpadSwipeDirection)
}

/// Pure gesture arbitration. Contact coordinates are UIKit points in the current
/// orientation, never normalized video coordinates. A lift has no pointer effect.
struct TrackpadGestureState {
    private enum Phase { case idle, single, multiple, swipe, suppressed }
    private var phase = Phase.idle
    private var began = CGPoint.zero
    private var last = CGPoint.zero
    private var beganAt = 0.0
    private var moved = false
    private var held = false
    private var multiLast: CGPoint?
    private var secondaryEligible = false
    private var swipeFingers = 0
    private var swipeStart = CGPoint.zero
    private var swipeDelta = CGPoint.zero
    private var swipeSpan: Double = 0
    private var previousTap: (time: Double, point: CGPoint)?
    private(set) var contactCount = 0
    static let holdDelay = 0.4

    mutating func advance(time: Double) -> [TrackpadCommand] {
        guard phase == .single, !moved, !held, time - beganAt >= Self.holdDelay else { return [] }
        held = true; previousTap = nil
        return [.dragBegan]
    }
    mutating func cancel() -> [TrackpadCommand] {
        let commands: [TrackpadCommand] = held ? [.dragEnded] : []
        phase = .idle; held = false; moved = false; secondaryEligible = false; contactCount = 0; previousTap = nil; multiLast = nil; swipeFingers = 0; swipeDelta = .zero
        return commands
    }
    mutating func update(points: [CGPoint], time: Double) -> [TrackpadCommand] {
        guard time.isFinite, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return cancel() }
        var commands: [TrackpadCommand] = []
        let oldCount = contactCount; contactCount = points.count
        if phase == .suppressed {
            if points.isEmpty { phase = .idle }
            return []
        }
        if phase == .swipe {
            if points.count > swipeFingers {
                // Allow a fourth finger to settle before movement; late fingers
                // cancel rather than reclassifying an already moving swipe.
                if points.count == 4, swipeFingers == 3, hypot(swipeDelta.x,swipeDelta.y) < 8 {
                    startSwipe(points,time:time)
                } else { phase = .suppressed }
                return []
            }
            if points.count < swipeFingers {
                let direction = TrackpadSwipeDirection.recognize(swipeDelta,duration:time-beganAt)
                phase = points.isEmpty ? .idle : .suppressed
                return direction.map { [.swipe(swipeFingers,$0)] } ?? []
            }
            let center = Self.center(points)
            let span = Self.span(points,center:center)
            guard time-beganAt <= 1.5, abs(span-swipeSpan) < max(24,swipeSpan*0.35) else { phase = .suppressed; return [] }
            swipeDelta = CGPoint(x:center.x-swipeStart.x,y:center.y-swipeStart.y)
            return []
        }
        if points.count > 2 {
            let canStart = !held && !moved && (phase != .multiple || secondaryEligible)
            if held { commands.append(.dragEnded); held = false }
            previousTap = nil
            if canStart && points.count <= 4 { startSwipe(points,time:time) }
            else { phase = .suppressed }
            return commands
        }
        if points.isEmpty {
            switch phase {
            case .single:
                if held { commands.append(.dragEnded) }
                else if !moved, time - beganAt <= 0.3 {
                    let count = previousTap.map { time - $0.time <= 0.35 && hypot(began.x - $0.point.x, began.y - $0.point.y) <= 28 ? 2 : 1 } ?? 1
                    commands.append(.click(count))
                    previousTap = count == 1 ? (time, began) : nil
                }
            case .multiple:
                if secondaryEligible, time - beganAt <= 0.3 { commands.append(.secondaryClick) }
                previousTap = nil
            default: break
            }
            phase = .idle; held = false; moved = false; multiLast = nil
            return commands
        }
        if points.count == 2 {
            if phase == .multiple && oldCount == 1 { phase = .suppressed;return [] }
            let center = CGPoint(x: (points[0].x + points[1].x)/2, y: (points[0].y + points[1].y)/2)
            if phase != .multiple {
                secondaryEligible = !held && !moved && (phase == .idle || time - beganAt < 0.15)
                if held { commands.append(.dragEnded); held = false }
                phase = .multiple; multiLast = center; began = center; beganAt = time; previousTap = nil
            } else if let last = multiLast {
                let dx = center.x - last.x, dy = center.y - last.y
                if hypot(center.x - began.x, center.y - began.y) > 5 { secondaryEligible = false }
                if !secondaryEligible { commands.append(.scroll(dx, dy)) }
                multiLast = center
            }
            return commands
        }
        // One remaining finger after a scroll cannot become a new pointer/click.
        if phase == .multiple { multiLast = nil;return [] }
        let point = points[0]
        if phase == .idle || oldCount == 0 {
            phase = .single; began = point; last = point; beganAt = time; moved = false; held = false
            return []
        }
        let reference = !moved && !held ? began : last
        let dx = point.x - reference.x, dy = point.y - reference.y
        if hypot(point.x - began.x, point.y - began.y) > 4 { moved = true; previousTap = nil }
        if moved || held {
            // Preserve the initial slop displacement on the first movement.
            commands.append(.move(dx, dy))
        }
        last = point
        return commands
    }
    private static func center(_ points:[CGPoint]) -> CGPoint {
        CGPoint(x:points.map(\.x).reduce(0,+)/Double(points.count),y:points.map(\.y).reduce(0,+)/Double(points.count))
    }
    private static func span(_ points:[CGPoint],center:CGPoint) -> Double {
        points.map { hypot($0.x-center.x,$0.y-center.y) }.reduce(0,+)/Double(points.count)
    }
    private mutating func startSwipe(_ points:[CGPoint],time:Double) {
        phase = .swipe; swipeFingers = points.count; beganAt = time
        swipeStart = Self.center(points); swipeSpan = Self.span(points,center:swipeStart); swipeDelta = .zero
    }
}

enum PointerMapping {
    /// Global CG display bounds are already logical coordinates, including
    /// negative origins, rotation and scaling. Never constrain to the receiver.
    static func relative(from current: CGPoint, dx: Double, dy: Double, displays: [CGRect]) -> CGPoint? {
        guard current.x.isFinite, current.y.isFinite, dx.isFinite, dy.isFinite,
              abs(dx) <= 2048, abs(dy) <= 2048 else { return nil }
        let p = CGPoint(x: current.x + dx, y: current.y + dy)
        let usable = displays.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        if usable.contains(where: { $0.contains(p) }) { return p }
        return usable.map { r in CGPoint(x: min(max(p.x, r.minX), r.maxX - 0.01), y: min(max(p.y, r.minY), r.maxY - 0.01)) }
            .min { hypot($0.x-p.x,$0.y-p.y) < hypot($1.x-p.x,$1.y-p.y) }
    }
}

/// Phone-only relative-movement gain. Keep the saved level/key stable when
/// tuning the curve; clicks, dragging state and scrolling are not multiplied.
enum TrackpadSpeed {
    static let defaultsKey = "duo.trackpadSpeed.v1"
    static let defaultLevel = 4
    static let gains: [Double] = [0.75, 1.5, 2.5, 4, 6, 9, 14]
    static func normalized(_ level: Int) -> Int { (1...7).contains(level) ? level : defaultLevel }
    static func load(_ defaults: UserDefaults = .standard) -> Int { normalized(defaults.integer(forKey: defaultsKey)) }
    static func save(_ level: Int, to defaults: UserDefaults = .standard) { defaults.set(normalized(level), forKey: defaultsKey) }
    static func apply(_ command: TrackpadCommand, level: Int) -> TrackpadCommand? {
        guard case .move(let x, let y) = command else { return command }
        guard x.isFinite, y.isFinite else { return nil }
        let gain = gains[normalized(level)-1]
        let dx = x * gain, dy = y * gain
        guard dx.isFinite, dy.isFinite else { return nil }
        let limit = max(1, max(abs(dx),abs(dy))/2048)
        return .move(dx/limit,dy/limit)
    }
}

// Discrete public-keyboard-shortcut fallbacks, never private multitouch events.
enum TrackpadSwipeDirection:String,Codable,CaseIterable {
    case left,right,up,down
    static func recognize(_ delta:CGPoint,duration:Double) -> Self? {
        guard duration >= 0.08, duration <= 1.5 else { return nil }
        if abs(delta.x) >= 56 && abs(delta.x) >= abs(delta.y)*1.5 { return delta.x < 0 ? .left : .right }
        if abs(delta.y) >= 56 && abs(delta.y) >= abs(delta.x)*1.5 { return delta.y < 0 ? .up : .down }
        return nil
    }
}
enum TrackpadSystemAction:String,Codable,CaseIterable {
    case none,previousSpace,nextSpace,missionControl,appExpose
    var title:String { switch self {
        case .none:return "Off"
        case .previousSpace:return "Previous desktop / full-screen app"
        case .nextSpace:return "Next desktop / full-screen app"
        case .missionControl:return "Mission Control"
        case .appExpose:return "App Exposé"
    } }
}
struct TrackpadShortcut:Codable,Equatable {
    var key:UInt16
    var modifiers:UInt64
    static let control:UInt64 = 1 << 18, option:UInt64 = 1 << 19, shift:UInt64 = 1 << 17, command:UInt64 = 1 << 20
    static let keys:[UInt16:String] = [123:"←",124:"→",125:"↓",126:"↑",99:"F3",109:"F10",103:"F11",53:"Escape",49:"Space",48:"Tab"]
    var valid:Bool { Self.keys[key] != nil && modifiers & ~(Self.control|Self.option|Self.shift|Self.command) == 0 && (modifiers != 0 || [99,109,103].contains(key)) }
}
struct TrackpadGesturePreferences:Codable,Equatable {
    static let defaultsKey = "duo.shortcutGestures.v1"
    var enabled = false // Explicit opt-in; never guess that global shortcuts match.
    var mappings:[String:TrackpadSystemAction] = ["4.left":.nextSpace,"4.right":.previousSpace,"4.up":.missionControl]
    var shortcuts:[String:TrackpadShortcut] = [
        "previousSpace":.init(key:123,modifiers:TrackpadShortcut.control),
        "nextSpace":.init(key:124,modifiers:TrackpadShortcut.control),
        "missionControl":.init(key:126,modifiers:TrackpadShortcut.control),
        "appExpose":.init(key:125,modifiers:TrackpadShortcut.control)]
    func shortcut(fingers:Int,direction:TrackpadSwipeDirection) -> TrackpadShortcut? {
        guard enabled, [3,4].contains(fingers),let action = mappings["\(fingers).\(direction.rawValue)"],action != .none,
              let shortcut = shortcuts[action.rawValue],shortcut.valid else { return nil }
        return shortcut
    }
    private static func key(_ scope:String?) -> String { defaultsKey+"."+(scope.map{Data($0.utf8).base64EncodedString()} ?? "unreviewed") }
    static func load(_ defaults:UserDefaults = .standard,scope:String? = nil) -> Self {
        guard let data = defaults.data(forKey:key(scope)),let value = try? JSONDecoder().decode(Self.self,from:data) else { return Self() };return value
    }
    func save(_ defaults:UserDefaults = .standard,scope:String? = nil) { defaults.set(try? JSONEncoder().encode(self),forKey:Self.key(scope)) }
}
struct TrackpadGestureRequest:Codable {
    let id:String,sequence:Int,fingers:Int,direction:TrackpadSwipeDirection,shortcut:TrackpadShortcut
}
struct TrackpadGestureAdmission {
    private var lastSequence = 0
    private var ids:Set<String> = []
    private var lastTime:Double = -.infinity
    mutating func accept(_ request:TrackpadGestureRequest,authenticated:Bool,now:Double) -> Bool {
        guard authenticated,[3,4].contains(request.fingers),request.shortcut.valid,
              UUID(uuidString:request.id) != nil,!ids.contains(request.id),request.sequence > lastSequence,
              now.isFinite,now-lastTime >= 0.25 else { return false }
        lastSequence = request.sequence;lastTime = now;ids.insert(request.id)
        if ids.count > 128 { ids = [request.id] }
        return true
    }
}

/// Asynchronously posted absolute CG mouse positions may not be observable by
/// the next input packet. Accumulate against unacknowledged targets, while an
/// independently moved physical mouse immediately takes over. No smoothing.
struct RelativePointerLedger {
    private var observed:CGPoint?
    private var pending:[(point:CGPoint,time:Double)] = []
    mutating func reset() { observed = nil; pending.removeAll() }
    mutating func base(observation:CGPoint,now:Double) -> CGPoint {
        pending.removeAll { now-$0.time > 0.15 }
        if let index = pending.lastIndex(where:{ hypot($0.point.x-observation.x,$0.point.y-observation.y) < 0.5 }) {
            pending.removeFirst(index+1)
        } else if let previous = observed, hypot(previous.x-observation.x,previous.y-observation.y) >= 0.5 {
            pending.removeAll() // Physical mouse or other app moved the pointer.
        }
        observed = observation
        return pending.last?.point ?? observation
    }
    mutating func posted(_ point:CGPoint,now:Double) {
        pending.append((point,now));if pending.count > 128 { pending.removeFirst(pending.count-128) }
    }
}
enum TrackpadPacketFreshness {
    static func skip(action:String,sentMacMs:Double?,nowMacMs:Double) -> Bool {
        guard action == "move",let sentMacMs,sentMacMs.isFinite,nowMacMs.isFinite else { return false }
        return nowMacMs-sentMacMs > 250
    }
}

enum PhoneHapticLevel:String,CaseIterable {
    case off,light,standard,strong
    static let defaultsKey = "duo.inputHaptics.v1"
    static func load(_ defaults:UserDefaults = .standard) -> Self { Self(rawValue:defaults.string(forKey:defaultsKey) ?? "") ?? .standard }
}
enum PhoneInputFeedback:Equatable { case click,secondaryClick,hold }
enum PhoneHapticPolicy {
    static func intensity(_ level:PhoneHapticLevel) -> Double? {
        switch level { case .off:return nil;case .light:return 0.45;case .standard:return 0.75;case .strong:return 1 }
    }
}
struct PhoneInputFeedbackState {
    private var held = false
    mutating func trackpad(_ command:TrackpadCommand,accepted:Bool) -> PhoneInputFeedback? {
        guard accepted else { return nil }
        switch command {
        case .click: return held ? nil : .click
        case .secondaryClick:return held ? nil : .secondaryClick
        case .dragBegan:guard !held else { return nil };held = true;return .hold
        case .dragEnded:held = false;return nil
        default:return nil
        }
    }
    mutating func reset() { held = false }
}
struct DirectTouchFeedbackState {
    private(set) var held = false
    mutating func engage(accepted:Bool) -> PhoneInputFeedback? {
        guard accepted,!held else { return nil };held = true;return .hold
    }
    mutating func complete(tap:Bool,accepted:Bool) -> PhoneInputFeedback? {
        defer { held = false };return tap && accepted && !held ? .click : nil
    }
    mutating func cancel() { held = false }
}

/// Classifies actual pointer presses. A release after a drag/hold is never a
/// typing request. Shared by sender-side validation and direct-touch tests.
struct PointerTypingIntent {
    private var start:CGPoint?
    private var beganAt:Double = 0
    private var moved = false
    mutating func begin(_ point:CGPoint,time:Double) { start = point;beganAt = time;moved = false }
    mutating func move(_ point:CGPoint) { if let start, hypot(point.x-start.x,point.y-start.y)>6 { moved = true } }
    mutating func end(_ point:CGPoint,time:Double) -> Bool {
        move(point);let tap = start != nil && !moved && time-beganAt >= 0 && time-beganAt <= 0.35
        start = nil;return tap
    }
    mutating func cancel() { start = nil;moved = false }
}
