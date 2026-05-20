// APIIntegrationTests: end-to-end HTTP tests against an in-process SwiftNIO server.
// Uses .serialized because tests mutate module-level globals (db, emailSender, activeAuthSecret).
// Each test gets a fresh in-memory DB and a new server on port 0.

import Blackbird
import CryptoKit
import Foundation
import Testing

@testable import swift_crud

private enum TestError: Error {
    case serverDidNotBind
    case loginFailed
}

private struct CreatePostRequest: Encodable {
    let id: String
    let content: String
    let variant: String
    let isDeleted: Bool
}

private struct UpdatePostRequest: Encodable {
    let content: String
    let variant: String
    let updatedAt: String
    let isDeleted: Bool
}

private func sha256(_ string: String) -> String {
    let data = Data(string.utf8)
    return SHA256.hash(data: data)
        .compactMap { String(format: "%02x", $0) }
        .joined()
}

@Suite("API integration", .serialized)
final class APIIntegrationTests {

    // Register routes into the global `routes` instance exactly once per test binary run.
    // Route registration is idempotent (same path replaces the previous handler).
    private static let _routesRegistered: Void = {
        registerPostRoutes()
        registerSessionRoutes()
    }()

    private let testDb: Blackbird.Database
    private let mockEmail: MockEmailSender
    private let server: Server
    private let http: HTTPClient

    // MARK: - Per-test setup / teardown

    init() async throws {
        _ = Self._routesRegistered
        await resetSendCodeRateLimitersForTesting()

        testDb = try Blackbird.Database.inMemoryDatabase()
        try await User.resolveSchema(in: testDb)
        try await Post.resolveSchema(in: testDb)

        mockEmail = MockEmailSender()

        // Set module globals before starting the server so handlers see the test state.
        db = testDb
        emailSender = mockEmail
        activeAuthSecret = "test-secret"
        cookieDomain = nil
        cookieSecure = true
        corsAllowedOrigins = []

        server = Server(port: 0)
        try await server.startAndListen()
        guard let port = server.boundPort else { throw TestError.serverDidNotBind }
        http = HTTPClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
    }

    deinit {
        let s = server
        Task { await s.stop() }
    }

    // MARK: - Helpers

    /// Inserts a user directly into the DB with a known code so tests bypass SMTP.
    @discardableResult
    private func seedUser(email: String, code: String = "12345678") async throws -> Int {
        let now = Date()
        try await testDb.query(
            "INSERT INTO users (codeAttempts, codeCreatedAt, codeHash, createdAt, email) VALUES (0, ?, ?, ?, ?)",
            now, sha256(code), now, email
        )
        let rows = try await testDb.query("SELECT id FROM users WHERE email = ?", email)
        return rows[0]["id"]?.intValue ?? 0
    }

    private func login(email: String, code: String = "12345678") async throws -> String {
        let body = try http.jsonBody(["email": email, "code": code])
        let (status, _, headers) = try await http.request("POST", "/api/session/login", body: body)
        guard status == 200, let cookie = http.extractCookie(from: headers, name: "user_id") else {
            throw TestError.loginFailed
        }
        return cookie
    }

    // MARK: - Auth / session tests

    @Test("unauthenticated GET /api/posts returns 401")
    func unauthorizedAccess() async throws {
        let (status, _, _) = try await http.request("GET", "/api/posts")
        #expect(status == 401)
    }

    @Test("POST /api/session/send-code creates a new user and sends a code")
    func sendCodeCreatesUser() async throws {
        let body = try http.jsonBody(["email": "new@test.com"])
        let (status, _, _) = try await http.request("POST", "/api/session/send-code", body: body)
        #expect(status == 200)

        let rows = try await testDb.query("SELECT email FROM users WHERE email = ?", "new@test.com")
        #expect(rows.count == 1)

        let sentCount = await mockEmail.sent.count
        #expect(sentCount == 1)
    }

