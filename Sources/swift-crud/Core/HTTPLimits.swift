// HTTPLimits.swift: shared numeric caps for HTTP request bodies and handler-level payload fields.

/// Shared HTTP limits for the server and handlers.
enum HTTPLimits {
    /// Maximum request body size accepted by the server (bytes).
    static let maxRequestBodyBytes = 1_000_000

    /// Maximum `content` field length for post payloads (bytes).
    static let maxPostContentBytes = 100_000
}
