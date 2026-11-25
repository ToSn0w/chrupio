import Foundation
@testable import ChrupioCore
import XCTest

/// Never called: these tests feed chunk results straight in.
private struct UnusedEngines: SpeechEngines {
    func whisper(_ wav: URL, transcriber: Transcriber) async throws -> Transcription { throw CocoaError(.featureUnsupported) }
    func parakeet(_ wav: URL, language: String?, chunk: AudioChunk, vocabulary: [String], aliases: [String: [String]]) async throws -> Transcription {
        throw CocoaError(.featureUnsupported)
    }
    func removeEcho(_ chunk: AudioChunk) async -> URL? { nil }
}

@MainActor
final class FakeFinisherEnvironment: TranscriptFinisherEnvironment {
    var keepAudio = true
    var autoSummarize = true
    var minimumMeetingSeconds: TimeInterval = 60
    var preferredLanguage: String?
    var recordingMeetingID: UUID?
    var undelivered: Set<UUID> = []
    var chunks: [UUID: [AudioChunk]] = [:]
    private(set) var events: [String] = []
    private(set) var discarded: [UUID] = []
    private(set) var summarized: [UUID] = []

    func deliveriesDone(_ id: UUID) -> Bool { !undelivered.contains(id) }
    func savedChunks(_ id: UUID) -> [AudioChunk] { chunks[id] ?? [] }
    func pinEngines(_ id: UUID) { events.append("pin") }
    func applyContext(_ meeting: inout Meeting) {}
    func attributeVoices(_ meeting: inout Meeting) { events.append("voices") }
    func releaseEngines() { events.append("release") }
    func discard(_ meeting: Meeting) { discarded.append(meeting.id) }
    func summarizeTranscribed(_ id: UUID) { summarized.append(id) }
    func activityChanged() {}
}

@MainActor
final class TranscriptFinisherTests: XCTestCase {
    private var library: MeetingLibrary!
    private var environment: FakeFinisherEnvironment!
    private var notifier: FakeNotifier!
    private var finisher: TranscriptFinisher!

    override func setUp() async throws {
        library = MeetingLibrary(saver: FakeSaver())
        environment = FakeFinisherEnvironment()
        notifier = FakeNotifier()
        let transcription = TranscriptionScheduler(engines: UnusedEngines(), makeTranscriber: { Transcriber(model: WhisperModel.all[1]) })
        transcription.mayStart = { false }
        finisher = TranscriptFinisher(library: library, transcription: transcription,
                                      diarization: DiarizationScheduler { _ in Diarization(turns: [], centroids: [:]) })
        finisher.environment = environment
        finisher.notifier = notifier
    }

    private func meeting(seconds: TimeInterval) -> Meeting {
        let start = Date().addingTimeInterval(-3_600)
        let meeting = Meeting(title: "Call", platform: .meet, startedAt: start, endedAt: start.addingTimeInterval(seconds), status: .transcribing)
        library.add([meeting])
        return meeting
    }

    private func chunk(_ index: Int, track: AudioChunk.Track = .mic) -> AudioChunk {
        AudioChunk(track: track, index: index, url: URL(fileURLWithPath: "/nonexistent/\(track)-\(index).wav"), startOffset: Double(index) * 30, duration: 30, rms: 0.1)
    }

    private func stopped(_ id: UUID) {
        finisher.transcription.startFinishing(id)
        library.phases.send(.recordingStarted, to: id)
        library.phases.send(.stopRequested, to: id)
        library.phases.send(.lastChunksQueued, to: id)
    }

    func testShortRecordingIsDiscardedOnceTranscribed() {
        let short = meeting(seconds: 20)
        stopped(short.id)
        XCTAssertEqual(library.phases[short.id], .transcribing(discardIfShort: true))
        finisher.finishIfReady(short.id)
        XCTAssertEqual(environment.discarded, [short.id])
        XCTAssertEqual(notifier.titles, ["Recording discarded"])
        XCTAssertTrue(environment.summarized.isEmpty)
    }

    func testNotReadyWhileRecordingOrChunksAreStillArriving() {
        let call = meeting(seconds: 600)
        stopped(call.id)
        environment.undelivered = [call.id]
        finisher.finishIfReady(call.id)
        XCTAssertEqual(library.meeting(call.id)?.status, .transcribing)
        environment.undelivered = []
        environment.recordingMeetingID = UUID()
        finisher.finishIfReady(call.id)
        XCTAssertEqual(library.meeting(call.id)?.status, .transcribing)
        environment.recordingMeetingID = nil
        finisher.finishIfReady(call.id)
        XCTAssertEqual(library.meeting(call.id)?.status, .done)
    }