    @Test("POST /api/session/send-code twice within 2 minutes returns 429")
    func sendCodeRateLimited() async throws {
        try await seedUser(email: "rate@test.com")
        // Ensure codeCreatedAt is within the 2-minute window
        try await testDb.query(
            "UPDATE users SET codeCreatedAt = ? WHERE email = ?", Date(), "rate@test.com")

        let body = try http.jsonBody(["email": "rate@test.com"])
        let (status, _, _) = try await http.request("POST", "/api/session/send-code", body: body)
        #expect(status == 429)
    }

    @Test("POST /api/session/send-code rejects overly short and malformed emails")
    func sendCodeInvalidEmail() async throws {
        let shortBody = try http.jsonBody(["email": "a@b"])
        let (s1, _, _) = try await http.request("POST", "/api/session/send-code", body: shortBody)
        #expect(s1 == 401)

        let multiAt = try http.jsonBody(["email": "a@@b.com"])
        let (s2, _, _) = try await http.request("POST", "/api/session/send-code", body: multiAt)
        #expect(s2 == 401)
    }

    @Test("POST /api/session/send-code returns 429 after too many requests from the same IP")
    func sendCodeIPRateLimited() async throws {
        for i in 0..<10 {
            let email = "iptest\(i)@test.com"
            let body = try http.jsonBody(["email": email])
            let (status, _, _) = try await http.request("POST", "/api/session/send-code", body: body)
            #expect(status == 200, "request \(i) should succeed")
        }
        let overflow = try http.jsonBody(["email": "iptest_overflow@test.com"])
        let (lastStatus, _, _) = try await http.request("POST", "/api/session/send-code", body: overflow)
        #expect(lastStatus == 429)
    }

    @Test("POST /api/session/login returns HMAC-signed cookie")
    func loginHappyPath() async throws {
        let userId = try await seedUser(email: "login@test.com", code: "12345678")
        let cookie = try await login(email: "login@test.com", code: "12345678")

        // Cookie is HMAC-signed: "userId.base64sig"
        let parts = cookie.split(separator: ".")
        #expect(parts.count == 2)
        #expect(Int(parts[0]) == userId)
        #expect(AuthCookie.verify(cookie, secret: "test-secret") == userId)
    }

    @Test("POST /api/session/login wrong code 3 times locks account; correct code then also fails")
    func loginAttemptsExhausted() async throws {
        try await seedUser(email: "lock@test.com", code: "12345678")

        let wrongBody = try http.jsonBody(["email": "lock@test.com", "code": "00000000"])
        for _ in 0..<3 {
            let (s, _, _) = try await http.request("POST", "/api/session/login", body: wrongBody)
            #expect(s == 401)
        }

        let correctBody = try http.jsonBody(["email": "lock@test.com", "code": "12345678"])
        let (status, _, _) = try await http.request("POST", "/api/session/login", body: correctBody)
        #expect(status == 401)
    }

    @Test("GET /api/session/ with valid cookie returns current user")
    func getSessionValid() async throws {
        let userId = try await seedUser(email: "session@test.com")
        let cookie = try await login(email: "session@test.com")

        let (status, data, _) = try await http.request("GET", "/api/session/", cookie: cookie)
        #expect(status == 200)

        let decoded = try http.decode(data, as: Int.self)
        #expect(decoded == userId)
    }

    @Test("GET /api/session/ with tampered cookie returns 401")
    func getSessionTamperedCookie() async throws {
        let badSig = Data(repeating: 0xAB, count: 32).base64EncodedString()
        let (status, _, _) = try await http.request("GET", "/api/session/", cookie: "1.\(badSig)")
        #expect(status == 401)
    }

    @Test("login Set-Cookie includes Domain when cookieDomain is set")
    func loginCookieDomain() async throws {
        cookieDomain = "btec.cc"
        defer { cookieDomain = nil }
        try await seedUser(email: "domain@test.com")
        let body = try http.jsonBody(["email": "domain@test.com", "code": "12345678"])
        let (_, _, headers) = try await http.request("POST", "/api/session/login", body: body)
        let setCookie = headers.first { $0.key.lowercased() == "set-cookie" }?.value ?? ""
        #expect(setCookie.contains("Domain=btec.cc"))
        #expect(setCookie.contains("SameSite=Lax"))
    }

