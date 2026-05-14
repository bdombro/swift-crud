// HTTPRequest.swift: inbound HTTP representation, query parsing, and route handler type alias.

import Foundation
import NIOHTTP1

typealias HTTPHeader = String
typealias HTTPHeaders = [HTTPHeader: String]
typealias RequestHeaders = NIOHTTP1.HTTPHeaders
typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse

struct HTTPRequest: Sendable {
    struct QueryItem: Equatable {
        let name: String
        let value: String
    }

    let method: HTTPMethod
    let path: String
    let query: String
    let headers: RequestHeaders
    let body: Data
    /// Client IP for rate limiting / logging when provided by the server.
    let remoteAddress: String?
    var routeParameters: [String: String] = [:]
    /// Unique identifier for correlating logs across this request's lifecycle.
    var requestId: String? = nil

    /// Shared reference type so all struct copies see the same cached auth state.
    private final class AuthCache: @unchecked Sendable {
        /// nil = not yet computed, .none = computed-no-auth, .some(id) = authenticated
        var result: Int?? = nil
    }
    private let _authCache = AuthCache()

    var queryParameters: [String: String] {
        guard !query.isEmpty else { return [:] }
        let pairs = query.split(separator: "&").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let name = parts.first else { return nil }
            let value = parts.count == 2 ? String(parts[1]) : ""
            return (String(name), value.removingPercentEncoding ?? value)
        }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    var bodyData: Data {
        body
    }

    func cookie(_ name: String) -> String? {
        guard let cookieHeader = headers.first(name: "Cookie") else { return nil }
        for part in cookieHeader.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(name)=") {
                return String(trimmed.dropFirst(name.count + 1))
            }
        }
        return nil
    }

    /// The authenticated user ID, extracted from the HMAC-signed `user_id` cookie.
    /// Lazily computed and cached — only runs HMAC on first access.
    var authUserId: Int? {
        if let cached = _authCache.result { return cached }
        guard let val = cookie("user_id") else {
            _authCache.result = .some(nil)
            return nil
        }
        let id = AuthCookie.verify(val, secret: activeAuthSecret)
        _authCache.result = .some(id)
        return id
    }

    /// True once any copy of this request has resolved authUserId.
    var wasAuthChecked: Bool { _authCache.result != nil }

    func decode<T: Decodable>(as type: T.Type) async throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: body)
    }
}
