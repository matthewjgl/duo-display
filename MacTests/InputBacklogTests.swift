import XCTest
import CoreGraphics

/// Review findings C1 (outbox overflow) and C2 (direct-touch scroll remainder).
final class InputBacklogTests: XCTestCase {
    private func decoded(_ frame: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: frame.dropFirst(4)) as? [String: Any])
    }
    private func touch(_ phase: String, _ x: Double) -> [String: Any] {
        ["type": "touch", "phase": phase, "x": x, "y": 0.5]
    }

    /// A held socket write while the clock advances past the merge window:
    /// every move is a separate pending item, which used to cancel the
    /// connection at 128 items during an ordinary Direct Touch drag.
    func testHeldWriterDirectTouchDragNeverDisconnectsAndKeepsFinalPositionAndRelease() throws {
        var writes: [Data] = [], callbacks: [(Bool) -> Void] = [], failures = 0, now = 0.0
        let box = InputControlOutbox(clock: { now }, write: { writes.append($0); callbacks.append($1) },
                                     failure: { failures += 1 })
        XCTAssertTrue(box.enqueue(touch("began", 0)))
        for i in 1...500 {
            now += 0.03 // beyond the 25 ms adjacency window
            XCTAssertTrue(box.enqueue(touch("moved", Double(i) / 500)), "move \(i) rejected")
        }
        XCTAssertTrue(box.enqueue(touch("ended", 1)))
        XCTAssertEqual(failures, 0)
        while !callbacks.isEmpty { callbacks.removeFirst()(true) }
        let objects = try writes.map(decoded)
        XCTAssertLessThanOrEqual(objects.count, InputControlOutbox.capacity + 2, "bounded writes")
        XCTAssertEqual(objects.first?["phase"] as? String, "began")
        XCTAssertEqual(objects.last?["phase"] as? String, "ended")
        let moved = objects.filter { $0["phase"] as? String == "moved" }
        XCTAssertEqual(moved.last?["x"] as? Double, 1, "latest absolute position survives")
        let xs = moved.compactMap { $0["x"] as? Double }
        XCTAssertEqual(xs, xs.sorted(), "positions stay in order")
        XCTAssertEqual(failures, 0)
    }

    func testHeldWriterScrollIsSummedExactlyAndBarriersSurvive() throws {
        var writes: [Data] = [], callbacks: [(Bool) -> Void] = [], failures = 0, now = 0.0
        let box = InputControlOutbox(clock: { now }, write: { writes.append($0); callbacks.append($1) },
                                     failure: { failures += 1 })
        XCTAssertTrue(box.enqueue(["type": "inputReset"]))
        for _ in 0..<400 {
            now += 0.03
            XCTAssertTrue(box.enqueue(["type": "scroll", "dx": 0.5, "dy": -1.0]))
        }
        XCTAssertTrue(box.enqueue(["type": "trackpad", "action": "click", "count": 1]))
        XCTAssertEqual(failures, 0)
        while !callbacks.isEmpty { callbacks.removeFirst()(true) }
        let objects = try writes.map(decoded)
        let scrolls = objects.filter { $0["type"] as? String == "scroll" }
        XCTAssertEqual(scrolls.compactMap { $0["dy"] as? Double }.reduce(0, +), -400, accuracy: 1e-9)
        XCTAssertEqual(scrolls.compactMap { $0["dx"] as? Double }.reduce(0, +), 200, accuracy: 1e-9)
        XCTAssertEqual(objects.first?["type"] as? String, "inputReset")
        XCTAssertEqual(objects.last?["action"] as? String, "click")
    }

    func testOverflowShedsTelemetryAndPencilMotionBeforeFailing() throws {
        var writes: [Data] = [], callbacks: [(Bool) -> Void] = [], failures = 0, now = 0.0
        let box = InputControlOutbox(clock: { now }, write: { writes.append($0); callbacks.append($1) },
                                     failure: { failures += 1 })
        XCTAssertTrue(box.enqueue(["type": "pencil", "phase": "down", "x": 0.0, "y": 0.0]))
        for i in 0..<300 {
            now += 0.03
            if i % 50 == 0 { XCTAssertTrue(box.enqueue(["type": "live", "fps": i])) }
            XCTAssertTrue(box.enqueue(["type": "pencil", "phase": "move", "x": Double(i), "y": 0.0]))
        }
        XCTAssertTrue(box.enqueue(["type": "pencil", "phase": "up", "x": 299.0, "y": 0.0]))
        XCTAssertEqual(failures, 0)
        while !callbacks.isEmpty { callbacks.removeFirst()(true) }
        let phases = try writes.map(decoded).filter { $0["type"] as? String == "pencil" }.compactMap { $0["phase"] as? String }
        XCTAssertEqual(phases.first, "down"); XCTAssertEqual(phases.last, "up")
        XCTAssertEqual(phases.filter { $0 == "down" }.count, 1)
        XCTAssertEqual(phases.filter { $0 == "up" }.count, 1)
    }

    /// The fail-closed path is preserved when nothing disposable exists.
    func testOnlyBarriersStillFailClosed() {
        var failures = 0
        let box = InputControlOutbox(write: { _, _ in }, failure: { failures += 1 })
        for _ in 0..<130 { box.enqueue(["type": "trackpad", "action": "click", "count": 1]) }
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(box.enqueue(["type": "touch", "phase": "moved", "x": 0.5, "y": 0.5]))
    }

    func testKeyboardIntentReleaseAndProbesAreNeverMergedOrShed() {
        XCTAssertFalse(InputControlOutbox.isDisposable(["type": "touch", "phase": "ended"]))
        XCTAssertFalse(InputControlOutbox.isDisposable(["type": "touch", "phase": "began"]))
        XCTAssertFalse(InputControlOutbox.isDisposable(["type": "trackpad", "action": "move", "probe": 3]))
        XCTAssertFalse(InputControlOutbox.isDisposable(["type": "keyboardInput"]))
        XCTAssertFalse(InputControlOutbox.isDisposable(["type": "hello"]))
        XCTAssertFalse(InputControlOutbox.isDisposable(["type": "pencil", "phase": "up"]))
        XCTAssertTrue(InputControlOutbox.isDisposable(["type": "touch", "phase": "moved"]))
    }

    // MARK: C2

    func testSlowDirectTouchScrollAccumulatesSubPixelDeltas() {
        var events: [CGEvent] = []
        let input = InputInjector(displayID: 1, boundsProvider: { _ in CGRect(x: 0, y: 0, width: 1000, height: 800) },
                                  cursorProvider: { .zero }, displaysProvider: { [CGRect(x: 0, y: 0, width: 1000, height: 800)] },
                                  post: { events.append($0) }, pixelsWideProvider: { _ in 2000 })
        // 0.6 video pixels = 0.3 points per event at 2x: rounding each alone posted nothing.
        for _ in 0..<20 { input.handleScroll(dx: 0, dy: 0.6) }
        let total = events.map { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) }.reduce(0, +)
        XCTAssertEqual(total, 6)
        events.removeAll()
        for _ in 0..<20 { input.handleScroll(dx: 0, dy: -0.6) }
        XCTAssertEqual(events.map { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) }.reduce(0, +), -6)
        events.removeAll()
        input.handleScroll(dx: .infinity, dy: 1)
        XCTAssertTrue(events.isEmpty, "non-finite deltas are ignored")
        input.handleScroll(dx: 0, dy: 1.2)   // 0.6 pt remainder kept
        input.releaseAll()                    // remainder cleared with the session
        input.handleScroll(dx: 0, dy: 1.2)
        XCTAssertTrue(events.isEmpty)
    }
}

