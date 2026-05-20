// CORSTests: origin allowlist and preflight response headers.

import Foundation
import NIOHTTP1
import Testing
@testable import swift_crud

@Suite("CORS", .serialized)
struct CORSTests {

    private func request(method: HTTPMethod, origin: String?) -> HTTPRequest {
        var headers = NIOHTTP1.HTTPHeaders()
        if let origin { headers.add(name: "Origin", value: origin) }
        return HTTPRequest(
            method: method, path: "/api/posts", query: "", headers: headers, body: Data(),
            remoteAddress: nil)
    }

    @Test("allowedOrigin returns nil when allowlist is empty")
    func noAllowlist() {
        defer { corsAllowedOrigins = [] }
        corsAllowedOrigins = []
        let req = request(method: .GET, origin: "https://app.example.com")
        #expect(CORS.allowedOrigin(for: req) == nil)
    }

    @Test("allowedOrigin matches configured origin")
    func matchingOrigin() {
        defer { corsAllowedOrigins = [] }
        corsAllowedOrigins = ["https://app.btec.cc"]
        let req = request(method: .GET, origin: "https://app.btec.cc")
        #expect(CORS.allowedOrigin(for: req) == "https://app.btec.cc")
    }

    @Test("preflight returns 204 with credentials headers")
    func preflight() {
        defer { corsAllowedOrigins = [] }
        corsAllowedOrigins = ["https://app.btec.cc"]
        let req = request(method: .OPTIONS, origin: "https://app.btec.cc")
        let res = CORS.preflightResponse(for: req)
        #expect(res?.statusCode == .noContent)
        #expect(res?.headers[HTTPHeader("Access-Control-Allow-Origin")] == "https://app.btec.cc")
        #expect(res?.headers[HTTPHeader("Access-Control-Allow-Credentials")] == "true")
        #expect(res?.headers[HTTPHeader("Access-Control-Allow-Methods")] != nil)
    }

    @Test("apply adds CORS headers to handler response")
    func applyToResponse() {
        defer { corsAllowedOrigins = [] }
        corsAllowedOrigins = ["https://app.btec.cc"]
        let req = request(method: .GET, origin: "https://app.btec.cc")
        var res = HTTPResponse.json(.ok, ["ok": true])
        CORS.apply(to: &res, request: req)
        #expect(res.headers[HTTPHeader("Access-Control-Allow-Origin")] == "https://app.btec.cc")
        #expect(res.headers[HTTPHeader("Access-Control-Allow-Credentials")] == "true")
    }
}
