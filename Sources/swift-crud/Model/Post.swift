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
    @BlackbirdColumn var isDeleted: Bool = false

    nonisolated(unsafe) static var indexes: [[BlackbirdColumnKeyPath]] = [
        [\.$userId, \.$updatedAt]
    ]
}
