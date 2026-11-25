import XCTest
@testable import ChrupioCore

final class DeferredSavesTests: XCTestCase {
    func testRetriesBackOffFiveTenThenThirtySeconds() {
        var saves = DeferredSaves()
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        saves.deferred(id, now: start)
        XCTAssertEqual(saves.due(now: start.addingTimeInterval(4.9)), [])
        XCTAssertEqual(saves.due(now: start.addingTimeInterval(5)), [id])
        var now = start.addingTimeInterval(5)
        var delays: [TimeInterval] = []
        for _ in 0..<4 {
            saves.deferred(id, now: now)
            let next = saves.nextTry(id)!
            delays.append(next.timeIntervalSince(now))
            now = next
        }
        XCTAssertEqual(delays, [10, 30, 30, 30])
        saves.saved(id)
        XCTAssertTrue(saves.isEmpty)
        saves.deferred(id, now: now)
        XCTAssertEqual(saves.nextTry(id)?.timeIntervalSince(now), 5, "a success starts the backoff over")
    }
}
