// Health.swift: health check endpoint — returns {status:ok} for load balancer and aaPanel health monitoring.

import Foundation

/// Health check endpoint — no auth required.
/// Returns 200 with {"status":"ok"} to signal the server is alive.
func healthz(req: HTTPRequest) async throws -> HTTPResponse {
    HTTPResponse.json(.ok, ["status": "ok"])
}

// MARK: - Route registration

/// Register the health check route on the shared `routes` instance.
func registerHealthRoutes() {
    routes.get("/healthz", handler: healthz)
}
