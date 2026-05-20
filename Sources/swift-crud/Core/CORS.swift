// CORS.swift: cross-origin headers for browser clients on allowed frontend origins.

import Foundation
import NIOHTTP1

/// Credentialed CORS for browser frontends on a different origin than this API.
///
/// Configure allowed origins via `CORS_ALLOWED_ORIGINS` (comma-separated). When the list is empty,
/// all helpers no-op. The frontend must send `credentials: 'include'` (or `withCredentials: true`)
/// and this server must echo a specific `Access-Control-Allow-Origin` (never `*`).
enum CORS {
    private static let allowMethods = "GET, POST, PUT, DELETE, OPTIONS"
    private static let allowHeaders = "Content-Type, Authorization, Cookie"

    /// Returns the request's `Origin` header value if CORS is configured and the origin is allowed.
    ///
    /// - Parameter request: Incoming HTTP request (may include an `Origin` header from the browser).
    /// - Returns: The exact origin string to echo in `Access-Control-Allow-Origin`, or `nil` if CORS
    ///   is disabled, the header is missing, or the origin is not in `corsAllowedOrigins`.
    static func allowedOrigin(for request: HTTPRequest) -> String? {
        guard !corsAllowedOrigins.isEmpty,
            let origin = request.headers.first(name: "Origin"),
            corsAllowedOrigins.contains(origin)
        else { return nil }
        return origin
    }

    /// Builds a `204 No Content` response for a browser CORS preflight (`OPTIONS`).
    ///
    /// Call from the HTTP server before routing. Returns `nil` unless the method is `OPTIONS` and
    /// `allowedOrigin(for:)` succeeds. Includes `Access-Control-Allow-Credentials`, allowed methods
    /// and headers, and `Access-Control-Max-Age` so the browser can cache the preflight.
    ///
    /// - Parameter request: Preflight request from the browser.
    /// - Returns: A complete preflight response, or `nil` to continue normal routing.
    static func preflightResponse(for request: HTTPRequest) -> HTTPResponse? {
        guard request.method == .OPTIONS, let origin = allowedOrigin(for: request) else { return nil }
        var headers: HTTPHeaders = [
            HTTPHeader("Access-Control-Allow-Origin"): origin,
            HTTPHeader("Access-Control-Allow-Credentials"): "true",
            HTTPHeader("Vary"): "Origin",
            HTTPHeader("Access-Control-Allow-Methods"): allowMethods,
            HTTPHeader("Access-Control-Allow-Headers"): allowHeaders,
            HTTPHeader("Access-Control-Max-Age"): "86400",
        ]
        return HTTPResponse(statusCode: .noContent, headers: headers, body: Data())
    }

    /// Adds credentialed CORS headers to a handler response when the request origin is allowed.
    ///
    /// Sets `Access-Control-Allow-Origin` to the request origin (required for cookies),
    /// `Access-Control-Allow-Credentials: true`, and `Vary: Origin`. No-op when CORS is disabled
    /// or the origin is not allowlisted.
    ///
    /// - Parameters:
    ///   - response: Handler response to mutate in place.
    ///   - request: The request that produced `response` (used to read `Origin`).
    static func apply(to response: inout HTTPResponse, request: HTTPRequest) {
        guard let origin = allowedOrigin(for: request) else { return }
        response.headers[HTTPHeader("Access-Control-Allow-Origin")] = origin
        response.headers[HTTPHeader("Access-Control-Allow-Credentials")] = "true"
        response.headers[HTTPHeader("Vary")] = "Origin"
    }
}
