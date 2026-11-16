import CoreGraphics
import AppKit
import Darwin
import Carbon

/// System double-click thresholds. Interval is public API; distance is read from
/// AppKit's `NSDoubleClickDistance()` (same value the Window Server uses).
private enum SystemClickMetrics {
    static var interval: TimeInterval { NSEvent.doubleClickInterval }

    static var distance: CGFloat {
        doubleClickDistanceFn?() ?? 4
    }

    private typealias DoubleClickDistanceFn = @convention(c) () -> CGFloat
    private static let doubleClickDistanceFn: DoubleClickDistanceFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY),
              let sym = dlsym(handle, "NSDoubleClickDistance") else { return nil }
        return unsafeBitCast(sym, to: DoubleClickDistanceFn.self)
    }()
}

/// Turns normalized touch coordinates from the phone into mouse events on a
/// target display. Touch semantics: finger down = left button down, finger
/// move = drag, finger up = button up — i.e. the phone acts as a touchscreen.
final class InputInjector {

    private let displayID: CGDirectDisplayID
    private let displayBounds: (CGDirectDisplayID) -> CGRect
    private var isDown = false
    private var relativeDown = false
    private var scrollRemainder = CGPoint.zero
    private var directScrollRemainder = CGPoint.zero
    private var pointerRemainder = CGPoint.zero
    private let displayPixelsWide: (CGDirectDisplayID) -> Int
    private var relativeLedger = RelativePointerLedger()
    private(set) var lastPostedPoint:CGPoint?
    private let inputLock = NSRecursiveLock()
    private let cursorProvider: () -> CGPoint
    private let displaysProvider: () -> [CGRect]
    private let postEvent: (CGEvent) -> Void
    private var penDown = false
    // A real event source (vs nil) plus non-zero clickState on down/up: menu
    // tracking treats sourceless/zero-click synthetic clicks as malformed — menus
    // open but their tracking session breaks, leaving zombie menu windows
    // composited on the display (visible in the stream, unclickable).
    private let source = CGEventSource(stateID: .hidSystemState)
    // Synthetic SideExtend tablet — conspicuous in logs; not Wacom (0x056A) or
    // typical small driver IDs (1, 2, …).
    private let tabletVendorID: Int64 = 0x0D15       // "ODIS"
    private let tabletProductID: Int64 = 0x0101
    private let deviceID: Int64 = 424242
    private let pointerID: Int64 = 0x0D02              // pen tip
    private let vendorPointerType: Int64 = 0x0802    // Grip Pen (what apps expect)
    private let capabilityMask: Int64 = 0x05C7       // pressure + tilt + rotation + buttons
    private var inRange = false

    // Pencil-only synthetic click counting — tablet events don't get click
    // state from the Window Server, so we mirror macOS double-click prefs here.
    private struct PenClickSession {
        let downLocation: CGPoint
        let clickState: Int
    }

    private struct PenCompletedClick {
        let upTime: CFAbsoluteTime
        let downLocation: CGPoint
        let clickState: Int
    }

    private var penClickSession: PenClickSession?
    private var penLastClick: PenCompletedClick?

