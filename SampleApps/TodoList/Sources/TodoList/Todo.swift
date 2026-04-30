import Foundation

public struct Todo: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var isCompleted: Bool
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        isCompleted: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.createdAt = createdAt
    }
}
