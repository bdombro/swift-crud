// APIIntegrationTests: end-to-end HTTP tests against an in-process FlyingFox server.
// Uses .serialized because tests mutate module-level globals (db, emailSender, activeAuthSecret).
// Each test gets a fresh in-memory DB and a new server on port 0.

import CryptoKit
import Testing
import Blackbird
import Foundation
@testable import swift_crud

private enum TestError: Error {
    case serverDidNotBind
    case loginFailed
}

private func sha256(_ string: String) -> String {
    let data = Data(string.utf8)
    return SHA256.hash(data: data)
        .compactMap { String(format: "%02x", $0) }
        .joined()
}

@Suite("API integration", .serialized)
final class APIIntegrationTests {

    // Register routes into the global `routes` struct exactly once per test binary run.
    // Calling registerPostRoutes()/registerSessionRoutes() twice appends duplicate handlers.
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

        testDb = try Blackbird.Database.inMemoryDatabase()
        try await User.resolveSchema(in: testDb)
        try await Post.resolveSchema(in: testDb)

        mockEmail = MockEmailSender()

        // Set module globals before starting the server so handlers see the test state.
        db = testDb
        emailSender = mockEmail
        activeAuthSecret = "test-secret"

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
        try await testDb.query("UPDATE users SET codeCreatedAt = ? WHERE email = ?", Date(), "rate@test.com")

        let body = try http.jsonBody(["email": "rate@test.com"])
        let (status, _, _) = try await http.request("POST", "/api/session/send-code", body: body)
        #expect(status == 429)
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

    @Test("wrong code 3 times locks account; correct code then also fails")
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

        let user = try http.decode(data, as: User.self)
        #expect(user.id == userId)
        #expect(user.email == "session@test.com")
    }

    @Test("GET /api/session/ with tampered cookie returns 401")
    func getSessionTamperedCookie() async throws {
        let badSig = Data(repeating: 0xAB, count: 32).base64EncodedString()
        let (status, _, _) = try await http.request("GET", "/api/session/", cookie: "1.\(badSig)")
        #expect(status == 401)
    }

    @Test("POST /api/session/logout sets an expired cookie")
    func logout() async throws {
        try await seedUser(email: "logout@test.com")
        let cookie = try await login(email: "logout@test.com")

        let (status, _, headers) = try await http.request("POST", "/api/session/logout", cookie: cookie)
        #expect(status == 200)

        let clearedCookie = http.extractCookie(from: headers, name: "user_id")
        #expect(clearedCookie?.isEmpty == true)
    }

    // MARK: - Post CRUD tests

    @Test("full post CRUD round-trip: create, list, get, update, delete, 404")
    func postCrudRoundTrip() async throws {
        try await seedUser(email: "crud@test.com")
        let cookie = try await login(email: "crud@test.com")

        // Create
        let createBody = try http.jsonBody(["id": "e2e-1", "content": "Hello", "variant": "note"])
        let (createStatus, _, _) = try await http.request("POST", "/api/posts", body: createBody, cookie: cookie)
        #expect(createStatus == 201)

        // List
        let (listStatus, listData, _) = try await http.request("GET", "/api/posts", cookie: cookie)
        #expect(listStatus == 200)
        let list = try http.decode(listData, as: ListResponse.self)
        #expect(list.items.count == 1)
        #expect(list.items[0].id == "e2e-1")

        // Get
        let (getStatus, getData, _) = try await http.request("GET", "/api/posts/e2e-1", cookie: cookie)
        #expect(getStatus == 200)
        let post = try http.decode(getData, as: Post.self)
        #expect(post.content == "Hello")

        // Update (updatedAt must be newer than current)
        let newTime = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
        let updateBody = try http.jsonBody(["content": "Updated", "updatedAt": newTime])
        let (updateStatus, _, _) = try await http.request("PUT", "/api/posts/e2e-1", body: updateBody, cookie: cookie)
        #expect(updateStatus == 200)

        // Delete
        let (deleteStatus, _, _) = try await http.request("DELETE", "/api/posts/e2e-1", cookie: cookie)
        #expect(deleteStatus == 200)

        // Get after delete → 404
        let (notFoundStatus, _, _) = try await http.request("GET", "/api/posts/e2e-1", cookie: cookie)
        #expect(notFoundStatus == 404)
    }

    @Test("PUT with stale updatedAt returns 404")
    func putStaleTimestamp() async throws {
        try await seedUser(email: "stale@test.com")
        let cookie = try await login(email: "stale@test.com")

        let now = Date()
        let nowStr = ISO8601DateFormatter().string(from: now)
        let createBody = try http.jsonBody(["id": "stale-1", "content": "Original", "variant": "note",
                                            "updatedAt": nowStr])
        _ = try await http.request("POST", "/api/posts", body: createBody, cookie: cookie)

        // Stale updatedAt (before the current one)
        let staleStr = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let staleBody = try http.jsonBody(["content": "Stale", "updatedAt": staleStr])
        let (status, _, _) = try await http.request("PUT", "/api/posts/stale-1", body: staleBody, cookie: cookie)
        #expect(status == 404)
    }

    @Test("POST /api/posts/upsert-many inserts all posts")
    func upsertMany() async throws {
        try await seedUser(email: "bulk@test.com")
        let cookie = try await login(email: "bulk@test.com")

        let now = ISO8601DateFormatter().string(from: Date())
        let payload: [[String: String]] = [
            ["id": "b1", "content": "First", "variant": "note", "createdAt": now, "updatedAt": now],
            ["id": "b2", "content": "Second", "variant": "note", "createdAt": now, "updatedAt": now],
            ["id": "b3", "content": "Third", "variant": "note", "createdAt": now, "updatedAt": now],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (status, _, _) = try await http.request("POST", "/api/posts/upsert-many", body: body, cookie: cookie)
        #expect(status == 200)

        let (_, listData, _) = try await http.request("GET", "/api/posts?limit=10", cookie: cookie)
        let list = try http.decode(listData, as: ListResponse.self)
        #expect(list.items.count == 3)
    }

    @Test("DELETE /api/posts removes only the authenticated user's posts")
    func deleteAllPostsScoped() async throws {
        try await seedUser(email: "del1@test.com")
        let cookie1 = try await login(email: "del1@test.com")

        try await seedUser(email: "del2@test.com")
        let cookie2 = try await login(email: "del2@test.com")

        let now = ISO8601DateFormatter().string(from: Date())
        func mkBody(_ id: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["id": id, "content": "c", "variant": "note",
                                                       "createdAt": now, "updatedAt": now])
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

    @Test("pagination: first page has 10 items with hasMore=true; second page returns remainder")
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
}
