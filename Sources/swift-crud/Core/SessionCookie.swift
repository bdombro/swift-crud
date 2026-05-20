// SessionCookie.swift: builds Set-Cookie header values for the `user_id` session cookie.

import Foundation

/// Assembles `Set-Cookie` header values for the HMAC-signed `user_id` session.
///
/// Cookie attributes come from module-level `cookieDomain` (`COOKIE_DOMAIN`) and `cookieSecure`
/// (`COOKIE_SECURE`, default `true`). Omit `COOKIE_DOMAIN` for host-only cookies (typical local dev).
enum SessionCookie {
    private static let cookieName = "user_id"

    /// Full `Set-Cookie` header line after successful login.
    ///
    /// - Parameters:
    ///   - signedValue: HMAC-signed cookie payload from `AuthCookie.setCookie(userId:secret:)`.
    ///   - expires: HTTP-date for the `Expires` attribute (e.g. far-future session lifetime).
    /// - Returns: A complete `Set-Cookie` value suitable for the `Set-Cookie` response header.
    static func setHeader(signedValue: String, expires: String) -> String {
        attributeLine(value: signedValue, expires: expires)
    }

    /// Full `Set-Cookie` header line that clears the session on logout.
    ///
    /// Uses an empty value and epoch `Expires` so the browser deletes the cookie. Must use the same
    /// `Domain` and `Path` attributes as `setHeader` so the correct cookie is removed.
    ///
    /// - Returns: A complete `Set-Cookie` value for the `Set-Cookie` response header.
    static func clearHeader() -> String {
        attributeLine(value: "", expires: "Thu, 01 Jan 1970 00:00:00 GMT")
    }

    /// Builds `name=value` plus shared attributes: `Path=/`, `HttpOnly`, `SameSite=Lax`, optional `Secure` and `Domain`.
    private static func attributeLine(value: String, expires: String) -> String {
        var parts = ["\(cookieName)=\(value)", "Path=/", "Expires=\(expires)", "HttpOnly", "SameSite=Lax"]
        if cookieSecure { parts.append("Secure") }
        if let domain = cookieDomain, !domain.isEmpty { parts.append("Domain=\(domain)") }
        return parts.joined(separator: "; ")
    }
}
