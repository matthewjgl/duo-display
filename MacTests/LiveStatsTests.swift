import XCTest

/// The `live` control message the phone sends ~1 Hz and the Mac shows in its
/// menu bar (PROTOCOL.md 6.1).
final class LiveStatsTests: XCTestCase {
    private func parse(_ json: String) throws -> LiveStats? {
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return LiveStats.parse(obj)
    }

    func testFullMessage() throws {
        let s = try XCTUnwrap(parse(#"{"type":"live","fps":60,"ms":18.4,"p95":27.1,"kind":"glass"}"#))
        XCTAssertEqual(s.fps, 60)
        XCTAssertEqual(s.latencyMs ?? 0, 18.4, accuracy: 0.001)
        XCTAssertEqual(s.p95Ms ?? 0, 27.1, accuracy: 0.001)
        XCTAssertEqual(s.kind, .glass)
        XCTAssertEqual(LiveStats.summary(s), "18 ms · 60 fps")
    }

    func testFpsOnlyBeforeClockSync() throws {
        // No `ms` until the ping/pong offset is known: latency stays unknown.
        let s = try XCTUnwrap(parse(#"{"type":"live","fps":59}"#))
        XCTAssertNil(s.latencyMs)
        XCTAssertEqual(s.kind, .unknown)
        XCTAssertEqual(LiveStats.summary(s), "— ms · 59 fps")
        XCTAssertEqual(LiveStats.measurementLabel(s), "no reading yet")
    }

    func testFractionalFpsRounds() throws {
        let s = try XCTUnwrap(parse(#"{"type":"live","fps":59.6}"#))
        XCTAssertEqual(s.fps, 60)
    }

    func testOtherTypesAndEmptyMessagesAreIgnored() throws {
        XCTAssertNil(try parse(#"{"type":"stats","fps":60,"ms":10}"#))
        XCTAssertNil(try parse(#"{"type":"live"}"#))
        XCTAssertNil(try parse(#"{"fps":60}"#))
    }

    func testBadValuesAreDroppedNotTrusted() throws {
        let s = try XCTUnwrap(parse(#"{"type":"live","fps":60,"ms":-5,"p95":10}"#))
        XCTAssertNil(s.latencyMs)
        XCTAssertNil(s.p95Ms)
        XCTAssertNil(try parse(#"{"type":"live","fps":"fast","ms":99999}"#))
        XCTAssertNil(try parse(#"{"type":"live","fps":5000}"#))
    }

    func testWrongTypesDoNotCrash() throws {
        XCTAssertNil(try parse(#"{"type":"live","fps":null,"ms":[1],"kind":7}"#))
        let s = try XCTUnwrap(parse(#"{"type":"live","fps":30,"kind":"mystery"}"#))
        XCTAssertEqual(s.kind, .unknown)
    }

    func testStaleReadingShowsDashes() {
        let s = LiveStats(fps: 60, latencyMs: 18, p95Ms: nil, kind: .handoff)
        XCTAssertEqual(LiveStats.summary(s, fresh: false), "— ms · — fps")
        XCTAssertEqual(LiveStats.summary(nil), "— ms · — fps")
        XCTAssertEqual(LiveStats.measurementLabel(s), "Mac capture → handed to display")
    }
}