    @Test("OPTIONS preflight returns CORS headers for allowed origin")
    func corsPreflight() async throws {
        let appOrigin = "http://127.0.0.1:3000"
        corsAllowedOrigins = [appOrigin]
        defer { corsAllowedOrigins = [] }
        let (status, _, headers) = try await http.request("OPTIONS", "/api/posts", origin: appOrigin)
        #expect(status == 204)
        #expect(headers["Access-Control-Allow-Origin"] == appOrigin)
        #expect(headers["Access-Control-Allow-Credentials"] == "true")
    }

    @Test("GET with allowed Origin receives CORS headers on API responses")
    func corsOnGet() async throws {
        let appOrigin = "https://app.example.com"
        corsAllowedOrigins = [appOrigin]
        defer { corsAllowedOrigins = [] }
        let (status, _, headers) = try await http.request(
            "GET", "/api/session/", origin: appOrigin)
        #expect(status == 401)
        #expect(headers["Access-Control-Allow-Origin"] == appOrigin)
        #expect(headers["Access-Control-Allow-Credentials"] == "true")
    }

    @Test("POST /api/session/logout sets an expired cookie")
    func logout() async throws {
        try await seedUser(email: "logout@test.com")
        let cookie = try await login(email: "logout@test.com")

        let (status, _, headers) = try await http.request(
            "POST", "/api/session/logout", cookie: cookie)
        #expect(status == 200)

        let clearedCookie = http.extractCookie(from: headers, name: "user_id")
        #expect(clearedCookie?.isEmpty == true)
    }

    // MARK: - Post CRUD tests

    @Test("POST /api/posts, GET /api/posts, GET /api/posts/:id, PUT /api/posts/:id, DELETE /api/posts/:id round-trip")
    func postCrudRoundTrip() async throws {
        try await seedUser(email: "crud@test.com")
        let cookie = try await login(email: "crud@test.com")

        // Create
        let createBody = try http.jsonBody(CreatePostRequest(
            id: "e2e-1", content: "Hello", variant: "note", isDeleted: false))
        let (createStatus, _, _) = try await http.request(
            "POST", "/api/posts", body: createBody, cookie: cookie)
        #expect(createStatus == 201)

        // List
        let (listStatus, listData, _) = try await http.request("GET", "/api/posts", cookie: cookie)
        #expect(listStatus == 200)
        let list = try http.decode(listData, as: ListResponse.self)
        #expect(list.items.count == 1)
        #expect(list.items[0].id == "e2e-1")
        #expect(list.items[0].isDeleted == false)

        // Get
        let (getStatus, getData, _) = try await http.request(
            "GET", "/api/posts/e2e-1", cookie: cookie)
        #expect(getStatus == 200)
        let post = try http.decode(getData, as: Post.self)
        #expect(post.content == "Hello")
        #expect(post.isDeleted == false)

        // Update (updatedAt must be newer than current)
        let newTime = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
        let updateBody = try http.jsonBody(UpdatePostRequest(
            content: "Updated", variant: "note", updatedAt: newTime, isDeleted: true))
        let (updateStatus, _, _) = try await http.request(
            "PUT", "/api/posts/e2e-1", body: updateBody, cookie: cookie)
        #expect(updateStatus == 200)

        let (updatedGetStatus, updatedGetData, _) = try await http.request(
            "GET", "/api/posts/e2e-1", cookie: cookie)
        #expect(updatedGetStatus == 200)
        let updatedPost = try http.decode(updatedGetData, as: Post.self)
        #expect(updatedPost.isDeleted == true)

        // Delete
        let (deleteStatus, _, _) = try await http.request(
            "DELETE", "/api/posts/e2e-1", cookie: cookie)
        #expect(deleteStatus == 200)

        // Get after delete → 404
        let (notFoundStatus, _, _) = try await http.request(
            "GET", "/api/posts/e2e-1", cookie: cookie)
        #expect(notFoundStatus == 404)
    }

