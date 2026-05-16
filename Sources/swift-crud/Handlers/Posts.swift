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
    var isDeleted: Bool?
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
    var isDeleted: Bool?
}

/// Payload for each item in a bulk upsert request.
struct UpsertPostPayload: Codable {
    var id: String
    var createdAt: Date
    var content: String
    var updatedAt: Date
    var variant: String
    var isDeleted: Bool
}

// MARK: - SQL

private let upsertSQL = """
    INSERT INTO posts (createdAt, id, content, updatedAt, userId, variant, isDeleted)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
    content = excluded.content,
    variant = excluded.variant,
    isDeleted = excluded.isDeleted,
    updatedAt = excluded.updatedAt
    WHERE posts.userId = excluded.userId
"""

// MARK: - Handlers (alphabetical)

/// Create a single post.  Duplicate `id` performs an upsert.
func createPost(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId else {
        return HTTPResponse.json(.unauthorized, ["message": "unauthorized"])
    }
    let body = try await req.decode(as: CreateRequestBody.self)
    guard body.content.count <= HTTPLimits.maxPostContentBytes else {
        return HTTPResponse.json(.badRequest, ["message": "content too long"])
    }
    guard body.variant.count <= HTTPLimits.maxPostContentBytes else {
        return HTTPResponse.json(.badRequest, ["message": "variant too long"])
    }
    let now = Date()

    _ = try await db.query(upsertSQL,
        body.createdAt ?? now,
        isValidID(body.id ?? "") ? body.id! : UUID().uuidString,
        body.content,
        body.updatedAt ?? now,
        userId,
        body.variant,
        body.isDeleted ?? false)

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
    guard let raw = req.routeParameters["id"], isValidID(raw) else {
        return HTTPResponse.json(.badRequest, ["message": "invalid post id"])
    }

    _ = try await db.query("DELETE FROM posts WHERE id = ? AND userId = ?", raw, userId)
    return HTTPResponse.json(.ok, ["message": "success"])
}

/// Fetch a single post by id, scoped to the authenticated user.
func getPost(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId else {
        return HTTPResponse.json(.unauthorized, ["message": "unauthorized"])
    }
    guard let raw = req.routeParameters["id"], isValidID(raw) else {
        return HTTPResponse.json(.badRequest, ["message": "invalid post id"])
    }

    guard let post = try await Post.read(from: db, sqlWhere: "id = ? AND userId = ?", raw, userId).first else {
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
    let limit = max(1, min(Int(query["limit"] ?? "10") ?? 10, 1000))
    let limitPlusOne = limit + 1

    var afterDate: Date? = nil
    if let afterStr = query["after"], !afterStr.isEmpty {
        guard let date = ISO8601DateFormatter().date(from: afterStr) else {
            return HTTPResponse.json(.badRequest, ["message": "invalid after cursor"])
        }
        afterDate = date
    }

    var posts: [Post]
    if let after = afterDate {
        posts = try await Post.read(from: db, sqlWhere: "userId = ? AND updatedAt > ? ORDER BY updatedAt DESC LIMIT ?", userId, after, limitPlusOne)
    } else {
        posts = try await Post.read(from: db, sqlWhere: "userId = ? ORDER BY updatedAt DESC LIMIT ?", userId, limitPlusOne)
    }

    let hasMore = posts.count > limit
    if hasMore { posts.removeLast() }

    return HTTPResponse.json(.ok, ListResponse(items: posts, hasMore: hasMore))
}

/// Put a post.  Acts as a complete replacement or a fallback to create.
func putPost(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId else {
        return HTTPResponse.json(.unauthorized, ["message": "unauthorized"])
    }
    guard let raw = req.routeParameters["id"] else {
        return HTTPResponse.json(.badRequest, ["message": "missing id parameter"])
    }
    guard isValidID(raw) else {
        return HTTPResponse.json(.badRequest, ["message": "invalid post id"])
    }
    let body = try await req.decode(as: CreateRequestBody.self)
    guard body.content.count <= HTTPLimits.maxPostContentBytes else {
        return HTTPResponse.json(.badRequest, ["message": "content too long"])
    }
    guard body.variant.count <= HTTPLimits.maxPostContentBytes else {
        return HTTPResponse.json(.badRequest, ["message": "variant too long"])
    }
    let now = Date()
    let updateTime = body.updatedAt ?? now

    let rows = try await db.query(
        upsertSQL + " RETURNING id",
        body.createdAt ?? now, raw, body.content, updateTime, userId, body.variant, body.isDeleted ?? false)

    if !rows.isEmpty {
        return HTTPResponse.json(.ok, ["message": "success"])
    } else {
        return HTTPResponse.json(.notFound, ["error": "Post not found or unauthorized"])
    }
}

/// Bulk upsert an array of posts in a single transaction.
func upsertManyPosts(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId else {
        return HTTPResponse.json(.unauthorized, ["message": "unauthorized"])
    }

    let payloads = try await req.decode(as: [UpsertPostPayload].self)
    guard !payloads.isEmpty else { return HTTPResponse.json(.ok, ["message": "success"]) }
    for post in payloads {
        guard post.content.count <= HTTPLimits.maxPostContentBytes else {
            return HTTPResponse.json(.badRequest, ["message": "content too long"])
        }
        guard post.variant.count <= HTTPLimits.maxPostContentBytes else {
            return HTTPResponse.json(.badRequest, ["message": "variant too long"])
        }
        guard isValidID(post.id) else {
            return HTTPResponse.json(.badRequest, ["message": "invalid id format"])
        }
    }

    try await db.transaction { core in
        for post in payloads {
            _ = try core.query(upsertSQL, post.createdAt, post.id, post.content, post.updatedAt, userId, post.variant, post.isDeleted)
        }
    }

    return HTTPResponse.json(.ok, ["message": "success"])
}

// MARK: - Route registration

/// Register all post routes on the shared `routes` instance.
func registerPostRoutes() {
    routes.get("/api/posts", handler: listPosts)
    routes.post("/api/posts", handler: createPost)
    routes.del("/api/posts", handler: deleteAllPosts)
    routes.get("/api/posts/:id", handler: getPost)
    routes.put("/api/posts/:id", handler: putPost)
    routes.del("/api/posts/:id", handler: deletePost)
    routes.post("/api/posts/upsert-many", handler: upsertManyPosts)
}

