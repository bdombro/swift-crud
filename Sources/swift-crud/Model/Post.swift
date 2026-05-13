// Post.swift: Blackbird model for the posts SQLite table (id, content, createdAt, updatedAt, userId, variant) — conforms to Codable for JSON serialization.

import Blackbird
import Foundation

struct Post: BlackbirdModel, Codable {
    nonisolated(unsafe) static var tableName: String = "posts"
    nonisolated(unsafe) static var primaryKey: [BlackbirdColumnKeyPath] = [\.$id]

    @BlackbirdColumn var id: String
    @BlackbirdColumn var content: String
    @BlackbirdColumn var createdAt: Date
    @BlackbirdColumn var updatedAt: Date
    @BlackbirdColumn var userId: Int
    @BlackbirdColumn var variant: String

    nonisolated(unsafe) static var indexes: [[BlackbirdColumnKeyPath]] = [
        [\.$userId, \.$updatedAt]
    ]
}
