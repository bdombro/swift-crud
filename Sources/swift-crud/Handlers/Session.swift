// Session.swift: authentication session handlers — send-code, login, logout, and get-session.

import Blackbird
import Crypto
import Foundation

// MARK: - Request types

/// Request body for the send-code endpoint.
struct SendCodeRequest: Codable {
    var email: String
}

/// Request body for the login endpoint.
struct LoginRequest: Codable {
    var email: String
    /// 1–8 decimal digits; left-padded to 8 digits before verification (e.g. `"3910426"` → `"03910426"`).
    var code: String
}

/// Response body for a successful login containing the authenticated user's database ID.
struct LoginResponse: Codable {
    var userId: Int
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

// MARK: - Login codes

/// One-time login codes: eight decimal digits, zero-padded (e.g. `"00428173"`).
private let loginCodeLength = 8

/// Draws a cryptographically random 8-digit code in `00000000`…`99999999`.
private func generateLoginCode() -> String {
    let value = secureRandomUInt32()
    return String(format: "%0\(loginCodeLength)u", value % 100_000_000)
}

/// Normalizes user input to eight digits (left-pads shorter numeric strings).
private func normalizeLoginCode(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= loginCodeLength,
        trimmed.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains)
    else { return nil }
    return String(repeating: "0", count: loginCodeLength - trimmed.count) + trimmed
}

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
func getSessionHandler(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId
    else {
        return HTTPResponse.apiError(.unauthorized, .unauthorized)
    }
    return HTTPResponse.json(.ok, userId)
}

/// Exchange a login code for an HMAC-signed `user_id` session cookie.
///
/// On success, sets `Set-Cookie` via `SessionCookie` (`HttpOnly`, `SameSite=Lax`, optional `Domain` / `Secure`).
func loginHandler(req: HTTPRequest) async throws -> HTTPResponse {
    let body = try await req.decode(as: LoginRequest.self)

    guard let email = normalizeEmail(body.email) else {
        return HTTPResponse.apiError(.unauthorized, .invalidEmail)
    }

    let user = try await User.read(from: db, sqlWhere: "email = ?", email).first

    guard let code = normalizeLoginCode(body.code),
        let codeData = code.data(using: .utf8)
    else {
        return HTTPResponse.apiError(.badRequest, .invalidCodeEncoding)
    }
    let reqHash = SHA256.hash(data: codeData).compactMap { String(format: "%02x", $0) }.joined()

    // Accept the login only when a send-code is still pending: hash and createdAt exist,
    // fewer than 3 failed attempts (codeAttempts 0…2), and the code is younger than 10 minutes.
    // Compare SHA-256 hex digests in constant time so timing does not leak hash bytes.
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
        return HTTPResponse.apiError(.unauthorized, .invalidEmailOrPassword)
    }

    var u = user
    u.codeAttempts = nil
    u.codeCreatedAt = nil
    u.codeHash = nil
    try await u.write(to: db)

    let responseBody = LoginResponse(userId: user.id)
    var res = HTTPResponse.json(.ok, responseBody)
    let farFuture = "Wed, 01 Jan 2099 00:00:00 GMT"
    let signed = AuthCookie.setCookie(userId: user.id, secret: activeAuthSecret)
    res.headers.addValue(SessionCookie.setHeader(signedValue: signed, expires: farFuture), for: HTTPHeader("Set-Cookie"))
    return res
}

/// Clear the session cookie (expired `Set-Cookie` with the same `Domain` / `Path` as login).
func logoutHandler(req: HTTPRequest) async throws -> HTTPResponse {
    var res = HTTPResponse.json(.ok, ["message": "success"])
    res.headers.addValue(SessionCookie.clearHeader(), for: HTTPHeader("Set-Cookie"))
    return res
}

/// Request a one-time 8-digit login code. When SMTP is configured the code is emailed;
/// otherwise it is printed to stdout (`PrintEmailSender`).
func sendCodeHandler(req: HTTPRequest) async throws -> HTTPResponse {
    let body = try await req.decode(as: SendCodeRequest.self)

    guard let email = normalizeEmail(body.email) else {
        return HTTPResponse.apiError(.unauthorized, .invalidEmail)
    }

    let clientIP = req.remoteAddress ?? "unknown"
    let ipLimited = await sendCodeIPRateLimiter.checkAndRecord(
        key: clientIP, maxRequests: 10, windowSeconds: 60)
    guard !ipLimited else {
        return HTTPResponse.apiError(.tooManyRequests, .sendCodeIPRateLimited)
    }

    let rateLimited = await sendCodeRateLimiter.checkAndRecord(
        key: email, maxRequests: 5, windowSeconds: 60)
    guard !rateLimited else {
        return HTTPResponse.apiError(.tooManyRequests, .sendCodeEmailRateLimited)
    }

    if let user = try await User.read(from: db, sqlWhere: "email = ?", email).first {
        let twoMinsAgo = Date().addingTimeInterval(-120)
        if let created = user.codeCreatedAt, created > twoMinsAgo {
            return HTTPResponse.apiError(.tooManyRequests, .sendCodeCooldown)
        }
    }

    let code = generateLoginCode()
    let codeData = code.data(using: .utf8)!
    let hash = SHA256.hash(data: codeData).compactMap { String(format: "%02x", $0) }.joined()

    try await emailSender.send(code: code, to: email)

    if let user = try await User.read(from: db, sqlWhere: "email = ?", email).first {
        var u = user
        u.codeAttempts = 0
        u.codeCreatedAt = Date()
        u.codeHash = hash
        try await u.write(to: db)
    } else {
        _ = try await db.query(
            "INSERT INTO users (codeAttempts, codeCreatedAt, codeHash, createdAt, email) VALUES (0, ?, ?, ?, ?)",
            Date(), hash, Date(), email)
    }

    return HTTPResponse.json(.ok, ["message": "success"])
}

/// Resets send-code rate limiters — `@testable` from integration tests only.
internal func resetSendCodeRateLimitersForTesting() async {
    await sendCodeRateLimiter.resetForTesting()
    await sendCodeIPRateLimiter.resetForTesting()
}