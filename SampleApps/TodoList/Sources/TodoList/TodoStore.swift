import Foundation

public struct TodoStore: Sendable, Equatable {
    public private(set) var todos: [Todo]

    public init(todos: [Todo] = []) {
        self.todos = todos
    }

    public mutating func add(_ todo: Todo) {
        todos.append(todo)
    }

    public mutating func remove(id: Todo.ID) {
        todos.removeAll { $0.id == id }
    }

    public mutating func toggle(id: Todo.ID) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].isCompleted.toggle()
    }

    public mutating func rename(id: Todo.ID, to title: String) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].title = title
    }

    public func filtered(by filter: TodoFilter) -> [Todo] {
        todos.filter { filter.matches($0) }
    }

    public var activeCount: Int {
        todos.lazy.filter { !$0.isCompleted }.count
    }

    public var completedCount: Int {
        todos.lazy.filter(\.isCompleted).count
    }

    public mutating func clearCompleted() {
        todos.removeAll(where: \.isCompleted)
    }
}