extension InputBacklogTests {
    func testAggregateQueueMetricsMeasureStallWithoutChangingOrderingOrBatching() throws {
        var now = 0.0, callbacks: [(Bool)->Void] = [], writes: [Data] = []
        let box = InputControlOutbox(clock: { now }, write: { writes.append($0); callbacks.append($1) }, failure: { XCTFail() })
        box.enqueue(["type":"trackpad","action":"move","dx":1.0,"dy":0.0])
        now = 0.01; box.enqueue(["type":"trackpad","action":"move","dx":2.0,"dy":0.0])
        now = 0.02; box.enqueue(["type":"trackpad","action":"move","dx":3.0,"dy":0.0])
        box.enqueue(["type":"trackpad","action":"dragEnded"])
        XCTAssertEqual(box.metricsSnapshot().pendingNow,3)
        now = 0.08
        while !callbacks.isEmpty { callbacks.removeFirst()(true) }
        let measured = box.metricsSnapshot(reset:true)
        XCTAssertEqual(measured.enqueued,4);XCTAssertEqual(measured.writes,3);XCTAssertEqual(measured.merged,1)
        XCTAssertEqual(measured.pendingNow,0);XCTAssertEqual(measured.peakPending,2)
        XCTAssertEqual(measured.maxWaitMs,70,accuracy:0.001)
        XCTAssertEqual(measured.waitP95Ms,70,accuracy:0.001)
        XCTAssertEqual(try writes.map(decoded).compactMap{$0["dx"] as? Double}.reduce(0,+),6)
        XCTAssertEqual(try decoded(writes.last!)["action"] as? String,"dragEnded")
        XCTAssertEqual(box.metricsSnapshot().writes,0)
        // An idle healthy writer must write immediately; metrics add no timer.
        box.enqueue(["type":"trackpad","action":"click"])
        XCTAssertEqual(writes.count,4)
    }
}
