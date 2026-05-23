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
    var createdAt: Date?
    var content: String
    var updatedAt: Date?
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
func createPostHandler(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId else {
        return HTTPResponse.apiError(.unauthorized, .unauthorized)
    }
    let body = try await req.decode(as: CreateRequestBody.self)
    guard body.content.count <= HTTPLimits.maxPostContentBytes else {
        return HTTPResponse.apiError(.badRequest, .postContentTooLong)
    }
    guard body.variant.count <= HTTPLimits.maxPostContentBytes else {
        return HTTPResponse.apiError(.badRequest, .postVariantTooLong)
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
func deleteAllPostsHandler(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId else {
        return HTTPResponse.apiError(.unauthorized, .unauthorized)
    }
    _ = try await db.query("DELETE FROM posts WHERE userId = ?", userId)
    return HTTPResponse.json(.ok, ["message": "success"])
}

/// Delete a single post by id, scoped to the authenticated user.
func deletePostHandler(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId else {
        return HTTPResponse.apiError(.unauthorized, .unauthorized)
    }
    guard let raw = req.routeParameters["id"], isValidID(raw) else {
        return HTTPResponse.apiError(.badRequest, .invalidPostId)
    }

    _ = try await db.query("DELETE FROM posts WHERE id = ? AND userId = ?", raw, userId)
    return HTTPResponse.json(.ok, ["message": "success"])
}

/// Fetch a single post by id, scoped to the authenticated user.
func getPostHandler(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId else {
        return HTTPResponse.apiError(.unauthorized, .unauthorized)
    }
    guard let raw = req.routeParameters["id"], isValidID(raw) else {
        return HTTPResponse.apiError(.badRequest, .invalidPostId)
    }

    guard let post = try await Post.read(from: db, sqlWhere: "id = ? AND userId = ?", raw, userId).first else {
        return HTTPResponse.apiError(.notFound, .postNotFound)
    }
    return HTTPResponse.json(.ok, post)
}

/// List the authenticated user's posts, newest first, with optional cursor pagination.
func listPostsHandler(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId else {
        return HTTPResponse.apiError(.unauthorized, .unauthorized)
    }

    let query = req.queryParameters
    let limit = max(1, min(Int(query["limit"] ?? "10") ?? 10, 1000))
    let limitPlusOne = limit + 1

    var afterDate: Date? = nil
    if let afterStr = query["after"], !afterStr.isEmpty {
        guard let ms = Double(afterStr), ms >= 0 else {
            return HTTPResponse.apiError(.badRequest, .invalidAfterCursor)
        }
        afterDate = Date(timeIntervalSince1970: ms / 1000.0)
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
func putPostHandler(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId else {
        return HTTPResponse.apiError(.unauthorized, .unauthorized)
    }
    guard let raw = req.routeParameters["id"] else {
        return HTTPResponse.apiError(.badRequest, .missingPostIdParameter)
    }
    guard isValidID(raw) else {
        return HTTPResponse.apiError(.badRequest, .invalidPostId)
    }
    let body = try await req.decode(as: CreateRequestBody.self)
    guard body.content.count <= HTTPLimits.maxPostContentBytes else {
        return HTTPResponse.apiError(.badRequest, .postContentTooLong)
    }
    guard body.variant.count <= HTTPLimits.maxPostContentBytes else {
        return HTTPResponse.apiError(.badRequest, .postVariantTooLong)
    }
    let now = Date()
    let updateTime = body.updatedAt ?? now

    let rows = try await db.query(
        upsertSQL + " RETURNING id",
        body.createdAt ?? now, raw, body.content, updateTime, userId, body.variant, body.isDeleted ?? false)

    if !rows.isEmpty {
        return HTTPResponse.json(.ok, ["message": "success"])
    } else {
        return HTTPResponse.apiError(.notFound, .postNotFoundOrUnauthorized)
    }
}

/// Bulk upsert an array of posts in a single transaction.
func upsertManyPostsHandler(req: HTTPRequest) async throws -> HTTPResponse {
    guard let userId = req.authUserId else {
        return HTTPResponse.apiError(.unauthorized, .unauthorized)
    }

    let payloads = try await req.decode(as: [UpsertPostPayload].self)
    guard !payloads.isEmpty else { return HTTPResponse.json(.ok, ["message": "success"]) }
    for post in payloads {
        guard post.content.count <= HTTPLimits.maxPostContentBytes else {
            return HTTPResponse.apiError(.badRequest, .postContentTooLong)
        }
        guard post.variant.count <= HTTPLimits.maxPostContentBytes else {
            return HTTPResponse.apiError(.badRequest, .postVariantTooLong)
        }
        guard isValidID(post.id) else {
            return HTTPResponse.apiError(.badRequest, .invalidBulkPostId)
        }
    }

    let now = Date()
    try await db.transaction { core in
        for post in payloads {
            _ = try core.query(
                upsertSQL,
                post.createdAt ?? now,
                post.id,
                post.content,
                post.updatedAt ?? now,
                userId,
                post.variant,
                post.isDeleted)
        }
    }

    return HTTPResponse.json(.ok, ["message": "success"])
}

