import Foundation
@testable import ChrupioCore
import XCTest

private final class DiarizerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private(set) var maxRunning = 0
    private(set) var started: [String] = []

    func begin(_ chunks: [AudioChunk]) {
        lock.withLock {
            running += 1
            maxRunning = max(maxRunning, running)
            started.append(chunks.first?.url.lastPathComponent ?? "-")
        }
    }

    func end() { lock.withLock { running -= 1 } }
}

@MainActor
final class DiarizationSchedulerTests: XCTestCase {
    private func system(_ name: String) -> [AudioChunk] {
        [AudioChunk(track: .system, index: 0, url: URL(fileURLWithPath: "/nonexistent/\(name).wav"), startOffset: 0, duration: 30, rms: 0.1)]
    }

    private func meetings(_ count: Int) -> [UUID: Meeting] {
        Dictionary(uniqueKeysWithValues: (0..<count).map { _ in
            let meeting = Meeting(title: "Call", platform: .meet, url: nil)
            return (meeting.id, meeting)
        })
    }

    func testAStalledDiarizerRunsOutOfTimeAndTheMeetingFallsBack() async {
        let scheduler = DiarizationScheduler { _ in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return Diarization(turns: [], centroids: [:])
        }
        let stored = meetings(1)
        let id = stored.keys.first!
        scheduler.meeting = { stored[$0] }
        scheduler.deadline = { _ in 0.1 }
        let done = expectation(description: "finished")
        scheduler.onFinished = { meetingID, segments, voices, failures in
            XCTAssertEqual(meetingID, id)
            XCTAssertNil(segments, "a late run reports no lines")
            XCTAssertNil(voices)
            XCTAssertEqual(failures, 2)
            done.fulfill()
        }
        let start = Date()
        scheduler.enqueue(id, system: system("a"), failures: 2)
        await fulfillment(of: [done], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertFalse(scheduler.queue.isRunning)
    }

    func testRunsOneAtATimeInOrderWithTheNamingsLines() async {
        let log = DiarizerLog()
        let scheduler = DiarizationScheduler { chunks in
            log.begin(chunks)
            defer { log.end() }
            try await Task.sleep(nanoseconds: 20_000_000)
            return Diarization(turns: [DiarizedTurn(start: 0, end: 1, cluster: "S1")], centroids: ["S1": [1, 0]])
        }
        let stored = meetings(3)
        let ids = Array(stored.keys)
        scheduler.meeting = { stored[$0] }
        scheduler.makeNaming = { { _, meeting, voices in
            voices = ["Ann": [1, 0]]
            return [TranscriptSegment(start: 0, end: 1, speaker: .remote("Ann"), text: meeting.id.uuidString)]
        } }
        var finished: [UUID] = []
        let done = expectation(description: "all")
        done.expectedFulfillmentCount = 3
        scheduler.onFinished = { id, segments, voices, _ in
            XCTAssertEqual(segments?.first?.text, id.uuidString)
            XCTAssertEqual(voices, ["Ann": [1, 0]])
            finished.append(id)
            done.fulfill()
        }
        for (index, id) in ids.enumerated() { scheduler.enqueue(id, system: system("m\(index)"), failures: 0) }
        XCTAssertEqual(scheduler.queue.pending, Array(ids.dropFirst()))
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(finished, ids)
        XCTAssertEqual(log.started, ["m0.wav", "m1.wav", "m2.wav"])
        XCTAssertEqual(log.maxRunning, 1)
    }

    func testVoicesSurviveANamingThatThrowsAfterLearningThem() async {
        let scheduler = DiarizationScheduler { _ in Diarization(turns: [], centroids: [:]) }
        let stored = meetings(1)
        let id = stored.keys.first!
        scheduler.meeting = { stored[$0] }
        scheduler.makeNaming = { { _, _, voices in
            voices = ["Bob": [0, 1]]
            throw CocoaError(.fileWriteOutOfSpace)
        } }
        let done = expectation(description: "finished")
        scheduler.onFinished = { _, segments, voices, _ in
            XCTAssertNil(segments)
            XCTAssertEqual(voices, ["Bob": [0, 1]])
            done.fulfill()
        }
        scheduler.enqueue(id, system: system("a"), failures: 0)
        await fulfillment(of: [done], timeout: 5)
    }

    func testAMeetingGoneBeforeItsTurnIsDroppedAndTheNextRuns() async {
        let scheduler = DiarizationScheduler { _ in Diarization(turns: [], centroids: [:]) }
        let stored = meetings(1)
        let kept = stored.keys.first!
        let gone = UUID()
        scheduler.meeting = { stored[$0] }
        var dropped: [UUID] = []
        scheduler.onDropped = { dropped.append($0) }
        let done = expectation(description: "kept finished")
        scheduler.onFinished = { id, _, _, _ in
            XCTAssertEqual(id, kept)
            done.fulfill()
        }
        scheduler.enqueue(gone, system: system("gone"), failures: 0)
        scheduler.enqueue(kept, system: system("kept"), failures: 0)
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(dropped, [gone])
    }
}
