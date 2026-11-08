import Foundation
import Network

/// Reads receiver metadata through the already trusted USB transport. It never
/// sends welcome, input or video: a receiver with a live Wi-Fi session therefore
/// keeps that session while we learn whether this is the same physical device.
enum USBPeerProbe {
    static func installID(deviceID: Int, port: UInt16) async throws -> String {
        let queue = DispatchQueue(label: "duo.usbIdentityProbe")
        let connection = try await Usbmux.connect(deviceID: deviceID, port: port,
                                                  queue: queue, deadline: 3)
        defer { connection.cancel() }
        return try await readInstallID(on: connection, queue: queue)
    }

    static func readInstallID(on connection: NWConnection, queue: DispatchQueue,
                              timeout: TimeInterval = 3) async throws -> String {
        let deadline = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        let header = try await Usbmux.receive(exactly: 4, on: connection)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= 65_536 else {
            throw Usbmux.Failure.protocolError("invalid receiver metadata length")
        }
        let data = try await Usbmux.receive(exactly: length, on: connection)
        guard let id = DeviceIdentity.helloID(data) else {
            throw Usbmux.Failure.protocolError("receiver has no stable identity")
        }
        return id
    }
}
