import Foundation
import Network
import Security
import CryptoKit

/// TLS PSK binds the complete bidirectional TCP stream (including touch)
/// to a previously verified pair. There is no plaintext retry on failure.
enum PairedTransport {
    static let serviceType = "_duostream._tcp"
    static func identity(_ a: String, _ b: String) -> String { [a, b].sorted().joined(separator: ":") }
    static func streamService(_ identity: String) -> String {
        "Duo-" + SHA256.hash(data: Data(identity.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
    static func endpoint(mac: String, phone: String) -> NWEndpoint {
        .service(name: streamService(identity(mac, phone)), type: serviceType, domain: "local.", interface: nil)
    }

    static func parameters(key: SymmetricKey, identity: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let secret = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let label = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: 0x00A8)!)
        sec_protocol_options_set_tls_pre_shared_key_identity_hint(tls.securityProtocolOptions, label as __DispatchData)
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                                                secret as __DispatchData, label as __DispatchData)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }
}
