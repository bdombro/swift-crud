// HTTPClient: thin URLSession wrapper for integration tests.
// Manages cookies manually so each test controls auth state explicitly.

import Foundation

/// Per-test HTTP helper that talks to an in-process server and manages auth cookies manually.
struct HTTPClient {

    let baseURL: URL

    /// Ephemeral session with cookie jar disabled — we set Cookie headers ourselves.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg)
    }()

    func request(
        _ method: String,
        _ path: String,
        body: Data? = nil,
        cookie: String? = nil
    ) async throws -> (statusCode: Int, data: Data, headers: [String: String]) {
        let url = URL(string: path, relativeTo: baseURL)!
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let cookie { req.setValue("user_id=\(cookie)", forHTTPHeaderField: "Cookie") }
        req.httpBody = body

        let (data, response) = try await Self.session.data(for: req)
        let http = response as! HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers["\(k)"] = "\(v)" }
        return (http.statusCode, data, headers)
    }

    func jsonBody<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(value)
    }

    func decode<T: Decodable>(_ data: Data, as _: T.Type = T.self) throws -> T {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(T.self, from: data)
    }

    /// Extracts the value of a named cookie from a `Set-Cookie` response header.
    func extractCookie(from headers: [String: String], name: String) -> String? {
        let raw =
            headers.first(where: { $0.key.lowercased() == "set-cookie" })?.value ?? ""
        guard raw.hasPrefix("\(name)=") else { return nil }
        return raw
            .split(separator: ";")
            .first
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .map { String($0.dropFirst(name.count + 1)) }
    }
}
