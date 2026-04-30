import XCTest
@testable import TodoList

final class TodoFilterTests: XCTestCase {

    private let active = Todo(title: "active", isCompleted: false)
    private let done   = Todo(title: "done", isCompleted: true)

    func testAllMatchesEverything() {
        XCTAssertTrue(TodoFilter.all.matches(active))
        XCTAssertTrue(TodoFilter.all.matches(done))
    }

    func testActiveMatchesOnlyIncomplete() {
        XCTAssertTrue(TodoFilter.active.matches(active))
        XCTAssertFalse(TodoFilter.active.matches(done))
    }

    func testCompletedMatchesOnlyDone() {
        XCTAssertFalse(TodoFilter.completed.matches(active))
        XCTAssertTrue(TodoFilter.completed.matches(done))
    }

    func testCaseIterableExposesAllThreeCases() {
        XCTAssertEqual(TodoFilter.allCases, [.all, .active, .completed])
    }
}
