// PostModelTests: verifies Post schema and upsert/pagination SQL behavior.
// Each test uses its own in-memory DB — no module globals touched, runs in parallel.

import Testing
import Blackbird
import Foundation
@testable import swift_crud

// Mirrors the private upsertSQL from Posts.swift — tested here at the DB layer.
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

@Suite("Post model")
struct PostModelTests {

    // MARK: Schema

    @Test("schema resolves on a fresh in-memory DB")
    func schemaResolves() async throws {
        let db = try Blackbird.Database.inMemoryDatabase()
        try await Post.resolveSchema(in: db)
    }

    // MARK: Upsert conflict resolution

    @Test("insert a new post succeeds")
    func insertNew() async throws {
        let db = try Blackbird.Database.inMemoryDatabase()
        try await Post.resolveSchema(in: db)

        let now = Date()
        try await db.query(upsertSQL, now, "post-1", "hello", now, "user-1", "note", false)

        let posts = try await Post.read(from: db, sqlWhere: "id = ?", "post-1")
        #expect(posts.count == 1)
        #expect(posts[0].content == "hello")
        #expect(posts[0].isDeleted == false)
    }

    @Test("upsert with newer updatedAt updates content")
    func upsertNewer() async throws {
        let db = try Blackbird.Database.inMemoryDatabase()
        try await Post.resolveSchema(in: db)

        let t1 = Date()
        let t2 = t1.addingTimeInterval(60)

        try await db.query(upsertSQL, t1, "post-1", "original", t1, "user-1", "note", false)
        try await db.query(upsertSQL, t1, "post-1", "updated", t2, "user-1", "note", true)

        let post = try #require(try await Post.read(from: db, sqlWhere: "id = ?", "post-1").first)
        #expect(post.content == "updated")
        #expect(post.isDeleted == true)
    }

    @Test("upsert with older updatedAt overwrites content")
    func upsertOlder() async throws {
        let db = try Blackbird.Database.inMemoryDatabase()
        try await Post.resolveSchema(in: db)

        let t1 = Date()
        let t0 = t1.addingTimeInterval(-60)

        try await db.query(upsertSQL, t1, "post-1", "original", t1, "user-1", "note", false)
        try await db.query(upsertSQL, t0, "post-1", "stale", t0, "user-1", "note", true)

        let post = try #require(try await Post.read(from: db, sqlWhere: "id = ?", "post-1").first)
        #expect(post.content == "stale")
        #expect(post.isDeleted == true)
    }

    @Test("upsert from different userId leaves original post unchanged")
    func upsertWrongUser() async throws {
        let db = try Blackbird.Database.inMemoryDatabase()
        try await Post.resolveSchema(in: db)

        let t1 = Date()
        let t2 = t1.addingTimeInterval(60)

        try await db.query(upsertSQL, t1, "post-1", "user1-content", t1, "user-1", "note", false)
        // userId user-2 tries to overwrite post belonging to userId user-1
        try await db.query(upsertSQL, t1, "post-1", "user2-content", t2, "user-2", "note", true)

        let post = try #require(try await Post.read(from: db, sqlWhere: "id = ?", "post-1").first)
        #expect(post.content == "user1-content")
        #expect(post.isDeleted == false)
        #expect(post.userId == "user-1")
    }

    // MARK: Pagination ordering

    @Test("posts are returned newest-first up to limit")
    func paginationOrder() async throws {
        let db = try Blackbird.Database.inMemoryDatabase()
        try await Post.resolveSchema(in: db)

        let base = Date()
        for i in 0..<5 {
            let t = base.addingTimeInterval(Double(i) * 60)
            try await db.query(upsertSQL, t, "post-\(i)", "content \(i)", t, "user-1", "note", false)
        }

        let posts = try await Post.read(
            from: db,
            sqlWhere: "userId = ? ORDER BY updatedAt DESC LIMIT ?", "user-1", 3
        )
        #expect(posts.count == 3)
        #expect(posts[0].id == "post-4")
        #expect(posts[1].id == "post-3")
        #expect(posts[2].id == "post-2")
    }

    @Test("hasMore logic: fetching limit+1 indicates more pages exist")
    func hasMoreLogic() async throws {
        let db = try Blackbird.Database.inMemoryDatabase()
        try await Post.resolveSchema(in: db)

        let base = Date()
        for i in 0..<5 {
            let t = base.addingTimeInterval(Double(i) * 60)
            try await db.query(upsertSQL, t, "post-\(i)", "c", t, "user-1", "note", false)
        }

        let limit = 3
        var posts = try await Post.read(
            from: db,
            sqlWhere: "userId = ? ORDER BY updatedAt DESC LIMIT ?", "user-1", limit + 1
        )
        let hasMore = posts.count > limit
        if hasMore { posts.removeLast() }

        #expect(hasMore == true)
        #expect(posts.count == limit)
    }
}
