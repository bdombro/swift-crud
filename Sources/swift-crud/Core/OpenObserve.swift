// OpenObserve.swift: handles asynchronous shipping of NDJSON log chunks to OpenObserve.
//
// Goal: Modularize and encapsulate the ingestion of structured NDJSON logs into the OpenObserve server.
// Why: Keeps core log buffering decoupled from network concerns, Basic Auth generation, and HTTP transport.
// How: Uses an asynchronous, non-blocking URLSession data task to post log payload blocks to OpenObserve.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A dedicated namespace containing state and transport logic for direct OpenObserve log ingestion.
enum OpenObserve {
    /// Cached URL for direct JSON ingestion.
    private nonisolated(unsafe) static var ingestURL: URL? = nil

    /// Cached Basic Authentication header.
    private nonisolated(unsafe) static var authHeader: String? = nil

    /// Wires OpenObserve configuration properties from the environment.
    ///
    /// - Parameter env: The loaded server environment context containing credentials.
    static func setup(env: Environment) {
        guard let urlStr = env.openobserveURL, let url = URL(string: urlStr),
              let user = env.openobserveUser, let pass = env.openobservePass
        else {
            return
        }

        Self.ingestURL = url
        let credentials = "\(user):\(pass)"
        if let credentialsData = credentials.data(using: .utf8) {
            Self.authHeader = "Basic \(credentialsData.base64EncodedString())"
        }
    }

    /// Asynchronously and non-blockingly ships NDJSON log records to OpenObserve.
    ///
    /// - Parameter data: Structured NDJSON log data chunk to ingest.
    static func ship(_ data: Data) {
        guard let url = Self.ingestURL, let auth = Self.authHeader, !data.isEmpty else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.httpBody = data
        request.timeoutInterval = 10

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                let errMsg = "swift-crud: OpenObserve transmission failed: \(error.localizedDescription)\n"
                _ = platformWrite(platformStderr, errMsg, errMsg.utf8.count)
                return
            }
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                let errMsg = "swift-crud: OpenObserve ingestion failed: HTTP \(httpResponse.statusCode)\n"
                _ = platformWrite(platformStderr, errMsg, errMsg.utf8.count)
            }
        }
        task.resume()
    }
}
