import XCTest
import Network
import AVFoundation

/// Review findings C5 (keyboard notice expiry), C7 (cross-thread receiver state)
/// and C8 (unbounded announced frame length).
final class ReceiverRobustnessTests: XCTestCase {
    func testExpiringNoticeClearsOnlyItsOwnMessage() {
        var notice = ExpiringNotice()
        let first = notice.show("first")
        XCTAssertEqual(notice.text, "first")
        let second = notice.show("second")
        notice.expire(try! XCTUnwrap(first))
        XCTAssertEqual(notice.text, "second", "an older expiry never hides a newer message")
        notice.expire(try! XCTUnwrap(second))
        XCTAssertNil(notice.text)
        XCTAssertNil(notice.show(nil))
        XCTAssertNil(notice.text)
        XCTAssertGreaterThan(ExpiringNotice.lifetime, 2)
    }

    private func dial(_ port: UInt16) -> NWConnection {
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        c.start(queue: DispatchQueue(label: "test.client"))
        return c
    }
    private func makeReceiver() -> (StreamReceiver, UInt16) {
        let receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(), deviceKind: "iPhone",
                                      fallbackServiceName: "Robustness QA " + UUID().uuidString.prefix(6))
        receiver.setPanel(pixelsWide: 1170, pixelsHigh: 2532, scale: 3)
        let port = Self.freePort()
        receiver.start(port: port)
        return (receiver, port)
    }
    /// Ask using the same dual-stack wildcard scope as NWListener. An IPv4
    /// loopback-only bind can choose a port still occupied by an IPv6 listener
    /// or a recently closed wildcard session, especially under instrumentation.
    static func freePort() -> UInt16 {
        let fd = socket(AF_INET6, SOCK_STREAM, 0); defer { close(fd) }
        var dualStack: Int32 = 0
        _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &dualStack, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6(); addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return UInt16(bigEndian: addr.sin6_port)
    }
    /// Reads length-prefixed JSON frames until `until` returns true or EOF.
    private func readFrames(_ c: NWConnection, timeout: TimeInterval,
                            until: @escaping ([String: Any]) -> Bool) -> (objects: [[String: Any]], closed: Bool) {
        var buffer = Data(), objects: [[String: Any]] = [], closed = false
        let done = DispatchSemaphore(value: 0)
        func next() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
                if let data { buffer.append(data) }
                while buffer.count >= 4 {
                    let n = buffer.prefix(4).withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
                    guard buffer.count >= 4 + n else { break }
                    let payload = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + 4 + n))
                    buffer = Data(buffer.dropFirst(4 + n))
                    if let o = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                        objects.append(o); if until(o) { done.signal(); return }
                    }
                }
                if complete || error != nil { closed = true; done.signal(); return }
                next()
            }
        }
        next()
        _ = done.wait(timeout: .now() + timeout)
        return (objects, closed)
    }

    func testOversizedAnnouncedFrameDropsConnectionInsteadOfBuffering() throws {
        let (receiver, port) = makeReceiver()
        defer { receiver.stop() }
        Thread.sleep(forTimeInterval: 0.5)
        let c = dial(port); defer { c.cancel() }
        let hello = readFrames(c, timeout: 5) { $0["type"] as? String == "hello" }
        XCTAssertTrue(hello.objects.contains { $0["type"] as? String == "hello" }, "receiver greets the sender")
        var huge = UInt32(StreamReceiver.maxFrameBytes + 1).bigEndian
        var frame = Data(bytes: &huge, count: 4); frame.append(Data(repeating: 1, count: 1024))
        c.send(content: frame, completion: .contentProcessed { _ in })
        let after = readFrames(c, timeout: 5) { _ in false }
        XCTAssertTrue(after.closed, "receiver must close a connection announcing an oversized frame")
    }

    /// App-thread panel updates race the receive queue. Every hello on the wire
    /// must carry one consistent panel (never width from one update and height
    /// from another), and the final hello must reflect the last update.
    func testConcurrentPanelUpdatesSendConsistentHellos() throws {
        let (receiver, port) = makeReceiver()
        defer { receiver.stop() }
        Thread.sleep(forTimeInterval: 0.5)
        let c = dial(port); defer { c.cancel() }
        _ = readFrames(c, timeout: 5) { $0["type"] as? String == "hello" }
        let sizes = (1...40).map { (w: 1000 + $0, h: 2000 + $0) }
        DispatchQueue.concurrentPerform(iterations: sizes.count) { i in
            let s = sizes[i]
            receiver.setPanel(pixelsWide: s.w, pixelsHigh: s.h, scale: 3)
            _ = receiver.setDecodeLimits(maxEncodeWide: nil, maxEncodeHigh: nil, hevc: nil)
            receiver.setDecodeBudget(maxPixelsPerSecond: 1_000_000 + i)
        }
        receiver.setPanel(pixelsWide: 1290, pixelsHigh: 2796, scale: 3)
        let result = readFrames(c, timeout: 5) { $0["type"] as? String == "hello" && $0["pixelsWide"] as? Int == 1290 }
        let hellos = result.objects.filter { $0["type"] as? String == "hello" }
        XCTAssertFalse(hellos.isEmpty)
        for hello in hellos {
            let w = try XCTUnwrap(hello["pixelsWide"] as? Int), h = try XCTUnwrap(hello["pixelsHigh"] as? Int)
            XCTAssertTrue(h - w == 1000 || (w, h) == (1290, 2796) || (w, h) == (1170, 2532), "mixed panel \(w)x\(h)")
            let panel = try XCTUnwrap(hello["panel"] as? [String: Any])
            XCTAssertEqual(panel["pixelsWide"] as? Int, w); XCTAssertEqual(panel["pixelsHigh"] as? Int, h)
        }
        XCTAssertEqual(hellos.last?["pixelsWide"] as? Int, 1290)
        XCTAssertEqual(receiver.devicePixelsWide, 1290)
    }
}
