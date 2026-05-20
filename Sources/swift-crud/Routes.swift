// Routes.swift: central route table — registers all HTTP handlers on the shared `routes` instance.

import Foundation

/// Registers every API route on the module-level `routes` instance.
func registerRoutes() {
    routes.get("/api/healthz", handler: healthzHandler)

    routes.get("/api/session", handler: getSessionHandler)
    routes.post("/api/session/send-code", handler: sendCodeHandler)
    routes.post("/api/session/login", handler: loginHandler)
    routes.post("/api/session/logout", handler: logoutHandler)

    routes.get("/api/posts", handler: listPostsHandler)
    routes.post("/api/posts", handler: createPostHandler)
    routes.del("/api/posts", handler: deleteAllPostsHandler)
    routes.get("/api/posts/:id", handler: getPostHandler)
    routes.put("/api/posts/:id", handler: putPostHandler)
    routes.del("/api/posts/:id", handler: deletePostHandler)
    routes.post("/api/posts/upsert-many", handler: upsertManyPostsHandler)
}
