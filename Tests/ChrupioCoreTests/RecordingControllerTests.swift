import Foundation
@testable import ChrupioCore
import XCTest

final class FakeRecorder: AudioRecording, @unchecked Sendable {
    private let lock = NSLock()
    var micLevel: Float = 0
    var systemLevel: Float = 0
    var systemPeakLevel: Float = 0
    var systemCaptureError: String?
    var writeError: String?
    var startError: Error?
    var lost: Set<AudioChunk.Track> = []
    var lastChunks: [AudioChunk] = []
    /// While set, `stop` blocks until the test signals it: the recorder is still flushing.
    var stopGate: DispatchSemaphore?
    let onChunk: AudioRecorder.ChunkHandler
    private(set) var started = false

    init(onChunk: @escaping AudioRecorder.ChunkHandler) { self.onChunk = onChunk }

    func start(captureSystemAudio: Bool) throws {
        if let startError { throw startError }
        started = true
    }

    func stop() -> [AudioChunk] {
        stopGate?.wait()
        return lock.withLock { lastChunks }
    }

    func reviveStalledTracks(now: Date) {}
    func lostTracks(now: Date) -> Set<AudioChunk.Track> { lost }
}

@MainActor
final class FakeRecordingEnvironment: RecordingControllerEnvironment {
    var captureSystemAudio = true
    var problem: String?
    var startError: Error?
    private(set) var recorders: [FakeRecorder] = []
    private(set) var events: [String] = []
    private(set) var chunks: [AudioChunk] = []
    private(set) var lastChunks: [UUID: [AudioChunk]] = [:]
    /// Whether the meeting was already saved when the recorder was made and started.
    var savedBeforeStart: () -> Bool = { true }

    func makeRecorder(directory: URL, onChunk: @escaping AudioRecorder.ChunkHandler) -> AudioRecording {
        let recorder = FakeRecorder(onChunk: onChunk)
        recorder.startError = startError
        recorders.append(recorder)
        return recorder
    }
    func setupProblem() -> String? { problem }
    func prepare(_ meeting: inout Meeting, for candidate: MeetingCandidate) { meeting.attendees = ["Ann"] }
    func recordingStarted(_ meeting: Meeting, candidate: MeetingCandidate, manual: Bool) { events.append("started \(candidate.key)") }
    func recordingFailed(candidate: MeetingCandidate, manual: Bool) { events.append("failed") }
    func recordingStopped(_ meetingID: UUID, hadMeeting: Bool) { events.append("stopped \(hadMeeting)") }
    func chunkArrived(_ chunk: AudioChunk, for meetingID: UUID) { chunks.append(chunk) }
    func lastChunksArrived(_ chunks: [AudioChunk], for meetingID: UUID) {
        events.append("last chunks")
        lastChunks[meetingID] = chunks
    }
    func activityChanged() {}
}

final class FakeSleepHold: SleepHolding, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [ObjectIdentifier: String] = [:]
    var count: Int { lock.withLock { held.count } }
    func hold(reason: String) -> NSObjectProtocol {
        let token = NSObject()
        lock.withLock { held[ObjectIdentifier(token)] = reason }
        return token
    }
    func release(_ token: NSObjectProtocol) { _ = lock.withLock { held.removeValue(forKey: ObjectIdentifier(token as AnyObject)) } }
}

@MainActor
final class RecordingControllerTests: XCTestCase {
    private var saver: FakeSaver!
    private var library: MeetingLibrary!
    private var environment: FakeRecordingEnvironment!
    private var notifier: FakeNotifier!
    private var sleep: FakeSleepHold!
    private var controller: RecordingController!

    override func setUp() async throws {
        saver = FakeSaver()
        library = MeetingLibrary(saver: saver)
        environment = FakeRecordingEnvironment()
        notifier = FakeNotifier()
        sleep = FakeSleepHold()
        controller = RecordingController(library: library, sleepHold: sleep, limits: RecordingLimits(silence: 60, maximum: 3_600))
        controller.environment = environment
        controller.notifier = notifier
    }

    private let meet = MeetingCandidate(key: "chrome-tab:1", platform: .meet, title: "Standup")

    private func chunk(_ index: Int, track: AudioChunk.Track = .mic) -> AudioChunk {
        AudioChunk(track: track, index: index, url: URL(fileURLWithPath: "/nonexistent/\(track)-\(index).wav"), startOffset: Double(index) * 30, duration: 30, rms: 0.1)
    }

    func testStartSavesTheMeetingFirstThenRecords() async throws {
        let id = try XCTUnwrap(controller.start(meet, manual: false))
        XCTAssertEqual(saver.saved.first?.id, id, "saved before audio")
        XCTAssertEqual(saver.saved.first?.attendees, ["Ann"])
        XCTAssertTrue(environment.recorders[0].started)
        XCTAssertEqual(controller.recording?.candidateKey, "chrome-tab:1")
        XCTAssertEqual(library.phases[id], .recording)
        XCTAssertEqual(environment.events, ["started chrome-tab:1"])
        XCTAssertEqual(notifier.titles, ["Taking notes"])
        XCTAssertNil(controller.start(meet, manual: true), "one recording at a time")
    }

    func testRecorderThatCantStartLeavesAFailedMeeting() async {
        environment.startError = CocoaError(.featureUnsupported)
        XCTAssertNil(controller.start(meet, manual: true))
        XCTAssertNil(controller.recording)
        XCTAssertEqual(library.meetings.first?.status, .failed)
        XCTAssertTrue(library.lastError?.hasPrefix("Couldn't start recording") == true)
        XCTAssertEqual(environment.events, ["failed"])
    }