    @Test("PUT /api/posts/:id clobbers existing post")
    func postPut() async throws {
        try await seedUser(email: "stale@test.com")
        let cookie = try await login(email: "stale@test.com")

        let now = Date()
        let nowStr = ISO8601DateFormatter().string(from: now)
        let createBody = try http.jsonBody([
            "id": "stale-1", "content": "Original", "variant": "note",
            "updatedAt": nowStr,
        ])
        _ = try await http.request("POST", "/api/posts", body: createBody, cookie: cookie)

        // Stale updatedAt (before the current one)
        let olderStr = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let olderBody = try http.jsonBody(UpdatePostRequest(
            content: "Overwritten", variant: "note", updatedAt: olderStr, isDeleted: false))
        let (status, _, _) = try await http.request(
            "PUT", "/api/posts/stale-1", body: olderBody, cookie: cookie)
        #expect(status == 200)
        
        let (getStatus, getData, _) = try await http.request(
            "GET", "/api/posts/stale-1", cookie: cookie)
        #expect(getStatus == 200)
        let post = try http.decode(getData, as: Post.self)
        #expect(post.content == "Overwritten")
    }

    @Test("POST /api/posts/upsert-many inserts all posts")
    func postUpsertMany() async throws {
        try await seedUser(email: "bulk@test.com")
        let cookie = try await login(email: "bulk@test.com")

        let now = ISO8601DateFormatter().string(from: Date())
        let payload: [[String: Any]] = [
            [
                "id": "b1", "content": "First", "variant": "note", "createdAt": now,
                "updatedAt": now, "isDeleted": false,
            ],
            [
                "id": "b2", "content": "Second", "variant": "note", "createdAt": now,
                "updatedAt": now, "isDeleted": true,
            ],
            [
                "id": "b3", "content": "Third", "variant": "note", "createdAt": now,
                "updatedAt": now, "isDeleted": false,
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (status, _, _) = try await http.request(
            "POST", "/api/posts/upsert-many", body: body, cookie: cookie)
        #expect(status == 200)

        let (_, listData, _) = try await http.request("GET", "/api/posts?limit=10", cookie: cookie)
        let list = try http.decode(listData, as: ListResponse.self)
        #expect(list.items.count == 3)
        #expect(list.items.first(where: { $0.id == "b2" })?.isDeleted == true)
    }

    @Test("DELETE /api/posts removes only the authenticated user's posts")
    func deleteAllPostsScoped() async throws {
        try await seedUser(email: "del1@test.com")
        let cookie1 = try await login(email: "del1@test.com")

        try await seedUser(email: "del2@test.com")
        let cookie2 = try await login(email: "del2@test.com")

        let now = ISO8601DateFormatter().string(from: Date())
        func mkBody(_ id: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "id": id, "content": "c", "variant": "note",
                "createdAt": now, "updatedAt": now,
            ])
        }

        _ = try await http.request("POST", "/api/posts", body: mkBody("u1-post"), cookie: cookie1)
        _ = try await http.request("POST", "/api/posts", body: mkBody("u2-post"), cookie: cookie2)

        let (delStatus, _, _) = try await http.request("DELETE", "/api/posts", cookie: cookie1)
        #expect(delStatus == 200)

        let (_, listData1, _) = try await http.request("GET", "/api/posts", cookie: cookie1)
        let list1 = try http.decode(listData1, as: ListResponse.self)
        #expect(list1.items.isEmpty)

        let (_, listData2, _) = try await http.request("GET", "/api/posts", cookie: cookie2)
        let list2 = try http.decode(listData2, as: ListResponse.self)
        #expect(list2.items.count == 1)
    }

