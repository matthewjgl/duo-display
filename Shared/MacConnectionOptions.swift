import Foundation

/// Presentation routing only. Names associate rows, never authorize peers.
/// Every .connect still requires signed discovery + the stored-key challenge;
/// every .pair still requires matching-code approval on both devices.
enum MacConnectionAction: Equatable {
    case connect(String), pair(String), search, none
}
struct MacConnectionOption: Identifiable, Equatable {
    struct Nearby { let token: String; let name: String }
    let id: String
    let name: String
    let detail: String
    let action: MacConnectionAction
    var title: String {
        switch action { case .connect: return "Connect"; case .pair: return "Pair & Connect"; case .search: return "Find Mac"; case .none: return "Connected" }
    }
    static func make(remembered: [TrustedPeerRegistry.Record], available: Set<String>, nearby: [Nearby], connected: Bool = false) -> [Self] {
        func key(_ name: String) -> String { name.trimmingCharacters(in:.whitespacesAndNewlines).folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX")) }
        var consumed = Set<String>()
        var rows = remembered.map { peer -> Self in
            let matches = nearby.filter { key($0.name) == key(peer.name) }
            let unique = matches.count == 1 && remembered.filter { key($0.name) == key(peer.name) }.count == 1
            if unique { consumed.insert(matches[0].token) }
            let action: MacConnectionAction = available.contains(peer.id) ? .connect(peer.id) : unique ? .pair(matches[0].token) : .search
            let detail = available.contains(peer.id) ? "Ready to connect" : unique ? "Verify pairing on both devices" : "Not nearby — check the same Wi-Fi"
            return Self(id:"trusted:"+peer.id,name:peer.name,detail:connected ? "Display connected" : detail,action:connected ? .none : action)
        }
        rows += nearby.filter { !consumed.contains($0.token) }.map {
            Self(id:"pair:"+$0.token,name:$0.name,detail:"Approval required",action:connected ? .none : .pair($0.token))
        }
        return rows
    }
    func enabled(busy: Bool, connected: Bool) -> Bool { !busy && !connected && action != .none }
}
