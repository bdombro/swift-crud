// Health.swift: health check endpoint — returns {status:ok} for load balancer and aaPanel health monitoring.

import Foundation

/// Health check endpoint — no auth required.
/// Returns 200 with {"status":"ok","db":"connected"} or 503 when DB is unreachable.
func healthz(req: HTTPRequest) async throws -> HTTPResponse {
    do {
        _ = try await db.query("SELECT 1")
        return HTTPResponse.json(.ok, ["status": "ok", "db": "connected"])
    } catch {
        return HTTPResponse.json(.serviceUnavailable, ["status": "error", "db": "unavailable"])
    }
}

// MARK: - Route registration

/// Register the health check route on the shared `routes` instance.
func registerHealthRoutes() {
    routes.get("/healthz", handler: healthz)
}
