@testable import ChrupioCore
import XCTest

final class TranscriptionStatsTests: XCTestCase {
    func testCountsChunksSecondsAndFailuresPerEngine() {
        var stats = TranscriptionStats()
        stats.record(engine: .whisper, audioSeconds: 30, computeSeconds: 6, failed: false)
        stats.record(engine: .parakeet, audioSeconds: 30, computeSeconds: 3, failed: false)
        stats.record(engine: .whisper, audioSeconds: 20, computeSeconds: 40, failed: true)
        XCTAssertEqual(stats.whisperChunks, 1)
        XCTAssertEqual(stats.parakeetChunks, 1)
        XCTAssertEqual(stats.failedChunks, 1)
        XCTAssertEqual(stats.audioSeconds, 80)
        XCTAssertEqual(stats.computeSeconds, 49)
        XCTAssertEqual(stats.realTimeFactor, 49.0 / 80.0, accuracy: 0.0001)
    }

    func testOlderMeetingFilesDecodeWithoutStats() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","title":"t","platform":"other","startedAt":0,"attendees":[],"segments":[],"speakerEvents":[],"status":"done"}"#
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(json.utf8))
        XCTAssertNil(meeting.transcriptionStats)
    }
}
