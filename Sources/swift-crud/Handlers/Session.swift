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

// MARK: - Rate limiter for send-code

private actor SendCodeRateLimiter {
    private var timestamps: [String: [Date]] = [:]

    /// Returns `true` if `key` has already hit `maxRequests` within `windowSeconds`; otherwise records this attempt.
    func checkAndRecord(key: String, maxRequests: Int, windowSeconds: TimeInterval) -> Bool {
        let now = Date()
        var recent = timestamps[key, default: []].filter { now.timeIntervalSince($0) < windowSeconds }
        if recent.count >= maxRequests { return true }
        recent.append(now)
        timestamps[key] = recent
        
        // Prevent unbounded memory growth from unique IPs/emails
        if timestamps.count > 100_000 {
            timestamps.removeAll()
        }
        
        return false
    }

    /// Clears all windows — used by integration tests so per-IP/email limits do not leak across cases.
    func resetForTesting() {
        timestamps = [:]
    }
}

private let sendCodeRateLimiter = SendCodeRateLimiter()

/// Limits send-code abuse by client IP (separate from per-email limits).
private let sendCodeIPRateLimiter = SendCodeRateLimiter()

// MARK: - Constant-time helpers

/// Constant-time comparison for login code hashes (mitigates timing side channels).
private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var result: UInt8 = 0
    for i in 0..<lhs.count {
        result |= lhs[i] ^ rhs[i]
    }
    return result == 0
}

// MARK: - Handlers (alphabetical)

/// Return the currently authenticated user's profile.
func getSession(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId
    else {
        return HTTPResponse.json(.unauthorized, ["message": "unauthorized"])
    }
    return HTTPResponse.json(.ok, userId)
}

/// Exchange a login code for an HMAC-signed `user_id` session cookie.
///
/// On success, sets `Set-Cookie` via `SessionCookie` (`HttpOnly`, `SameSite=Lax`, optional `Domain` / `Secure`).
func login(req: HTTPRequest) async throws -> HTTPResponse {
    let body = try await req.decode(as: LoginRequest.self)

    let user = try await User.read(from: db, sqlWhere: "email = ?", body.email).first

    guard let codeData = body.code.data(using: .utf8) else {
        return HTTPResponse.json(.badRequest, ["message": "invalid code encoding"])
    }
    let reqHash = SHA256.hash(data: codeData).compactMap { String(format: "%02x", $0) }.joined()

    let hashMatch: Bool
    if let user, let hash = user.codeHash, let created = user.codeCreatedAt,
       (user.codeAttempts ?? 0) <= 2,
       created >= Date().addingTimeInterval(-600) {
        hashMatch = constantTimeEqual(Data(reqHash.utf8), Data(hash.utf8))
    } else {
        hashMatch = false
    }

    if !hashMatch, let user, let userHash = user.codeHash,
        !constantTimeEqual(Data(reqHash.utf8), Data(userHash.utf8)),
        let created = user.codeCreatedAt, created >= Date().addingTimeInterval(-600) {
        var u = user
        u.codeAttempts = (u.codeAttempts ?? 0) + 1
        try await u.write(to: db)
    }

    guard hashMatch, let user else {
        return HTTPResponse.json(.unauthorized, ["message": "invalid email or password"])
    }

    var u = user
    u.codeAttempts = nil
    u.codeCreatedAt = nil
    u.codeHash = nil
    try await u.write(to: db)

    var res = HTTPResponse.json(.ok, ["message": "success"])
    let farFuture = "Wed, 01 Jan 2099 00:00:00 GMT"
    let signed = AuthCookie.setCookie(userId: user.id, secret: activeAuthSecret)
    res.headers.addValue(SessionCookie.setHeader(signedValue: signed, expires: farFuture), for: HTTPHeader("Set-Cookie"))
    return res
}

/// Clear the session cookie (expired `Set-Cookie` with the same `Domain` / `Path` as login).
func logout(req: HTTPRequest) async throws -> HTTPResponse {
    var res = HTTPResponse.json(.ok, ["message": "success"])
    res.headers.addValue(SessionCookie.clearHeader(), for: HTTPHeader("Set-Cookie"))
    return res
}

/// Request a one-time login code.  When SMTP is configured the code is emailed;
/// otherwise it is printed to stdout.
func sendCode(req: HTTPRequest) async throws -> HTTPResponse {
    let body = try await req.decode(as: SendCodeRequest.self)

    guard body.email.contains("@"),
        body.email.count >= 5,
        body.email.count <= 254,
        body.email.split(separator: "@", omittingEmptySubsequences: false).count == 2
    else {
        return HTTPResponse.json(.unauthorized, ["message": "invalid email"])
    }

    let clientIP = req.remoteAddress ?? "unknown"
    let ipLimited = await sendCodeIPRateLimiter.checkAndRecord(
        key: clientIP, maxRequests: 10, windowSeconds: 60)
    guard !ipLimited else {
        return HTTPResponse.json(
            .tooManyRequests,
            ["message": "Too many code requests from this network. Try again later."])
    }

    let rateLimited = await sendCodeRateLimiter.checkAndRecord(
        key: body.email, maxRequests: 5, windowSeconds: 60)
    guard !rateLimited else {
        return HTTPResponse.json(.tooManyRequests, ["message": "Too many code requests. Try again later."])
    }

    let code = Data((0..<20).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
    let codeData = code.data(using: .utf8)!
    let hash = SHA256.hash(data: codeData).compactMap { String(format: "%02x", $0) }.joined()

    if let user = try await User.read(from: db, sqlWhere: "email = ?", body.email).first {
        let twoMinsAgo = Date().addingTimeInterval(-120)
        if let created = user.codeCreatedAt, created > twoMinsAgo {
            return HTTPResponse.json(
                .tooManyRequests,
                ["message": "Wait 2 minutes after requesting a code to try again."])
        }

        var u = user
        u.codeAttempts = 0
        u.codeCreatedAt = Date()
        u.codeHash = hash
        try await u.write(to: db)
    } else {
        _ = try await db.query(
            "INSERT INTO users (codeAttempts, codeCreatedAt, codeHash, createdAt, email) VALUES (0, ?, ?, ?, ?)",
            Date(), hash, Date(), body.email)
    }

    try await emailSender.send(code: code, to: body.email)
    return HTTPResponse.json(.ok, ["message": "success"])
}

/// Resets send-code rate limiters — `@testable` from integration tests only.
internal func resetSendCodeRateLimitersForTesting() async {
    await sendCodeRateLimiter.resetForTesting()
    await sendCodeIPRateLimiter.resetForTesting()
}

// MARK: - Route registration

/// Register all session routes on the shared `routes` instance.
func registerSessionRoutes() {
    routes.get("/api/session", handler: getSession)
    routes.post("/api/session/send-code", handler: sendCode)
    routes.post("/api/session/login", handler: login)
    routes.post("/api/session/logout", handler: logout)
}
