// ClientIP.swift: resolves the client IP for rate limiting, honoring X-Forwarded-For only from loopback peers.

import Foundation
import NIO
import NIOHTTP1

/// Resolves the client IP from the TCP peer and optional proxy headers.
enum ClientIP {

    /// Uses `X-Forwarded-For` (first hop) when the TCP peer is a trusted local reverse proxy; otherwise the peer host.
    static func resolve(peer: SocketAddress?, headers: RequestHeaders) -> String {
        let peerHost = peer.map(hostString) ?? "unknown"
        guard let peer, isTrustedProxyPeer(peer),
            let forwarded = headers.first(name: "X-Forwarded-For")
        else {
            return peerHost
        }
        let client = forwarded
            .split(separator: ",")
            .first
            .map { String($0.trimmingCharacters(in: CharacterSet.whitespaces)) }
        guard let client, !client.isEmpty else { return peerHost }
        return client
    }

    private static func hostString(_ address: SocketAddress) -> String {
        switch address {
        case .v4(let v4): return ipv4PresentationHost(v4) ?? ""
        case .v6(let v6):
            if !v6.host.isEmpty { return v6.host }
            return String(describing: address)
        case .unixDomainSocket: return "unix"
        }
    }

    /// Trust forwarded headers only for on-host reverse proxies (nginx → 127.0.0.1:8222).
    private static func isTrustedProxyPeer(_ peer: SocketAddress) -> Bool {
        switch peer {
        case .v4(let v4): return ipv4PresentationHost(v4) == "127.0.0.1"
        case .v6(let v6):
            let host = v6.host.isEmpty ? String(describing: peer) : v6.host
            return host.contains("::1")
        case .unixDomainSocket: return true
        }
    }

    /// NIO may leave `IPv4Address.host` empty; parse the printed address from `description` when needed.
    private static func ipv4PresentationHost(_ v4: SocketAddress.IPv4Address) -> String? {
        if !v4.host.isEmpty { return v4.host }
        let desc = String(describing: SocketAddress.v4(v4))
        guard desc.hasPrefix("[IPv4]") else { return nil }
        let rest = desc.dropFirst("[IPv4]".count)
        if let slash = rest.firstIndex(of: "/") {
            return String(rest[..<slash])
        }
        if let colon = rest.firstIndex(of: ":") {
            return String(rest[..<colon])
        }
        return nil
    }
}
