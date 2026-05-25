import NIO
import NIOHTTP1
import Testing

@testable import swift_crud

@Suite("Client IP")
struct ClientIPTests {

    @Test("loopback peer uses first X-Forwarded-For hop")
    func forwardedFromLoopback() throws {
        let peer = try SocketAddress(ipAddress: "127.0.0.1", port: 8222)
        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "X-Forwarded-For", value: "203.0.113.50, 10.0.0.1")
        #expect(ClientIP.resolve(peer: peer, headers: headers) == "203.0.113.50")
    }

    @Test("public peer ignores X-Forwarded-For")
    func ignoresForwardedFromPublicPeer() throws {
        let peer = try SocketAddress(ipAddress: "203.0.113.1", port: 8222)
        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "X-Forwarded-For", value: "198.51.100.10")
        #expect(ClientIP.resolve(peer: peer, headers: headers) == "203.0.113.1")
    }

    @Test("missing peer is unknown")
    func missingPeer() {
        let headers = NIOHTTP1.HTTPHeaders()
        #expect(ClientIP.resolve(peer: nil, headers: headers) == "unknown")
    }
}
