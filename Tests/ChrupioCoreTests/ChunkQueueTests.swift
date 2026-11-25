import XCTest
@testable import ChrupioCore

final class ChunkQueueTests: XCTestCase {
    func chunk(_ index: Int, _ track: AudioChunk.Track = .mic) -> AudioChunk {
        AudioChunk(track: track, index: index, url: URL(fileURLWithPath: "/tmp/\(track.rawValue)-\(index).wav"),
                   startOffset: Double(index) * 30, duration: 30, rms: 0.1)
    }

    func testMeetingFinishesOnlyAfterItsLastChunkAndDelivery() {
        var queue = ChunkQueue()
        let a = UUID(), b = UUID()
        queue.enqueue(chunk(1), for: a)
        queue.enqueue(chunk(2), for: b)
        queue.enqueue(chunk(3), for: a, first: true)
        XCTAssertEqual(queue.jobs.map(\.index), [3, 1, 2])
        XCTAssertEqual(queue.pending, [a: 2, b: 1])

        queue.startFinishing(a)
        XCTAssertFalse(queue.isReady(a, recording: false, deliveriesDone: true), "chunks pending")
        let first = queue.next()!
        XCTAssertEqual(queue.meeting(of: first), a)
        XCTAssertEqual(queue.pending[a], 2, "pending until completed")
        queue.completed(first)
        queue.completed(queue.next()!, failed: true)
        XCTAssertNil(queue.pending[a])
        XCTAssertFalse(queue.isReady(a, recording: true, deliveriesDone: true), "a call is on")
        XCTAssertFalse(queue.isReady(a, recording: false, deliveriesDone: false), "the recorder still holds a chunk")
        XCTAssertFalse(queue.isReady(b, recording: false, deliveriesDone: true), "b hasn't ended")
        XCTAssertTrue(queue.isReady(a, recording: false, deliveriesDone: true))
        XCTAssertEqual(queue.finish(a), 1)
        XCTAssertFalse(queue.finishing.contains(a))
        XCTAssertNil(queue.completed(chunk(9)), "unknown chunk")
        XCTAssertEqual(queue.pending, [b: 1])
    }

    struct StartFailure: LocalizedError { var errorDescription: String? { "no input device" } }

    func testStartSavesBeforeTheRecorderAndAgainOnFailure() {
        let meeting = Meeting(title: "Call", platform: .meet)
        var events: [String] = []
        let started = RecordingSession.start(meeting, save: { events.append("save \($0.status)") },
                                             startRecorder: { events.append("recorder") })
        XCTAssertEqual(events, ["save \(meeting.status)", "recorder"])
        guard case .recording = started else { return XCTFail() }

        events = []
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let failed = RecordingSession.start(meeting, save: { events.append("save \($0.status)") },
                                            startRecorder: { events.append("recorder"); throw StartFailure() }, now: { end })
        XCTAssertEqual(events, ["save \(meeting.status)", "recorder", "save failed"])
        guard case .failed(let saved, let message) = failed else { return XCTFail() }
        XCTAssertEqual(saved.endedAt, end)
        XCTAssertEqual(message, "Couldn't start recording: no input device")
        XCTAssertEqual(saved.error, message)
    }

    func testStoppedClosesTheOpenRun() {
        var meeting = Meeting(title: "Call", platform: .meet)
        let end = Date()
        RecordingSession.stopped(&meeting, openRun: SpeakerEvent(time: 10, names: ["Anna"], end: 20), at: end)
        XCTAssertEqual(meeting.speakerEvents.count, 1)
        XCTAssertEqual(meeting.endedAt, end)
        XCTAssertEqual(meeting.status, .transcribing)
    }
}
