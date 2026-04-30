import Foundation

public enum TodoFilter: String, CaseIterable, Sendable {
    case all
    case active
    case completed

    public func matches(_ todo: Todo) -> Bool {
        switch self {
        case .all:       return true
        case .active:    return !todo.isCompleted
        case .completed: return todo.isCompleted
        }
    }
}
