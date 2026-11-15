import Foundation
import CoreGraphics
import ColorSync

/// Arrangement uses public Quartz APIs only. The injected test backend never
/// enters this type; reading topology is separate from mutating configuration.
enum PublicDisplayArrangement {
    enum Failure: Error { case topologyChanged,begin(Int32),origin(Int32),complete(Int32) }
    private static let queue = DispatchQueue(label:"DuoDisplay.display-arrangement",qos:.userInitiated)
    static func read() -> PhoneDisplayTopology {
        var count:UInt32 = 0
        guard CGGetActiveDisplayList(0,nil,&count) == .success, count > 0 else { return .init(main:0,displays:[]) }
        var ids = [CGDirectDisplayID](repeating:0,count:Int(count))
        guard CGGetActiveDisplayList(count,&ids,&count) == .success else { return .init(main:0,displays:[]) }
        let main = CGMainDisplayID()
        var nodes: [PhoneDisplay] = []
        let ordered = Array(ids.prefix(Int(count))).sorted()
        for (index,id) in ordered.enumerated() {
            let bounds = CGDisplayBounds(id)
            let identity: String
            if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
                identity = CFUUIDCreateString(nil,uuid) as String
            } else { identity = "display-\(id)" }
            let name = id == main ? "Mac main display" : "Display \(index+1)"
            let displayMode = CGDisplayCopyDisplayMode(id)
            let scale = backingScale(logicalWidth:displayMode?.width ?? 0,pixelWidth:displayMode?.pixelWidth ?? 0)
            let rotation: Double = CGDisplayRotation(id)
            let mode = UInt32(bitPattern:displayMode?.ioDisplayModeID ?? 0)
            let mirrored = CGDisplayIsInMirrorSet(id) != 0
            nodes.append(PhoneDisplay(id:id,identity:identity,name:name,frame:bounds,scale:scale,rotation:rotation,mode:mode,mirrored:mirrored))
        }
        return .init(main:main,displays:nodes)
    }
    static func backingScale(logicalWidth:Int,pixelWidth:Int) -> Double {
        guard logicalWidth > 0,pixelWidth > 0 else { return 1 }
        return Double(pixelWidth)/Double(logicalWidth)
    }
    static func apply(from before:PhoneDisplayTopology,to desired:PhoneDisplayTopology,authorized:@escaping () -> Bool = { true }) async throws {
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            queue.async {
                do {
                    guard authorized(), read() == before, before.sameHardware(as:desired),
                          PhoneArrangementGeometry.validLayout(desired) else { throw Failure.topologyChanged }
                    var config:CGDisplayConfigRef?
                    let begin = CGBeginDisplayConfiguration(&config)
                    guard begin == .success, let config else { throw Failure.begin(begin.rawValue) }
                    // Explicitly pin every unrelated display at its existing
                    // origin: Quartz may otherwise retile unspecified displays.
                    for display in desired.displays {
                        let origin = display.frame.origin
                        let result = CGConfigureDisplayOrigin(config,display.id,Int32(origin.x.rounded()),Int32(origin.y.rounded()))
                        if result != .success { CGCancelDisplayConfiguration(config); throw Failure.origin(result.rawValue) }
                    }
                    guard authorized(), read() == before else { CGCancelDisplayConfiguration(config); throw Failure.topologyChanged }
                    let complete = CGCompleteDisplayConfiguration(config,.forSession)
                    guard complete == .success else { throw Failure.complete(complete.rawValue) }
                    continuation.resume()
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
}