    func testLongMeetingWithSpeechCompletesAndIsSummarized() {
        let call = meeting(seconds: 600)
        library.update(call.id) { $0.segments = [TranscriptSegment(start: 0, end: 5, speaker: .me, text: "Hello")] }
        stopped(call.id)
        finisher.finishIfReady(call.id)
        XCTAssertEqual(library.meeting(call.id)?.status, .done)
        XCTAssertEqual(environment.summarized, [call.id])
        XCTAssertEqual(environment.events, ["release", "voices"])
        XCTAssertNil(library.phases[call.id])
    }

    func testMeetingWithoutSpeechNotifiesInsteadOfSummarizing() {
        let call = meeting(seconds: 600)
        stopped(call.id)
        finisher.finishIfReady(call.id)
        XCTAssertEqual(notifier.titles, ["No speech captured"])
        XCTAssertTrue(environment.summarized.isEmpty)
    }

    func testChunkStatisticsAreRecordedPerEngine() throws {
        let call = meeting(seconds: 600)
        finisher.transcription.startFinishing(call.id)
        let empty = TranscriptionPipeline.ChunkResult(segments: [], language: nil, speechCount: 0)
        finisher.finishChunk(chunk(0), meetingID: call.id, result: .success(empty), engine: .whisper, seconds: 6)
        finisher.finishChunk(chunk(1), meetingID: call.id, result: .success(empty), engine: .parakeet, seconds: 3)
        let stats = try XCTUnwrap(library.meeting(call.id)?.transcriptionStats)
        XCTAssertEqual(stats.whisperChunks, 1)
        XCTAssertEqual(stats.parakeetChunks, 1)
        XCTAssertEqual(stats.audioSeconds, 60)
        XCTAssertEqual(stats.computeSeconds, 9)
    }

    func testRetranscribeResetsTheStatistics() throws {
        let call = meeting(seconds: 600)
        let empty = TranscriptionPipeline.ChunkResult(segments: [], language: nil, speechCount: 0)
        finisher.transcription.startFinishing(call.id)
        finisher.finishChunk(chunk(0), meetingID: call.id, result: .success(empty), engine: .whisper, seconds: 6)
        XCTAssertEqual(library.meeting(call.id)?.transcriptionStats?.whisperChunks, 1)
        library.update(call.id) { $0.status = .done; $0.error = "Claude Code took too long to write the summary."; $0.summaryError = $0.error }
        environment.chunks[call.id] = [chunk(0)]
        finisher.retranscribe(call.id)
        XCTAssertNil(library.meeting(call.id)?.transcriptionStats)
        XCTAssertNil(library.meeting(call.id)?.error)
        XCTAssertNil(library.meeting(call.id)?.summaryError)
        finisher.finishChunk(chunk(0), meetingID: call.id, result: .success(empty), engine: .parakeet, seconds: 2)
        let stats = try XCTUnwrap(library.meeting(call.id)?.transcriptionStats)
        XCTAssertEqual(stats.whisperChunks, 0)
        XCTAssertEqual(stats.parakeetChunks, 1)
        XCTAssertEqual(stats.computeSeconds, 2)
    }

    func testFailedChunkOfARetranscribeKeepsTheLinesItCovered() throws {
        let call = meeting(seconds: 600)
        let old = TranscriptSegment(start: 2, end: 6, speaker: .me, text: "Old line")
        library.update(call.id) { $0.segments = [old]; $0.status = .done }
        environment.chunks[call.id] = [chunk(0)]
        finisher.retranscribe(call.id)
        XCTAssertTrue(library.meeting(call.id)?.segments.isEmpty == true, "replaced while redone")
        finisher.finishChunk(chunk(0), meetingID: call.id, result: .failure(TranscriberError.failed("whisper broke")))
        let stored = try XCTUnwrap(library.meeting(call.id))
        XCTAssertEqual(stored.segments.map(\.text), ["Old line"])
        XCTAssertTrue(stored.error?.hasPrefix("Part of the audio couldn't be transcribed") == true)
    }
}
