import XCTest
@testable import ChrupioCore

final class AudioSafetyTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("as-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { 0.2 * sin(Float($0) * 0.1) }
    }

    func testEchoReferenceSkipsAWAVShorterThanItsSidecar() throws {
        let directory = try directory()
        let rate = 100
        let micURL = directory.appendingPathComponent("mic-1.wav")
        try WAVFile.write([Float](repeating: 0.1, count: 4 * rate), sampleRate: rate, to: micURL)
        let mic = AudioChunk(track: .mic, index: 1, url: micURL, startOffset: 10, duration: 4, rms: 0.1)
        // The sidecar claims 0-30 s, but a crash left only 1 s of audio, which ends before the mic chunk starts.
        let systemURL = directory.appendingPathComponent("system-1.wav")
        try WAVFile.write([Float](repeating: 0.3, count: rate), sampleRate: rate, to: systemURL)
        let system = AudioChunk(track: .system, index: 1, url: systemURL, startOffset: 0, duration: 30, rms: 0.3)
        XCTAssertNil(EchoReference.samples(for: mic, system: [system], sampleRate: rate))
    }

    func testChunkWAVIsWrittenBeforeItsSidecar() throws {
        let directory = try directory()
        let writer = ChunkWriter(track: .mic, directory: directory)
        // Block the WAV path, so writing the chunk fails at the WAV.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("mic-0001.wav"), withIntermediateDirectories: true)
        XCTAssertTrue(writer.append(tone(31)).isEmpty)
        XCTAssertNotNil(writer.writeError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("mic-0001.json").path),
                       "no sidecar points at audio that was never written")
    }
}

final class ChunkWriteFailureTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wf-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { 0.2 * sin(Float($0) * 0.1) }
    }

    func testFailedWriteKeepsTheSidecarOfSavedAudio() throws {
        let directory = try directory()
        let writer = ChunkWriter(track: .mic, directory: directory)
        _ = writer.append(tone(6))
        let sidecar = directory.appendingPathComponent("mic-0001.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path), "the chunk in progress is on disk")
        // The disk fails for the finished chunk.
        let wav = directory.appendingPathComponent("mic-0001.wav")
        try FileManager.default.removeItem(at: wav)
        try FileManager.default.createDirectory(at: wav, withIntermediateDirectories: true)
        XCTAssertTrue(writer.append(tone(30)).isEmpty)
        XCTAssertNotNil(writer.writeError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path), "a sidecar this write didn't create stays")
    }

    func testFailedFlushIsReported() throws {
        let directory = try directory()
        let writer = ChunkWriter(track: .system, directory: directory)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("system-0001.wav"), withIntermediateDirectories: true)
        _ = writer.append(tone(2))
        XCTAssertNil(writer.flush())
        XCTAssertNotNil(writer.writeError, "a nil flush with an error means audio was lost, not that there was none")
    }
}

final class TrackWatchTests: XCTestCase {
    func testLostTrackIsRebuiltWarnedAboutAndCleared() {
        let start = Date()
        var watch = TrackWatch()
        watch.started(.mic, at: start)
        watch.heard(.system, at: start)
        XCTAssertTrue(watch.dueForRestart(now: start.addingTimeInterval(4)).isEmpty, "the system track isn't watched until it starts")
        XCTAssertFalse(watch.isQuiet(.mic, now: start.addingTimeInterval(0.5)))
        XCTAssertTrue(watch.isQuiet(.mic, now: start.addingTimeInterval(2)), "the meter drops to 0 once audio stops")

        XCTAssertEqual(watch.dueForRestart(now: start.addingTimeInterval(6)), [.mic])
        XCTAssertTrue(watch.dueForRestart(now: start.addingTimeInterval(8)).isEmpty, "rebuilds are spaced out")
        XCTAssertEqual(watch.dueForRestart(now: start.addingTimeInterval(12)), [.mic])
        XCTAssertTrue(watch.lost(now: start.addingTimeInterval(14)).isEmpty)

        // A rebuild that brings back no sound doesn't count as recovery.
        watch.started(.mic, at: start.addingTimeInterval(13))
        XCTAssertEqual(watch.lost(now: start.addingTimeInterval(15)), [.mic])

        watch.heard(.mic, at: start.addingTimeInterval(20))
        XCTAssertTrue(watch.lost(now: start.addingTimeInterval(20.5)).isEmpty)
        XCTAssertFalse(watch.isQuiet(.mic, now: start.addingTimeInterval(20.5)))
    }

    func testSystemTrackWatchedOnceStarted() {
        let start = Date()
        var watch = TrackWatch()
        watch.started(.system, at: start)
        XCTAssertEqual(watch.dueForRestart(now: start.addingTimeInterval(6)), [.system])
        XCTAssertEqual(watch.lost(now: start.addingTimeInterval(15)), [.system])
    }
}

final class MeetingRecoveryTests: XCTestCase {
    func testShortFirstRecordingsAreDiscardedAfterACrash() {
        var meeting = Meeting(title: "Quick", platform: .meet)
        meeting.status = .recording
        meeting.endedAt = meeting.startedAt.addingTimeInterval(16)
        XCTAssertTrue(MeetingRecovery.discardsIfShort(meeting, minimum: 60))
        XCTAssertFalse(MeetingRecovery.discardsIfShort(meeting, minimum: 0), "Keep all keeps it")
        meeting.status = .transcribing
        XCTAssertTrue(MeetingRecovery.discardsIfShort(meeting, minimum: 60))

        meeting.endedAt = meeting.startedAt.addingTimeInterval(90)
        XCTAssertFalse(MeetingRecovery.discardsIfShort(meeting, minimum: 60))

        meeting.endedAt = meeting.startedAt.addingTimeInterval(16)
        meeting.summary = MeetingSummary(markdown: "## Summary\nDone.", model: "m")
        XCTAssertFalse(MeetingRecovery.discardsIfShort(meeting, minimum: 60), "an interrupted retranscribe of a finished meeting is kept")
        meeting.summary = nil
        meeting.status = .summarizing
        XCTAssertFalse(MeetingRecovery.discardsIfShort(meeting, minimum: 60))
    }
}
