import XCTest
import CryptoKit
import Network
import AVFoundation

/// Test keys are in a lock-protected in-memory vault. No app trust or Keychain
/// item is created by these tests. Real Network.framework/Bonjour/TLS are used.
private final class ReconnectVault {
    private let lock = NSLock()
    private var entries: [String: SymmetricKey]
    init(_ entries: [String: SymmetricKey]) { self.entries = entries }
    func load(_ id: String) -> SymmetricKey? { lock.lock(); defer { lock.unlock() }; return entries[id] }
    func ids() -> [String] { lock.lock(); defer { lock.unlock() }; return Array(entries.keys) }
    func set(_ id: String, _ key: SymmetricKey?) { lock.lock(); defer { lock.unlock() }; entries[id] = key }
}

@MainActor
final class TrustedReconnectTests: XCTestCase {
    private func prefs() -> UserDefaults { UserDefaults(suiteName: "DuoReconnectTests." + UUID().uuidString)! }
    private func receiver() -> StreamReceiver { StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(), deviceKind: "iPhone", fallbackServiceName: "Trusted QA") }
    private func client(_ id: String, _ vault: ReconnectVault, _ defaults: UserDefaults) -> TrustedConnections {
        TrustedConnections(ownID: id, lookup: { vault.load($0) }, peers: { vault.ids() }, preferences: defaults,
                           erase: { vault.set($0, nil); TrustedPeerRegistry.markRevoked($0, defaults: defaults) })
    }
    private func eventually(_ predicate: () -> Bool, seconds: Double = 6) async throws -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if predicate() { return true }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        return predicate()
    }
    private func stop(_ receiver: StreamReceiver) async {
        let e = expectation(description: "receiver stopped"); receiver.stop { e.fulfill() }
        await fulfillment(of: [e], timeout: 5)
    }
    func testTrustedDiscoverySurvivesRestartNetworkSleepAndDisableOutsidePairingWindow() async throws {
        let key = SymmetricKey(size: .bits256), macID = UUID().uuidString, phoneID = UUID().uuidString
        let macVault = ReconnectVault([phoneID:key]), phoneVault = ReconnectVault([macID:key])
        let mp = prefs(), pp = prefs(); let r = receiver()
        var mac = client(macID, macVault, mp)
        let phone = client(phoneID, phoneVault, pp)
        defer { mac.shutdown(); phone.shutdown() }
        mac.serve(name: "Remembered QA Mac") { _,_,_ in "QA busy — retry later" }
        phone.browse(receiver: r)
        let found = try await eventually { phone.result(for: macID) != nil }
        XCTAssertTrue(found, phone.status)
        XCTAssertEqual(phone.rememberedPeers.first?.name, "Remembered QA Mac")
        XCTAssertFalse(PairingDiscovery.shared.isAdvertising)
        mac.shutdown()
        let removed = try await eventually { phone.result(for: macID) == nil }
        XCTAssertTrue(removed)
        XCTAssertEqual(phone.rememberedPeers.first?.name, "Remembered QA Mac", "Name persists when offline")
        mac = client(macID, macVault, mp)
        mac.serve(name: "Remembered QA Mac") { _,_,_ in "QA busy — retry later" }
        let restored = try await eventually { phone.canConnect(to: macID) }
        XCTAssertTrue(restored)
        mac.suspendForSleep()
        let sleeping = try await eventually { phone.result(for: macID) == nil }
        XCTAssertTrue(sleeping); XCTAssertNil(mac.listeningPort(for: phoneID))
        mac.resumeAfterWake()
        let awake = try await eventually { phone.canConnect(to: macID) }
        XCTAssertTrue(awake)
        mac.recoverAfterEnvironmentChange(); phone.recoverAfterEnvironmentChange()
        let networkRestored = try await eventually { phone.canConnect(to: macID) }
        XCTAssertTrue(networkRestored)
        phone.connectPeer(macID)
        let rejected = try await eventually { !phone.connecting && phone.status.contains("QA busy") }
        XCTAssertTrue(rejected, phone.status)
        mac.allowTrustedPhones = false
        XCTAssertNil(mac.listeningPort(for: phoneID))
        mac.shutdown()
        mac = client(macID, macVault, mp)
        mac.serve(name: "Remembered QA Mac") { _,_,_ in XCTFail("Disabled setting must persist"); return nil }
        XCTAssertFalse(mac.allowTrustedPhones); XCTAssertNil(mac.listeningPort(for: phoneID))
        mac.allowTrustedPhones = true
        let enabled = try await eventually { phone.canConnect(to: macID) }
        XCTAssertTrue(enabled)
        await stop(r)
    }

    func testCancellationAndBusyRejectionReturnToUsableState() async throws {
        let key = SymmetricKey(size: .bits256), mid = UUID().uuidString, pid = UUID().uuidString
        let mac = client(mid, ReconnectVault([pid:key]), prefs())
        let phone = client(pid, ReconnectVault([mid:key]), prefs()), r = receiver()
        defer { mac.shutdown(); phone.shutdown() }
        var requests = 0
        mac.serve(name: "Cancellation QA") { _,_,_ in requests += 1; return "Mac busy. Retry when its current connection ends." }
        let ready = try await eventually { mac.listeningPort(for: pid) != nil }; XCTAssertTrue(ready)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: try XCTUnwrap(mac.listeningPort(for: pid)))
        phone.connectTrusted(endpoint: endpoint, macID: mid, receiver: r); phone.cancel()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(phone.connecting); XCTAssertTrue(phone.status.contains("cancelled")); XCTAssertEqual(requests, 0)
        phone.connectTrusted(endpoint: endpoint, macID: mid, receiver: r)
        phone.connectTrusted(endpoint: endpoint, macID: mid, receiver: r)
        let rejected = try await eventually { !phone.connecting && phone.status.contains("Mac busy") }
        XCTAssertTrue(rejected, phone.status); XCTAssertEqual(requests, 1)
        await stop(r)
    }

    func testWrongKeyIsNotDiscoveredAndCannotRequestStreaming() async throws {
        let mid = UUID().uuidString, pid = UUID().uuidString
        let mac = client(mid, ReconnectVault([pid:SymmetricKey(size: .bits256)]), prefs())
        let phone = client(pid, ReconnectVault([mid:SymmetricKey(size: .bits256)]), prefs()), r = receiver()
        defer { mac.shutdown(); phone.shutdown() }
        var requests = 0
        mac.serve(name: "Wrong key QA") { _,_,_ in requests += 1; return nil }
        phone.browse(receiver: r)
        let ready = try await eventually { mac.listeningPort(for: pid) != nil }; XCTAssertTrue(ready)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(phone.result(for: mid))
        phone.connectTrusted(endpoint: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(mac.listeningPort(for: pid))), macID: mid, receiver: r)
        let failed = try await eventually { !phone.connecting }
        XCTAssertTrue(failed); XCTAssertEqual(requests, 0)
        await stop(r)
    }

    func testRequestTimeoutRestoresRetryWithoutStartingAnySession() async throws {
        let key = SymmetricKey(size: .bits256), mid = UUID().uuidString, pid = UUID().uuidString
        let listener = try NWListener(using: PairedTransport.parameters(key: key, identity: TrustedConnections.identity(mid,pid)))
        var held: [NWConnection] = []
        listener.newConnectionHandler = { c in held.append(c); c.start(queue: .main) }
        listener.start(queue: .main)
        let ready = try await eventually { listener.port != nil && listener.port!.rawValue != 0 }
        XCTAssertTrue(ready)
        let phone = TrustedConnections(ownID: pid, lookup: { _ in key }, peers: { [mid] }, preferences: prefs(), requestTimeout: 0.15)
        let r = receiver()
        defer { listener.cancel(); held.forEach { $0.cancel() }; phone.shutdown() }
        phone.connectTrusted(endpoint: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(listener.port)), macID: mid, receiver: r)
        let timedOut = try await eventually { !phone.connecting && phone.status.contains("timed out") }
        XCTAssertTrue(timedOut, phone.status)
        phone.connectTrusted(endpoint: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(listener.port)), macID: mid, receiver: r)
        XCTAssertTrue(phone.connecting); phone.cancel(); XCTAssertFalse(phone.connecting)
        await stop(r)
    }

    private func send(_ object: [String:Any], _ c: NWConnection) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        var n = UInt32(data.count).bigEndian; var packet = Data(bytes: &n, count: 4); packet.append(data)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void,Error>) in
            c.send(content: packet, completion: .contentProcessed { error in if let error { cont.resume(throwing: error) } else { cont.resume() } })
        }
    }
    private func read(_ c: NWConnection) async throws -> [String:Any] {
        func exact(_ n: Int) async throws -> Data {
            try await withCheckedThrowingContinuation { cont in
                c.receive(minimumIncompleteLength: n, maximumLength: n) { data,_,_,error in
                    if let error { cont.resume(throwing: error) }
                    else if let data, data.count == n { cont.resume(returning: data) }
                    else { cont.resume(throwing: TrustedConnections.RequestError.closed) }
                }
            }
        }
        let h = try await exact(4); let n = h.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard n > 0, n <= 4096 else { throw TrustedConnections.RequestError.invalid }
        let body = try await exact(n)
        return try JSONSerialization.jsonObject(with: body) as! [String:Any]
    }
    private func socket(key: SymmetricKey, identity: String, port: NWEndpoint.Port) async throws -> NWConnection {
        let c = NWConnection(host: "127.0.0.1", port: port, using: PairedTransport.parameters(key: key, identity: identity))
        let ready = expectation(description: "TLS ready")
        c.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        c.start(queue: .main); await fulfillment(of: [ready], timeout: 5)
        return c
    }
    func testReplayAcrossConnectionsAndChangedKeyAfterTLSAreRejected() async throws {
        let key = SymmetricKey(size: .bits256), mid = UUID().uuidString, pid = UUID().uuidString
        let vault = ReconnectVault([pid:key])
        let server = client(mid, vault, prefs())
        defer { server.shutdown() }
        var requests = 0
        server.serve(name: "Replay QA") { _,_,_ in requests += 1; return "QA rejected" }
        let listening = try await eventually { server.listeningPort(for: pid) != nil }; XCTAssertTrue(listening)
        let port = try XCTUnwrap(server.listeningPort(for: pid)), identity = TrustedConnections.identity(mid,pid)
        let a = try await socket(key:key, identity:identity, port:port); defer { a.cancel() }
        let first = try await read(a)
        let proof = try XCTUnwrap(PairingChallenge.proof(key:key, nonce:Data(base64Encoded:first["nonce"] as! String)!, purpose:.connect, macID:mid, phoneID:pid))
        try await send(["proof":proof.base64EncodedString(),"receiver":"QA","port":9001],a)
        _ = try await read(a); XCTAssertEqual(requests,1)
        let b = try await socket(key:key, identity:identity, port:port); defer { b.cancel() }
        _ = try await read(b)
        try await send(["proof":proof.base64EncodedString(),"receiver":"QA","port":9001],b)
        do { _ = try await read(b); XCTFail("Replayed proof must close without admission") } catch {}
        XCTAssertEqual(requests,1)
        let c = try await socket(key:key, identity:identity, port:port); defer { c.cancel() }
        let fresh = try await read(c)
        vault.set(pid,SymmetricKey(size:.bits256))
        let oldProof = PairingChallenge.proof(key:key, nonce:Data(base64Encoded:fresh["nonce"] as! String)!, purpose:.connect, macID:mid, phoneID:pid)!
        try await send(["proof":oldProof.base64EncodedString(),"receiver":"QA","port":9001],c)
        do { _ = try await read(c); XCTFail("Changed stored key must reject even an established TLS socket") } catch {}
        XCTAssertEqual(requests,1)
        server.revoke(pid); XCTAssertNil(server.listeningPort(for:pid))
    }

    func testSimultaneousMacAndPhoneRequestsReusePendingPairedSession() async throws {
        let key = SymmetricKey(size: .bits256), mid = UUID().uuidString, pid = UUID().uuidString
        let server = client(mid, ReconnectVault([pid:key]), prefs())
        defer { server.shutdown() }
        // Model the route already reserved by the normal Mac-side coordinator.
        // Production SenderController calls this exact reuse policy before
        // ending or creating any MacSender pipeline.
        let existing = NWEndpoint.hostPort(host: "127.0.0.1", port: 9001)
        var starts = 1, requests = 0
        server.serve(name: "Simultaneous QA") { peer,_,endpoint in
            requests += 1
            if !TrustedSessionRouting.canReuse(peer:peer, existingPeer:pid, pending:true,
                                               existingEndpoint:existing, requestedEndpoint:endpoint) { starts += 1 }
            return nil
        }
        let listening = try await eventually { server.listeningPort(for:pid) != nil }; XCTAssertTrue(listening)
        let port = try XCTUnwrap(server.listeningPort(for:pid)), identity = TrustedConnections.identity(mid,pid)
        func request() async throws {
            let c = try await socket(key:key, identity:identity, port:port); defer { c.cancel() }
            let challenge = try await read(c)
            let proof = PairingChallenge.proof(key:key, nonce:Data(base64Encoded:challenge["nonce"] as! String)!, purpose:.connect, macID:mid, phoneID:pid)!
            try await send(["proof":proof.base64EncodedString(),"receiver":"same-receiver","port":9001],c)
            let response = try await read(c); XCTAssertEqual(response["accepted"] as? Bool,true)
        }
        async let first: Void = request()
        async let second: Void = request()
        _ = try await (first,second)
        XCTAssertEqual(requests,2); XCTAssertEqual(starts,1)
        XCTAssertFalse(TrustedSessionRouting.canReuse(peer:pid, existingPeer:"other-peer", pending:false,
                                                     existingEndpoint:existing, requestedEndpoint:existing))
        XCTAssertFalse(TrustedSessionRouting.canReuse(peer:pid, existingPeer:pid, pending:true,
                                                     existingEndpoint:existing, requestedEndpoint:.hostPort(host:"127.0.0.1",port:9002)))
    }

    func testExplicitRePairRetiresOldPeerBeforeRefreshingListeners() async throws {
        let mid = UUID().uuidString, pid = UUID().uuidString
        let vault = ReconnectVault([pid:SymmetricKey(size:.bits256)])
        let server = client(mid,vault,prefs())
        defer { server.shutdown() }
        var retired: [String] = []
        server.onRevoked = { retired.append($0) }
        server.serve(name:"Re-pair QA") { _,_,_ in "QA rejected" }
        let ready = try await eventually { server.listeningPort(for:pid) != nil }; XCTAssertTrue(ready)
        vault.set(pid,SymmetricKey(size:.bits256))
        NotificationCenter.default.post(name:.init("DuoPairSaved"),object:pid)
        let refreshed = try await eventually { retired.contains(pid) && server.listeningPort(for:pid) != nil }
        XCTAssertTrue(refreshed)
    }

    func testShutdownCannotBeResurrectedByStaleRecovery() async throws {
        let pid = UUID().uuidString
        let server = client(UUID().uuidString, ReconnectVault([pid:SymmetricKey(size:.bits256)]), prefs())
        server.serve(name:"Shutdown QA") { _,_,_ in XCTFail("Retired server cannot accept requests"); return nil }
        let ready = try await eventually { server.listeningPort(for:pid) != nil }; XCTAssertTrue(ready)
        server.shutdown()
        server.recoverAfterEnvironmentChange(); server.resumeAfterWake()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(server.listeningPort(for:pid))
    }

    func testNamesAndRevocationTombstonesPersistWithoutGrantingTrust() {
        let p = prefs()
        TrustedPeerRegistry.rememberName("My actual Mac", peer:"mac", defaults:p)
        XCTAssertEqual(TrustedPeerRegistry.records(peers:["mac"], defaults:p).first?.name,"My actual Mac")
        TrustedPeerRegistry.markRevoked("mac", defaults:p)
        XCTAssertTrue(TrustedPeerRegistry.isRevoked("mac", defaults:p))
        TrustedPeerRegistry.approvedAgain("mac", defaults:p)
        XCTAssertFalse(TrustedPeerRegistry.isRevoked("mac", defaults:p))
    }
}
