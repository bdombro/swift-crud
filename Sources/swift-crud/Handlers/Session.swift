// Session.swift: authentication session handlers — send-code, login (code verification), logout, and get-session, all registered on the shared routes instance.

import Blackbird
import CryptoKit
import Foundation

// MARK: - Request types

/// Request body for the send-code endpoint.
struct SendCodeRequest: Codable {
    var email: String
}

/// Request body for the login endpoint.
struct LoginRequest: Codable {
    var email: String
    var code: String
}

// MARK: - Handlers (alphabetical)

/// Return the currently authenticated user's profile.
func getSession(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId,
          let user = try await User.read(from: db, id: userId)
    else {
        return HTTPResponse.json(.unauthorized, ["message": "unauthorized"])
    }
    return HTTPResponse.json(.ok, user)
}

/// Exchange a login code for an HMAC-signed `user_id` cookie.
func login(req: HTTPRequest) async throws -> HTTPResponse {
    let body = try await req.decode(as: LoginRequest.self)

    guard let user = try await User.read(from: db, sqlWhere: "email = ?", body.email).first,
          let hash = user.codeHash,
          let created = user.codeCreatedAt,
          (user.codeAttempts ?? 0) <= 2,
          created >= Date().addingTimeInterval(-600)
    else {
        return HTTPResponse.json(.unauthorized, ["message": "invalid email or password"])
    }

    let codeData = body.code.data(using: .utf8)!
    let reqHash = SHA256.hash(data: codeData).compactMap { String(format: "%02x", $0) }.joined()

    guard reqHash == hash else {
        var u = user
        u.codeAttempts = (u.codeAttempts ?? 0) + 1
        try await u.write(to: db)
        return HTTPResponse.json(.unauthorized, ["message": "invalid email or password"])
    }

    var u = user
    u.codeAttempts = nil
    u.codeCreatedAt = nil
    u.codeHash = nil
    try await u.write(to: db)

    var res = HTTPResponse.json(.ok, ["message": "success"])
    let farFuture = "Wed, 01 Jan 2099 00:00:00 GMT"
    let cookieValue = "\(AuthCookie.setCookie(userId: user.id, secret: activeAuthSecret)); Path=/; Expires=\(farFuture)"
    res.headers.addValue("user_id=\(cookieValue)", for: HTTPHeader("Set-Cookie"))
    return res
}

/// Clear the session cookie.
func logout(req: HTTPRequest) async throws -> HTTPResponse {
    var res = HTTPResponse.json(.ok, ["message": "success"])
    res.headers.addValue("user_id=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT", for: HTTPHeader("Set-Cookie"))
    return res
}

/// Request a one-time login code.  When SMTP is configured the code is emailed;
/// otherwise it is printed to stdout.
func sendCode(req: HTTPRequest) async throws -> HTTPResponse {
    let body = try await req.decode(as: SendCodeRequest.self)

    guard body.email.contains("@") else {
        return HTTPResponse.json(.unauthorized, ["message": "invalid email"])
    }

    let code = String(format: "%08d", Int.random(in: 0..<100_000_000))
    let codeData = code.data(using: .utf8)!
    let hash = SHA256.hash(data: codeData).compactMap { String(format: "%02x", $0) }.joined()

    if let user = try await User.read(from: db, sqlWhere: "email = ?", body.email).first {
        let twoMinsAgo = Date().addingTimeInterval(-120)
        if let created = user.codeCreatedAt, created > twoMinsAgo {
            return HTTPResponse.json(.tooManyRequests, ["message": "Wait 2 minutes after requesting a code to try again."])
        }

        var u = user
        u.codeAttempts = 0
        u.codeCreatedAt = Date()
        u.codeHash = hash
        try await u.write(to: db)
    } else {
        _ = try await db.query(
            "INSERT INTO users (codeAttempts, codeCreatedAt, codeHash, email) VALUES (0, ?, ?, ?)",
            Date(), hash, body.email)
    }

    try await emailSender.send(code: code, to: body.email)
    return HTTPResponse.json(.ok, ["message": "success"])
}

// MARK: - Route registration

/// Register all session routes on the shared `routes` instance.
func registerSessionRoutes() {
    routes.get("/api/session", handler: getSession)
    routes.post("/api/session/send-code", handler: sendCode)
    routes.post("/api/session/login", handler: login)
    routes.post("/api/session/logout", handler: logout)
}