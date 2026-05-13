// HTTPHelpers.swift: core HTTP types (HTTPRequest, HTTPResponse), HMAC-signed auth cookie helpers, module-level globals (authSecret, db, emailSender), and JSON encoding utilities.

import Blackbird
import CryptoKit
import Foundation
import NIOHTTP1

typealias HTTPHeader = String
typealias HTTPHeaders = [HTTPHeader: String]
typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse

/// Module-level auth secret for HMAC-signing the `user_id` cookie.
nonisolated(unsafe) var activeAuthSecret: String = "change-me"

/// Module-level database reference set once at startup.
nonisolated(unsafe) var db: Blackbird.Database!

/// Module-level email sender set once at startup.
nonisolated(unsafe) var emailSender: EmailSender = PrintEmailSender()

/// Background queue for async file-based request logs. nil when LOG_FILE is not set.
nonisolated(unsafe) var logFileWriteQueue: DispatchQueue? = nil

/// File path used by logFileWriteQueue. Nil when LOG_FILE is not set.
nonisolated(unsafe) var logFilePath: String? = nil

// MARK: - Auth cookie (HMAC-signed)

/// Namespace for HMAC-signed `user_id` cookie helpers.
enum AuthCookie {
    /// Sign a user ID for use as the cookie value.
    static func sign(userId: Int, with secret: String) -> String {
        let data = Data("\(userId)".utf8)
        let key = SymmetricKey(data: Data(secret.utf8))
        let hmac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        let sig = Data(hmac).base64EncodedString()
        return "\(userId).\(sig)"
    }

    /// Verify and extract the user ID from a signed cookie value.
    /// Returns `nil` if the signature is missing, malformed, or invalid.
    static func verify(_ cookieValue: String, secret: String) -> Int? {
        let parts = cookieValue.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
            let userId = Int(parts[0])
        else { return nil }

        let data = Data("\(parts[0])".utf8)
        let key = SymmetricKey(data: Data(secret.utf8))
        let expected = HMAC<SHA256>.authenticationCode(for: data, using: key)

        guard let sigData = Data(base64Encoded: String(parts[1])),
            sigData.count == SHA256.byteCount
        else { return nil }
        // Constant-time comparison of the raw bytes
        let expectedData = Data(expected)
        guard expectedData == sigData else { return nil }

        return userId
    }

    /// Set the `user_id` cookie on a response (signed value).
    static func setCookie(userId: Int, secret: String) -> String {
        sign(userId: userId, with: secret)
    }
}

// MARK: - HTTP primitives

struct HTTPRequest {
    struct QueryItem: Equatable {
        let name: String
        let value: String
    }

    let method: HTTPMethod
    let path: String
    let query: String
    let headers: HTTPHeaders
    let body: Data
    var routeParameters: [String: String] = [:]

    var queryParameters: [String: String] {
        guard !query.isEmpty else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: query.split(separator: "&").compactMap { pair in
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard let name = parts.first else { return nil }
                let value = parts.count == 2 ? String(parts[1]) : ""
                return (String(name), value.removingPercentEncoding ?? value)
            })
    }

    var bodyData: Data {
        body
    }

    func cookie(_ name: String) -> String? {
        guard let cookieHeader = headers[HTTPHeader("Cookie")] else { return nil }
        for part in cookieHeader.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(name)=") {
                return String(trimmed.dropFirst(name.count + 1))
            }
        }
        return nil
    }

    /// The authenticated user ID, extracted from the HMAC-signed `user_id` cookie.
    var authUserId: Int? {
        guard let val = cookie("user_id") else { return nil }
        return AuthCookie.verify(val, secret: activeAuthSecret)
    }

    func decode<T: Decodable>(as type: T.Type) async throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: body)
    }
}

struct HTTPResponse {
    var statusCode: HTTPResponseStatus
    var headers: HTTPHeaders
    var body: Data

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static func json<T: Encodable>(_ status: HTTPResponseStatus, _ payload: T) -> HTTPResponse {
        let data = try! encoder.encode(payload)
        let headers: HTTPHeaders = [HTTPHeader("Content-Type"): "application/json"]
        return HTTPResponse(statusCode: status, headers: headers, body: data)
    }
}

extension Dictionary where Key == HTTPHeader, Value == String {
    mutating func addValue(_ value: String, for key: HTTPHeader) {
        if let existing = self[key] {
            self[key] = existing + ", " + value
        } else {
            self[key] = value
        }
    }
}
