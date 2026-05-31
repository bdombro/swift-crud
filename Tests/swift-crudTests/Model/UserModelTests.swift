// UserModelTests: verifies User schema resolution and Blackbird read/write behavior.
// Each test creates its own in-memory DB — no module globals touched, runs in parallel.

import Testing
import Blackbird
import Foundation
@testable import swift_crud

@Suite("User model")
struct UserModelTests {

    // MARK: Schema

    @Test("schema resolves on a fresh in-memory DB")
    func schemaResolves() async throws {
        let db = try Blackbird.Database.inMemoryDatabase()
        try await User.resolveSchema(in: db)
        // If resolveSchema throws, the test fails automatically
    }

    // MARK: Insert / read

    @Test("user inserted via raw SQL is readable via Blackbird")
    func insertAndRead() async throws {
        let db = try Blackbird.Database.inMemoryDatabase()
        try await User.resolveSchema(in: db)

        let now = Date()
        let uuid = UUID().uuidString
        try await db.query(
            "INSERT INTO users (id, codeAttempts, codeCreatedAt, codeHash, createdAt, email) VALUES (?, 0, ?, NULL, ?, ?)",
            uuid, now, now, "test@example.com"
        )

        let users = try await User.read(from: db, sqlWhere: "email = ?", "test@example.com")
        #expect(users.count == 1)
        #expect(users[0].id == uuid)
        #expect(users[0].email == "test@example.com")
        #expect(users[0].codeAttempts == 0)
        #expect(users[0].codeHash == nil)
    }

    @Test("user.write updates stored fields")
    func writeUpdatesFields() async throws {
        let db = try Blackbird.Database.inMemoryDatabase()
        try await User.resolveSchema(in: db)

        let now = Date()
        try await db.query(
            "INSERT INTO users (id, codeAttempts, codeCreatedAt, codeHash, createdAt, email) VALUES (?, 0, ?, 'hash', ?, ?)",
            UUID().uuidString, now, now, "update@example.com"
        )

        var user = try #require(try await User.read(from: db, sqlWhere: "email = ?", "update@example.com").first)
        user.codeHash = nil
        user.codeAttempts = nil
        user.codeCreatedAt = nil
        try await user.write(to: db)

        let updated = try #require(try await User.read(from: db, id: user.id))
        #expect(updated.codeHash == nil)
        #expect(updated.codeAttempts == nil)
        #expect(updated.codeCreatedAt == nil)
    }

    @Test("codeAttempts increments correctly")
    func incrementAttempts() async throws {
        let db = try Blackbird.Database.inMemoryDatabase()
        try await User.resolveSchema(in: db)

        let now = Date()
        try await db.query(
            "INSERT INTO users (id, codeAttempts, codeCreatedAt, codeHash, createdAt, email) VALUES (?, 1, ?, 'h', ?, ?)",
            UUID().uuidString, now, now, "attempts@example.com"
        )

        var user = try #require(try await User.read(from: db, sqlWhere: "email = ?", "attempts@example.com").first)
        user.codeAttempts = (user.codeAttempts ?? 0) + 1
        try await user.write(to: db)

        let reloaded = try #require(try await User.read(from: db, id: user.id))
        #expect(reloaded.codeAttempts == 2)
    }
}
