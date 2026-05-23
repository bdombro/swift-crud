// HTTPResponse.swift: outbound HTTP representation and JSON helper with safe encoding.

import Foundation
import NIOHTTP1

struct HTTPResponse {
    var statusCode: HTTPResponseStatus
    var headers: HTTPHeaders
    var body: Data

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    static func json<T: Encodable>(_ status: HTTPResponseStatus, _ payload: T) -> HTTPResponse {
        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            data = Data(#"{"jsonError":"encoding failed"}"#.utf8)
        }
        let headers: HTTPHeaders = [
            HTTPHeader("Content-Type"): "application/json",
            HTTPHeader("X-Content-Type-Options"): "nosniff",
            HTTPHeader("X-Frame-Options"): "DENY",
            HTTPHeader("Content-Security-Policy"): "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
        ]
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
