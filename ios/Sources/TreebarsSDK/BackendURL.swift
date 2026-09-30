import Foundation

/**
 Whether an address may carry this SDK's traffic: https anywhere, and plain http only to a machine on
 the developer's own desk. The same rule as Android's `BackendUrl`, and for the same reasons.

 Every request carries the write key and the device's secret, and a signed-in one carries the account
 id and the signature that proves it. Over http all four would cross every network between the handset
 and the server in the clear. App Transport Security would refuse most of it, but an app that sets
 `NSAllowsArbitraryLoads` for its own reasons turns that off for this SDK too, so the SDK checks for
 itself.

 Local means what a development setup and a simulator actually use: loopback, a `.local` mDNS name,
 and the private ranges a handset on the same Wi-Fi reaches a laptop by. Anything else over http is
 refused and the SDK stays off, saying why.
 */
enum BackendURL {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
            return false
        }
        switch scheme {
        case "https": return true
        case "http": return isLocal(host)
        default: return false
        }
    }

    /// A host on this machine or its own network — never one a request would cross the internet to reach.
    static func isLocal(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            guard let value = Int(part), (0...255).contains(value) else { return false }
            octets.append(value)
        }
        return octets[0] == 127
            || octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }
}