    func testManualRecordingHasNoCandidateKey() async {
        controller.start(MeetingCandidate(key: "manual", platform: .other, title: nil), manual: true)
        XCTAssertNil(controller.recording?.candidateKey)
        XCTAssertNil(controller.recording?.sourceKey)
    }

    func testChunksAreCountedUntilTheyArrive() async throws {
        let id = try XCTUnwrap(controller.start(meet, manual: false))
        environment.recorders[0].onChunk(chunk(0))
        XCTAssertFalse(controller.deliveries.isEmpty(id), "in flight to the main actor")
        let arrived = await until { self.environment.chunks.count == 1 }
        XCTAssertTrue(arrived)
        XCTAssertTrue(controller.deliveries.isEmpty(id))
    }

    /// Stopping hands the recording over to transcription while the recorder is still flushing: the meeting is
    /// ended at once, counted as having a delivery outstanding (so it can't finish), and the sleep hold lasts
    /// until the final chunks are handed over.
    func testStopDuringHandoverWaitsForTheLastChunks() async throws {
        let id = try XCTUnwrap(controller.start(meet, manual: false))
        let recorder = environment.recorders[0]
        let gate = DispatchSemaphore(value: 0)
        recorder.stopGate = gate
        recorder.lastChunks = [chunk(7), chunk(7, track: .system)]
        controller.stop(holdingOffSleep: true)
        XCTAssertNil(controller.recording)
        XCTAssertEqual(library.meeting(id)?.status, .transcribing)
        XCTAssertNotNil(library.meeting(id)?.endedAt)
        XCTAssertEqual(library.phases[id], .stopping)
        XCTAssertFalse(controller.deliveries.isEmpty(id))
        XCTAssertEqual(sleep.count, 1)
        XCTAssertEqual(environment.events.last, "stopped true")
        XCTAssertNotNil(controller.stopTasks[id])
        // A new call may start while the old recorder flushes.
        XCTAssertNotNil(controller.start(MeetingCandidate(key: "zoom", platform: .zoom, title: nil), manual: false))
        gate.signal()
        let handed = await until { self.environment.lastChunks[id] != nil }
        XCTAssertTrue(handed)
        XCTAssertEqual(environment.lastChunks[id]?.count, 2)
        XCTAssertEqual(library.phases[id], .transcribing(discardIfShort: true))
        XCTAssertTrue(controller.deliveries.isEmpty(id))
        XCTAssertNil(controller.stopTasks[id])
        XCTAssertEqual(sleep.count, 0)
    }

    func testFinalWriteFailureIsShownOnTheMeeting() async throws {
        let id = try XCTUnwrap(controller.start(meet, manual: false))
        environment.recorders[0].writeError = "disk full"
        await controller.stopAndWait()
        XCTAssertEqual(library.meeting(id)?.error, RecordingSession.finalWriteMessage("disk full"))
        XCTAssertTrue(notifier.titles.contains("Recording incomplete"))
    }

    func testLostTrackWarnsThenNotesTheGapWhenItReturns() async throws {
        let id = try XCTUnwrap(controller.start(meet, manual: false))
        let recorder = environment.recorders[0]
        recorder.micLevel = 0.5
        recorder.lost = [.mic]
        XCTAssertFalse(controller.tick(now: Date()))
        XCTAssertEqual(library.meeting(id)?.error, RecordingController.lostTrackMessage(.mic))
        XCTAssertEqual(notifier.posted.last?.identifier, RecordingController.lostTrackNotification(.mic, id))
        recorder.lost = []
        _ = controller.tick(now: Date())
        XCTAssertEqual(notifier.removed, [RecordingController.lostTrackNotification(.mic, id)])
        XCTAssertTrue(library.meeting(id)?.error?.hasPrefix("Your microphone was lost") == true)
    }

    func testSilentDetectedRecordingIsStoppedButManualOneIsNot() async throws {
        let id = try XCTUnwrap(controller.start(meet, manual: false))
        environment.recorders[0].systemPeakLevel = 0.3
        XCTAssertFalse(controller.tick(now: Date().addingTimeInterval(30)))
        XCTAssertTrue(controller.tick(now: Date().addingTimeInterval(120)))
        XCTAssertNil(controller.recording)
        XCTAssertEqual(library.phases[id], .stopping)
        XCTAssertTrue(notifier.titles.contains("Recording stopped"))
        await controller.stopAndWait()

        controller.start(MeetingCandidate(key: "manual", platform: .other, title: nil), manual: true)
        environment.recorders[1].systemPeakLevel = 0.3
        XCTAssertFalse(controller.tick(now: Date().addingTimeInterval(120)), "manual recordings stop only manually")
        XCTAssertTrue(controller.tick(now: Date().addingTimeInterval(3_700)), "but never run past the maximum")
    }

    func testSilentCallAudioIsWarnedAboutOnce() async throws {
        let id = try XCTUnwrap(controller.start(meet, manual: false))
        environment.recorders[0].micLevel = 0.5
        _ = controller.tick(now: Date().addingTimeInterval(100))
        _ = controller.tick(now: Date().addingTimeInterval(102))
        XCTAssertEqual(notifier.titles.filter { $0 == "Can't hear the other participants" }.count, 1)
        XCTAssertTrue(library.meeting(id)?.error?.hasPrefix("No sound from the other participants") == true)
    }
}
