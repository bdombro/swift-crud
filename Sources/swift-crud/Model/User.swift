// User.swift: Blackbird model for the users SQLite table (id, email, codeHash, codeAttempts, codeCreatedAt, createdAt) — conforms to Codable for JSON serialization.

import Blackbird
import Foundation

struct User: BlackbirdModel, Codable {
    nonisolated(unsafe) static var tableName: String = "users"
    nonisolated(unsafe) static var primaryKey: [BlackbirdColumnKeyPath] = [\.$id]

    @BlackbirdColumn var id: Int
    @BlackbirdColumn var createdAt: Date
    @BlackbirdColumn var codeAttempts: Int?
    @BlackbirdColumn var codeCreatedAt: Date?
    @BlackbirdColumn var codeHash: String?
    @BlackbirdColumn var email: String
}
