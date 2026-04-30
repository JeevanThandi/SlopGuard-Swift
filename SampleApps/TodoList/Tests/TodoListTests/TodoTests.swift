import XCTest
@testable import TodoList

final class TodoTests: XCTestCase {

    func testInitWithDefaultsSetsIncompleteAndUniqueId() {
        let a = Todo(title: "buy milk")
        let b = Todo(title: "buy milk")
        XCTAssertEqual(a.title, "buy milk")
        XCTAssertFalse(a.isCompleted)
        XCTAssertNotEqual(a.id, b.id)
    }

    func testInitWithExplicitValuesPreservesAllFields() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 0)
        let todo = Todo(id: id, title: "ship it", isCompleted: true, createdAt: date)
        XCTAssertEqual(todo.id, id)
        XCTAssertEqual(todo.title, "ship it")
        XCTAssertTrue(todo.isCompleted)
        XCTAssertEqual(todo.createdAt, date)
    }

    func testEquatableMatchesOnAllFields() {
        let id = UUID()
        let date = Date()
        let lhs = Todo(id: id, title: "x", isCompleted: false, createdAt: date)
        let rhs = Todo(id: id, title: "x", isCompleted: false, createdAt: date)
        XCTAssertEqual(lhs, rhs)
    }

    func testEquatableDifferentiatesOnTitle() {
        let id = UUID()
        let date = Date()
        let lhs = Todo(id: id, title: "x", isCompleted: false, createdAt: date)
        let rhs = Todo(id: id, title: "y", isCompleted: false, createdAt: date)
        XCTAssertNotEqual(lhs, rhs)
    }
}
