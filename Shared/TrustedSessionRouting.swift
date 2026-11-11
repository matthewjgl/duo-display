import Network

/// Used inside the existing sender session coordinator. A verified repeat
/// request for the same pending route reuses that pipeline; a changed route
/// must retire it before the normal connect path creates a replacement.
enum TrustedSessionRouting {
    static func canReuse(peer: String, existingPeer: String?, pending: Bool,
                         existingEndpoint: NWEndpoint?, requestedEndpoint: NWEndpoint) -> Bool {
        existingPeer == peer && (!pending || existingEndpoint == requestedEndpoint)
    }
}