    @Test("GET /api/posts pagination: first page has 10 items with hasMore=true; second page returns remainder")
    func pagination() async throws {
        try await seedUser(email: "page@test.com")
        let cookie = try await login(email: "page@test.com")

        // Insert 15 posts with distinct updatedAt values (1-second apart)
        let base = Date()
        for i in 0..<15 {
            let t = ISO8601DateFormatter().string(from: base.addingTimeInterval(Double(i)))
            let body = try JSONSerialization.data(withJSONObject: [
                "id": "p-\(i)", "content": "c\(i)", "variant": "note",
                "createdAt": t, "updatedAt": t,
            ])
            _ = try await http.request("POST", "/api/posts", body: body, cookie: cookie)
        }

        let (_, data1, _) = try await http.request("GET", "/api/posts?limit=10", cookie: cookie)
        let page1 = try http.decode(data1, as: ListResponse.self)
        #expect(page1.items.count == 10)
        #expect(page1.hasMore == true)

        let lastUpdatedAt = ISO8601DateFormatter().string(from: page1.items.last!.updatedAt)
        let (_, data2, _) = try await http.request(
            "GET", "/api/posts?limit=10&after=\(lastUpdatedAt)", cookie: cookie
        )
        let page2 = try http.decode(data2, as: ListResponse.self)
        #expect(!page2.items.isEmpty)
    }

    @Test("GET /api/posts limit parameter: default, custom, edge cases, invalid value")
    func limitParameter() async throws {
        try await seedUser(email: "limit@test.com")
        let cookie = try await login(email: "limit@test.com")

        // Insert 15 posts with distinct timestamps
        let base = Date()
        for i in 0..<15 {
            let t = ISO8601DateFormatter().string(from: base.addingTimeInterval(Double(i)))
            let body = try JSONSerialization.data(withJSONObject: [
                "id": "lp-\(i)", "content": "c\(i)", "variant": "note",
                "createdAt": t, "updatedAt": t,
            ])
            _ = try await http.request("POST", "/api/posts", body: body, cookie: cookie)
        }

        // Default limit (no param) → 10 items
        do {
            let (_, data, _) = try await http.request("GET", "/api/posts", cookie: cookie)
            let page = try http.decode(data, as: ListResponse.self)
            #expect(page.items.count == 10, "default should be 10")
            #expect(page.hasMore == true)
        }

        // Explicit custom limit → respects value
        do {
            let (_, data, _) = try await http.request("GET", "/api/posts?limit=5", cookie: cookie)
            let page = try http.decode(data, as: ListResponse.self)
            #expect(page.items.count == 5, "limit=5 should return 5")
            #expect(page.hasMore == true)
        }

        // Limit larger than available items returns all
        do {
            let (_, data, _) = try await http.request("GET", "/api/posts?limit=100", cookie: cookie)
            let page = try http.decode(data, as: ListResponse.self)
            #expect(page.items.count == 15, "limit=100 should return all 15")
            #expect(page.hasMore == false)
        }

        // limit=1 returns 1 item
        do {
            let (_, data, _) = try await http.request("GET", "/api/posts?limit=1", cookie: cookie)
            let page = try http.decode(data, as: ListResponse.self)
            #expect(page.items.count == 1, "limit=1 should return 1")
            #expect(page.hasMore == true)
        }

        // limit=0 clamps to 1 (minimum page size)
        do {
            let (_, data, _) = try await http.request("GET", "/api/posts?limit=0", cookie: cookie)
            let page = try http.decode(data, as: ListResponse.self)
            #expect(page.items.count == 1, "limit=0 should clamp to 1")
            #expect(page.hasMore == true)
        }

        // Invalid limit (non-numeric) falls back to default 10
        do {
            let (_, data, _) = try await http.request("GET", "/api/posts?limit=abc", cookie: cookie)
            let page = try http.decode(data, as: ListResponse.self)
            #expect(page.items.count == 10, "invalid limit should default to 10")
        }

        // limit at the cap returns expected number
        do {
            let (_, data, _) = try await http.request(
                "GET", "/api/posts?limit=1000", cookie: cookie)
            let page = try http.decode(data, as: ListResponse.self)
            #expect(page.items.count == 15, "limit=1000 should return all 15 (cap at 1000 works)")
            #expect(page.hasMore == false)
        }
    }
}
