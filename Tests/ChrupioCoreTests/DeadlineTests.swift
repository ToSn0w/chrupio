@testable import ChrupioCore
import XCTest

final class DeadlineTests: XCTestCase {
    func testDiarizationDeadlineIsTwiceTheAudioWithATwoMinuteFloor() {
        XCTAssertEqual(Deadline.diarization(audioSeconds: 0), 120)
        XCTAssertEqual(Deadline.diarization(audioSeconds: 59), 120)
        XCTAssertEqual(Deadline.diarization(audioSeconds: 60), 120)
        XCTAssertEqual(Deadline.diarization(audioSeconds: 3600), 7200)
    }

    func testReturnsTheResultInTime() async throws {
        let value = try await Deadline.run(seconds: 5) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testGivesUpOnAnOperationThatIgnoresCancellation() async {
        let start = Date()
        do {
            _ = try await Deadline.run(seconds: 0.2) { () -> Int in
                usleep(3_000_000) // not cancellable, like a stuck model load
                return 1
            }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? DeadlineExceeded, DeadlineExceeded(seconds: 0.2))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testPassesTheOperationsErrorThrough() async {
        struct Boom: Error {}
        do {
            _ = try await Deadline.run(seconds: 5) { () -> Int in throw Boom() }
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }
}
