import XCTest
@testable import TodoList

final class TodoStoreTests: XCTestCase {

    func testInitDefaultsToEmpty() {
        let store = TodoStore()
        XCTAssertTrue(store.todos.isEmpty)
        XCTAssertEqual(store.activeCount, 0)
        XCTAssertEqual(store.completedCount, 0)
    }

    func testInitWithSeedSetsTodos() {
        let seed = [Todo(title: "a"), Todo(title: "b")]
        let store = TodoStore(todos: seed)
        XCTAssertEqual(store.todos, seed)
    }

    func testAddAppendsToEnd() {
        var store = TodoStore()
        let todo = Todo(title: "buy milk")
        store.add(todo)
        XCTAssertEqual(store.todos, [todo])
    }

    func testRemoveDropsMatchingId() {
        let keep   = Todo(title: "keep")
        let drop   = Todo(title: "drop")
        var store = TodoStore(todos: [keep, drop])
        store.remove(id: drop.id)
        XCTAssertEqual(store.todos, [keep])
    }

    func testRemoveIsNoopForUnknownId() {
        let todo = Todo(title: "only")
        var store = TodoStore(todos: [todo])
        store.remove(id: UUID())
        XCTAssertEqual(store.todos, [todo])
    }

    func testToggleFlipsCompletionForMatchingId() {
        let todo = Todo(title: "x", isCompleted: false)
        var store = TodoStore(todos: [todo])
        store.toggle(id: todo.id)
        XCTAssertTrue(store.todos[0].isCompleted)
        store.toggle(id: todo.id)
        XCTAssertFalse(store.todos[0].isCompleted)
    }

    func testToggleIsNoopForUnknownId() {
        let todo = Todo(title: "x", isCompleted: false)
        var store = TodoStore(todos: [todo])
        store.toggle(id: UUID())
        XCTAssertFalse(store.todos[0].isCompleted)
    }

    func testRenameReplacesTitleForMatchingId() {
        let todo = Todo(title: "old")
        var store = TodoStore(todos: [todo])
        store.rename(id: todo.id, to: "new")
        XCTAssertEqual(store.todos[0].title, "new")
    }

    func testRenameIsNoopForUnknownId() {
        let todo = Todo(title: "old")
        var store = TodoStore(todos: [todo])
        store.rename(id: UUID(), to: "new")
        XCTAssertEqual(store.todos[0].title, "old")
    }

    func testFilteredAppliesFilter() {
        let active = Todo(title: "active", isCompleted: false)
        let done   = Todo(title: "done", isCompleted: true)
        let store = TodoStore(todos: [active, done])
        XCTAssertEqual(store.filtered(by: .all),       [active, done])
        XCTAssertEqual(store.filtered(by: .active),    [active])
        XCTAssertEqual(store.filtered(by: .completed), [done])
    }

    func testActiveAndCompletedCountsReflectState() {
        let store = TodoStore(todos: [
            Todo(title: "a", isCompleted: false),
            Todo(title: "b", isCompleted: true),
            Todo(title: "c", isCompleted: true)
        ])
        XCTAssertEqual(store.activeCount, 1)
        XCTAssertEqual(store.completedCount, 2)
    }

    func testClearCompletedRemovesOnlyDoneTodos() {
        let active = Todo(title: "a", isCompleted: false)
        let done   = Todo(title: "b", isCompleted: true)
        var store = TodoStore(todos: [active, done])
        store.clearCompleted()
        XCTAssertEqual(store.todos, [active])
    }
}
