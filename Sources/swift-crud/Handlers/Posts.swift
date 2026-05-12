// Posts.swift: CRUD handlers for posts — create, list (with cursor pagination), get, update (last-write-wins conflict resolution), delete, and bulk upsert, all scoped to the authenticated user.

import Blackbird
import Foundation

// MARK: - Request / response types

/// Request body for creating a single post.
struct CreateRequestBody: Codable {
    var id: String?
    var createdAt: Date?
    var content: String
    var updatedAt: Date?
    var variant: String
}

/// Paginated list of posts returned to the client.
struct ListResponse: Codable {
    var items: [Post]
    var hasMore: Bool
}

/// Request body for updating a post.
struct UpdateRequestBody: Codable {
    var content: String
    var updatedAt: Date?
}

/// Payload for each item in a bulk upsert request.
struct UpsertPostPayload: Codable {
    var id: String
    var createdAt: Date
    var content: String
    var updatedAt: Date
    var variant: String
}

// MARK: - SQL

private let upsertSQL = """
    INSERT INTO posts (createdAt, id, content, updatedAt, userId, variant)
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
    content = excluded.content,
    variant = excluded.variant,
    updatedAt = excluded.updatedAt
    WHERE posts.updatedAt < excluded.updatedAt AND posts.userId = excluded.userId
"""

// MARK: - Handlers (alphabetical)

/// Create a single post.  Duplicate `id` performs an upsert.
func createPost(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId else {
        return HTTPResponse.json(.unauthorized, ["message": "unauthorized"])
    }
    let body = try await req.decode(as: CreateRequestBody.self)
    let now = Date()

    _ = try await db.query(upsertSQL,
        body.createdAt ?? now,
        body.id ?? UUID().uuidString,
        body.content,
        body.updatedAt ?? now,
        userId,
        body.variant)

    return HTTPResponse.json(.created, ["message": "success"])
}

/// Delete all posts belonging to the authenticated user.
func deleteAllPosts(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId else {
        return HTTPResponse.json(.unauthorized, ["message": "unauthorized"])
    }
    _ = try await db.query("DELETE FROM posts WHERE userId = ?", userId)
    return HTTPResponse.json(.ok, ["message": "success"])
}

/// Delete a single post by id, scoped to the authenticated user.
func deletePost(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId else {
        return HTTPResponse.json(.unauthorized, ["message": "unauthorized"])
    }
    let id = req.routeParameters["id"]!

    _ = try await db.query("DELETE FROM posts WHERE id = ? AND userId = ?", id, userId)
    return HTTPResponse.json(.ok, ["message": "success"])
}

/// Fetch a single post by id, scoped to the authenticated user.
func getPost(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId else {
        return HTTPResponse.json(.unauthorized, ["message": "unauthorized"])
    }
    let id = req.routeParameters["id"]!

    guard let post = try await Post.read(from: db, sqlWhere: "id = ? AND userId = ?", id, userId).first else {
        return HTTPResponse.json(.notFound, ["error": "Post not found"])
    }
    return HTTPResponse.json(.ok, post)
}

/// List the authenticated user's posts, newest first, with optional cursor pagination.
func listPosts(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId else {
        return HTTPResponse.json(.unauthorized, ["message": "unauthorized"])
    }

    let query = req.queryParameters
    let limit = min(Int(query["limit"] ?? "10") ?? 10, 1000)
    let limitPlusOne = limit + 1
    let afterDate = query["after"].flatMap { ISO8601DateFormatter().date(from: $0) }

    var posts: [Post]
    if let after = afterDate {
        posts = try await Post.read(from: db, sqlWhere: "userId = ? AND updatedAt >= ? ORDER BY updatedAt DESC LIMIT ?", userId, after, limitPlusOne)
    } else {
        posts = try await Post.read(from: db, sqlWhere: "userId = ? ORDER BY updatedAt DESC LIMIT ?", userId, limitPlusOne)
    }

    let hasMore = posts.count > limit
    if hasMore { posts.removeLast() }

    return HTTPResponse.json(.ok, ListResponse(items: posts, hasMore: hasMore))
}

/// Update a post.  The request must supply an `updatedAt` newer than the stored value.
func updatePost(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId else {
        return HTTPResponse.json(.unauthorized, ["message": "unauthorized"])
    }
    let id = req.routeParameters["id"]!
    let body = try await req.decode(as: UpdateRequestBody.self)
    let updateTime = body.updatedAt ?? Date()

    _ = try await db.query(
        "UPDATE posts SET content = ?, updatedAt = ? WHERE id = ? AND userId = ? AND updatedAt < ?",
        body.content, updateTime, id, userId, updateTime)

    let updated = try await Post.read(
        from: db, sqlWhere: "id = ? AND userId = ? AND updatedAt = ?", id, userId, updateTime
    ).first != nil

    if updated {
        return HTTPResponse.json(.ok, ["message": "success"])
    } else {
        return HTTPResponse.json(.notFound, ["error": "Post not found or supplied update_at is less than existing"])
    }
}

/// Bulk upsert an array of posts in a single transaction.
func upsertManyPosts(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId else {
        return HTTPResponse.json(.unauthorized, ["message": "unauthorized"])
    }

    let payloads = try await req.decode(as: [UpsertPostPayload].self)
    guard !payloads.isEmpty else { return HTTPResponse.json(.ok, ["message": "success"]) }

    try await db.transaction { core in
        for post in payloads {
            _ = try core.query(upsertSQL, post.createdAt, post.id, post.content, post.updatedAt, userId, post.variant)
        }
    }

    return HTTPResponse.json(.ok, ["message": "success"])
}

// MARK: - Route registration

/// Register all post routes on the shared `routes` instance.
func registerPostRoutes() {
    routes.get("/api/posts", handler: listPosts)
    routes.post("/api/posts", handler: createPost)
    routes.post("/api/posts/upsert-many", handler: upsertManyPosts)
    routes.del("/api/posts", handler: deleteAllPosts)
    routes.get("/api/posts/:id", handler: getPost)
    routes.put("/api/posts/:id", handler: updatePost)
    routes.del("/api/posts/:id", handler: deletePost)
}

