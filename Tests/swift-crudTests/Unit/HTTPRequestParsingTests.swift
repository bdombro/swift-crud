// HTTPRequestParsingTests: unit tests for HTTPRequest parsing extensions.
// Does not touch module globals — safe to run in parallel.

import Foundation
import NIOHTTP1
import Testing
@testable import swift_crud

/// Builds an HTTPRequest with the given query items and Cookie header value.
private func makeRequest(
    query: [HTTPRequest.QueryItem] = [],
    cookieHeader: String? = nil
) -> HTTPRequest {
    var headers = NIOHTTP1.HTTPHeaders()
    if let cookieHeader { headers.add(name: "Cookie", value: cookieHeader) }
    let queryString = query.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    return HTTPRequest(method: .GET, path: "/test", query: queryString, headers: headers, body: Data())
}

@Suite("HTTPRequest parsing")
struct HTTPRequestParsingTests {

    // MARK: queryParameters

    @Test("empty query returns empty dict")
    func emptyQuery() {
        let req = makeRequest()
        #expect(req.queryParameters.isEmpty)
    }

    @Test("single query param round-trips")
    func singleParam() {
        let req = makeRequest(query: [.init(name: "limit", value: "20")])
        #expect(req.queryParameters["limit"] == "20")
    }

    @Test("multiple query params all present")
    func multipleParams() {
        let req = makeRequest(query: [
            .init(name: "limit", value: "10"),
            .init(name: "after", value: "2026-01-01T00:00:00Z"),
        ])
        #expect(req.queryParameters["limit"] == "10")
        #expect(req.queryParameters["after"] == "2026-01-01T00:00:00Z")
    }

    // MARK: cookie(_:)

    @Test("missing Cookie header returns nil")
    func missingCookieHeader() {
        let req = makeRequest()
        #expect(req.cookie("user_id") == nil)
    }

    @Test("single cookie parsed correctly")
    func singleCookie() {
        let req = makeRequest(cookieHeader: "user_id=42")
        #expect(req.cookie("user_id") == "42")
    }

    @Test("cookie among multiple cookies parsed correctly")
    func multipleCookies() {
        let req = makeRequest(cookieHeader: "session=abc; user_id=7; theme=dark")
        #expect(req.cookie("user_id") == "7")
        #expect(req.cookie("session") == "abc")
        #expect(req.cookie("theme") == "dark")
    }

    @Test("cookie with leading spaces parsed correctly")
    func cookieWithSpaces() {
        let req = makeRequest(cookieHeader: "foo=bar;  user_id=99")
        #expect(req.cookie("user_id") == "99")
    }

    @Test("unknown cookie name returns nil")
    func unknownCookieName() {
        let req = makeRequest(cookieHeader: "user_id=5")
        #expect(req.cookie("other") == nil)
    }
}