    init(displayID: CGDirectDisplayID,
         boundsProvider: @escaping (CGDirectDisplayID) -> CGRect = { CGDisplayBounds($0) },
         cursorProvider: @escaping () -> CGPoint = { CGEvent(source: nil)?.location ?? .zero },
         displaysProvider: @escaping () -> [CGRect] = InputInjector.activeDisplayBounds,
         post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
         pixelsWideProvider: @escaping (CGDirectDisplayID) -> Int = { CGDisplayPixelsWide($0) }) {
        self.displayID = displayID; self.displayBounds = boundsProvider; self.cursorProvider = cursorProvider
        self.displayPixelsWide = pixelsWideProvider
        self.displaysProvider = displaysProvider; self.postEvent = post
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 64), count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    func handleTrackpad(action: String, dx: Double = 0, dy: Double = 0, count: Int = 1) {
        inputLock.lock(); defer { inputLock.unlock() }
        let observed = cursorProvider()
        let now = ProcessInfo.processInfo.systemUptime
        let current = relativeLedger.base(observation:observed,now:now)
        guard current.x.isFinite, current.y.isFinite else { return }
        switch action {
        case "move":
            guard dx.isFinite, dy.isFinite, abs(dx) <= 2048, abs(dy) <= 2048 else { return }
            // Keep sub-point gain across packets without remembering an absolute
            // pointer position: a physical mouse can move it at any time.
            pointerRemainder.x += dx; pointerRemainder.y += dy
            func step(_ value: CGFloat) -> CGFloat { (value + (value >= 0 ? 1e-9 : -1e-9)).rounded(.towardZero) }
            let x = step(pointerRemainder.x), y = step(pointerRemainder.y)
            pointerRemainder.x -= x; pointerRemainder.y -= y
            if abs(pointerRemainder.x) < 1e-9 { pointerRemainder.x = 0 }
            if abs(pointerRemainder.y) < 1e-9 { pointerRemainder.y = 0 }
            guard x != 0 || y != 0,
                  let point = PointerMapping.relative(from:current,dx:x,dy:y,displays:displaysProvider()) else { return }
            postMouse(relativeDown ? .leftMouseDragged : .mouseMoved, point: point,
                      movement:CGPoint(x:point.x-current.x,y:point.y-current.y))
            relativeLedger.posted(point,now:now)
        case "dragBegan":
            guard !relativeDown else { return }
            relativeDown = true; postMouse(.leftMouseDown, point: current)
        case "dragEnded":
            guard relativeDown else { return }
            relativeDown = false; postMouse(.leftMouseUp, point: current)
        case "click", "secondaryClick":
            guard !relativeDown else { return }
            let right = action == "secondaryClick"
            postMouse(right ? .rightMouseDown : .leftMouseDown, point: current, clicks: max(1,min(2,count)), right: right)
            postMouse(right ? .rightMouseUp : .leftMouseUp, point: current, clicks: max(1,min(2,count)), right: right)
        case "scroll":
            guard dx.isFinite, dy.isFinite, abs(dx) <= 2048, abs(dy) <= 2048 else { return }
            scrollRemainder.x += dx; scrollRemainder.y += dy
            let x = scrollRemainder.x.rounded(), y = scrollRemainder.y.rounded()
            scrollRemainder.x -= x; scrollRemainder.y -= y
            guard x != 0 || y != 0,
                  let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                      wheel1: Int32(y), wheel2: Int32(x), wheel3: 0) else { return }
            postEvent(event)
        default: break
        }
    }
    /// Public key events only. Allocate both halves before posting, never leave
    /// a modifier/key held across packets or grant broader input permissions.
    @discardableResult
    func handleGestureShortcut(_ shortcut:TrackpadShortcut,post:((CGEvent)->Void)? = nil,secureInput:Bool = IsSecureEventInputEnabled()) -> Bool {
        guard shortcut.valid,!secureInput,post != nil || Self.hasInputControlPermission,
              let down = CGEvent(keyboardEventSource:source,virtualKey:shortcut.key,keyDown:true),
              let up = CGEvent(keyboardEventSource:source,virtualKey:shortcut.key,keyDown:false) else { return false }
        releaseAll();inputLock.lock();defer { inputLock.unlock() }
        down.flags = CGEventFlags(rawValue:shortcut.modifiers);up.flags = down.flags
        for event in [down,up] { if let post { post(event) } else { postEvent(event) } }
        return true
    }
    /// Unicode is posted to the already-focused app, without AX writes, clipboard
    /// operations or activating another application. No text is retained or logged.
    @discardableResult
    func handleKeyboard(_ command: KeyboardCommand, to pid: pid_t, post: ((CGEvent) -> Void)? = nil) -> Bool {
        guard post != nil || Self.hasInputControlPermission else { return false }
        var success = true
        inputLock.lock(); defer { inputLock.unlock() }
        func key(_ code: CGKeyCode, unicode: [UniChar]? = nil) {
            guard let down = CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:true),
                  let up = CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:false) else { success = false; return }
            down.flags = []; up.flags = []
            if let unicode {
                unicode.withUnsafeBufferPointer { buffer in
                    down.keyboardSetUnicodeString(stringLength:buffer.count,unicodeString:buffer.baseAddress!)
                    up.keyboardSetUnicodeString(stringLength:buffer.count,unicodeString:buffer.baseAddress!)
                }
            }
            for event in [down,up] { if let post { post(event) } else { event.postToPid(pid) } }
        }
        switch command.action {
        case .backspace: key(51)
        case .enter: key(36)
        case .text:
            guard let text = command.text, !text.isEmpty else { return false }
            for chunk in KeyboardText.chunks(text) { key(0,unicode:chunk) }
        }
        return success
    }
    private func postMouse(_ type: CGEventType, point: CGPoint, clicks: Int = 1, right: Bool = false,
                           movement:CGPoint? = nil) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: right ? .right : .left) else { return }
        lastPostedPoint = point
        if let movement {
            // Public Quartz relative fields must agree with the mapped global
            // position, including display-edge clipping. Window tracking can
            // consume deltas instead of only the absolute cursor location.
            event.setIntegerValueField(.mouseEventDeltaX,value:Int64(exactly:movement.x.rounded()) ?? 0)
            event.setIntegerValueField(.mouseEventDeltaY,value:Int64(exactly:movement.y.rounded()) ?? 0)
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks)); postEvent(event)
    }
    func pointerReadbackMetrics() -> RelativePointerLedger.Metrics {
        inputLock.lock();defer { inputLock.unlock() }
        return relativeLedger.metricsSnapshot(reset:true)
    }
    /// Posts releases only for inputs this injector pressed; idle cleanup posts nothing.
    func releaseAll() {
        inputLock.lock(); defer { inputLock.unlock() }
        let releasePoint = relativeLedger.base(observation:cursorProvider(),now:ProcessInfo.processInfo.systemUptime)
        scrollRemainder = .zero; directScrollRemainder = .zero; pointerRemainder = .zero
        relativeLedger.reset()
        if isDown || relativeDown { postMouse(.leftMouseUp, point: releasePoint, clicks: 0) }
        isDown = false; relativeDown = false
        if penDown { postTabletPoint(phase: .up, x: nil, y: nil, pressure: 0, tiltX: 0, tiltY: 0, rotation: 0) }
        penDown = false
        if inRange { setProximity(entering: false, at: cursorProvider()) }
    }
    deinit { releaseAll() }

    /// Touch control posts CGEvents; check the permission for that capability,
    /// rather than trust for reading/manipulating other apps' AX element trees.
    static var hasInputControlPermission: Bool { CGPreflightPostEventAccess() }

    static var permissionSettingsName: String {
        if #available(macOS 27, *) { return "Device Control and Data Access" }
        return "Accessibility"
    }

    static func requestInputControlPermission() -> Bool {
        let granted = CGRequestPostEventAccess()
        if !granted {
            Log.info("Event-posting permission missing — system request issued")
        }
        return granted
    }

    /// x/y are normalized [0,1] in video space (origin top-left).
    func handleTouch(phase: String, x: Double, y: Double) {
        inputLock.lock(); defer { inputLock.unlock() }
        let bounds = displayBounds(displayID)   // global CG coords, y-down
        let point = CGPoint(
            x: bounds.origin.x + x * bounds.width,
            y: bounds.origin.y + y * bounds.height
        )

        let type: CGEventType
        // Click count on the release. A cancel means "a second finger joined,
        // this was a scroll, not a tap" — but there is no CGEvent for undoing a
        // press, and a plain up over the press point is indistinguishable from a
        // click, so every two-finger scroll opened whatever was under finger one.
        // Releasing with clickCount 0 keeps the button state honest while telling
        // AppKit and WebKit not to synthesize a click. Only the cancel path gets
        // 0: a zero-click *down* is what breaks menu tracking (see above).
        var clickState = 1
        switch phase {
        case "began":
            type = .leftMouseDown
            isDown = true
        case "moved":
            type = isDown ? .leftMouseDragged : .mouseMoved
        case "ended":
            guard isDown else { return }   // spurious up without a down
            type = .leftMouseUp
            isDown = false
        case "cancelled":
            guard isDown else { return }
            type = .leftMouseUp
            isDown = false
            clickState = 0
        default:
            return
        }

        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        lastPostedPoint = point
        relativeLedger.posted(point,now:ProcessInfo.processInfo.systemUptime)
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        postEvent(event)
    }

    /// dx/dy in display pixels, natural-scrolling sign from the phone.
    /// Scroll events take points, so convert via the display's pixel scale.
    func handleScroll(dx: Double, dy: Double) {
        inputLock.lock(); defer { inputLock.unlock() }
        let bounds = displayBounds(displayID)
        let pixels = bounds.width > 0 ? Double(displayPixelsWide(displayID)) : 0
        let scale = bounds.width > 0 && pixels > 0 ? pixels / bounds.width : 2
        guard dx.isFinite, dy.isFinite, scale.isFinite, scale > 0 else { return }
        // Keep the sub-point remainder: a slow two-finger scroll is many
        // fractional deltas, and rounding each one alone posts nothing.
        directScrollRemainder.x += dx / scale; directScrollRemainder.y += dy / scale
        func step(_ value: CGFloat) -> CGFloat { (value + (value >= 0 ? 1e-9 : -1e-9)).rounded(.towardZero) }
        let x = step(directScrollRemainder.x), y = step(directScrollRemainder.y)
        directScrollRemainder.x -= x; directScrollRemainder.y -= y
        if abs(directScrollRemainder.x) < 1e-9 { directScrollRemainder.x = 0 }
        if abs(directScrollRemainder.y) < 1e-9 { directScrollRemainder.y = 0 }
        guard x != 0 || y != 0, abs(x) < Double(Int32.max), abs(y) < Double(Int32.max),
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(y),
                                  wheel2: Int32(x),
                                  wheel3: 0) else { return }
        postEvent(event)
    }

    func handleProximity(entering: Bool, x: Double, y: Double) {
        inputLock.lock(); defer { inputLock.unlock() }
        setProximity(entering: entering, at: screenPoint(nx: x, ny: y))
    }

    func handlePencil(phase: String, x: Double, y: Double,
                      pressure: Double, azimuth: Double, altitude: Double,
                      rotation: Double) {
        inputLock.lock(); defer { inputLock.unlock() }
        // TODO: Wire Apple Pencil Pro barrel roll (UIKit rollAngle) once hardware
        // is available for testing. rotation on the wire is always 0 for now.
        _ = rotation
        let p = screenPoint(nx: x, ny: y)
        if phase == "down", !inRange {
            setProximity(entering: true, at: p)
        }
        let (tiltX, tiltY) = deriveTilt(azimuth: azimuth, altitude: altitude)

        switch phase {
        case "down":
            postTabletPoint(phase: .down, x: x, y: y, pressure: pressure,
                            tiltX: tiltX, tiltY: tiltY, rotation: 0)
            penDown = true
        case "move":
            if penDown {
                postTabletPoint(phase: .drag, x: x, y: y, pressure: pressure,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
            } else {
                postTabletPoint(phase: .hover, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
            }
        case "up":
            if penDown {
                postTabletPoint(phase: .up, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
                penDown = false
            }
        case "hover":
            if penDown {
                postTabletPoint(phase: .up, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
                penDown = false
            }
            postTabletPoint(phase: .hover, x: x, y: y, pressure: 0,
                            tiltX: tiltX, tiltY: tiltY, rotation: 0)
        default:
            return
        }
    }

    private func setProximity(entering: Bool, at p: CGPoint) {
        guard entering != inRange else { return }
        inRange = entering
        postProximityEvent(entering: entering, at: p)
    }

    private func postProximityEvent(entering: Bool, at p: CGPoint) {
        guard let ev = CGEvent(source: source) else { return }
        ev.type = .tabletProximity
        ev.location = p
        ev.setIntegerValueField(.tabletProximityEventVendorID, value: tabletVendorID)
        ev.setIntegerValueField(.tabletProximityEventTabletID, value: tabletProductID)
        ev.setIntegerValueField(.tabletProximityEventPointerID, value: pointerID)
        ev.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
        ev.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 0)
        ev.setIntegerValueField(.tabletProximityEventPointerType, value: entering ? 1 : 0)
        ev.setIntegerValueField(.tabletProximityEventVendorPointerType, value: vendorPointerType)
        ev.setIntegerValueField(.tabletProximityEventCapabilityMask, value: capabilityMask)
        ev.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        ev.flags = .maskNonCoalesced
        postEvent(ev)
    }

    private enum PointPhase { case down, drag, up, hover }

    private func postTabletPoint(phase: PointPhase, x: Double?, y: Double?,
                                 pressure: Double, tiltX: Double, tiltY: Double,
                                 rotation: Double) {
        let p: CGPoint
        if let nx = x, let ny = y { p = screenPoint(nx: nx, ny: ny) }
        else { p = currentCursor() }

        let type: CGEventType
        switch phase {
        case .down:  type = .leftMouseDown
        case .drag:  type = .leftMouseDragged
        case .up:    type = .leftMouseUp
        case .hover: type = .mouseMoved
        }

        guard let ev = CGEvent(mouseEventSource: source, mouseType: type,
                               mouseCursorPosition: p, mouseButton: .left) else { return }
        ev.setIntegerValueField(.mouseEventDeltaX, value: 0)
        ev.setIntegerValueField(.mouseEventDeltaY, value: 0)
        ev.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        ev.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
        ev.setDoubleValueField(.mouseEventPressure, value: pressure)
        ev.setIntegerValueField(.tabletEventPointPressure, value: Int64((pressure * 65535.0).rounded()))
        ev.setDoubleValueField(.tabletEventTiltX, value: tiltX)
        ev.setDoubleValueField(.tabletEventTiltY, value: tiltY)
        ev.setDoubleValueField(.tabletEventRotation, value: rotation)
        switch phase {
        case .down:
            ev.setIntegerValueField(.mouseEventClickState, value: Int64(beginPenClickSession(at: p)))
        case .up:
            ev.setIntegerValueField(.mouseEventClickState, value: Int64(finishPenClickSession(at: p)))
        case .drag, .hover:
            break
        }
        ev.flags = .maskNonCoalesced
        postEvent(ev)
    }

    private func penClickStateForMouseDown(at point: CGPoint) -> Int {
        let now = CFAbsoluteTimeGetCurrent()
        guard let last = penLastClick,
              now - last.upTime <= SystemClickMetrics.interval else {
            return 1
        }
        let dx = point.x - last.downLocation.x
        let dy = point.y - last.downLocation.y
        guard hypot(dx, dy) <= SystemClickMetrics.distance else { return 1 }
        return last.clickState + 1
    }

    private func beginPenClickSession(at point: CGPoint) -> Int {
        let state = penClickStateForMouseDown(at: point)
        penClickSession = PenClickSession(downLocation: point, clickState: state)
        return state
    }

    /// Returns click state for the matching pen mouse-up. Extends the multi-click
    /// chain only when down→up displacement is within the system threshold.
    private func finishPenClickSession(at upLocation: CGPoint) -> Int {
        guard let session = penClickSession else { return 1 }
        penClickSession = nil

        let dx = upLocation.x - session.downLocation.x
        let dy = upLocation.y - session.downLocation.y
        if hypot(dx, dy) <= SystemClickMetrics.distance {
            penLastClick = PenCompletedClick(
                upTime: CFAbsoluteTimeGetCurrent(),
                downLocation: session.downLocation,
                clickState: session.clickState
            )
        } else {
            penLastClick = nil
        }
        return session.clickState
    }

    /// UIKit altitude is radians from the surface (pi/2 = upright); CGEvent tilt
    /// is a unit vector in -1...1, so normalize rather than pass radians through
    /// (unnormalized, a flat pen reads 1.57 and apps that scale tilt by 90 report
    /// impossible angles).
    private func deriveTilt(azimuth: Double, altitude: Double) -> (Double, Double) {
        let mag = min(max(0, Double.pi / 2 - altitude) / (Double.pi / 2), 1)
        return (sin(azimuth) * mag, cos(azimuth) * mag)
    }

    private func screenPoint(nx: Double, ny: Double) -> CGPoint {
        let bounds = displayBounds(displayID)
        return CGPoint(x: bounds.minX + nx * bounds.width,
                       y: bounds.minY + ny * bounds.height)
    }

    private func currentCursor() -> CGPoint {
        cursorProvider()
    }
}
