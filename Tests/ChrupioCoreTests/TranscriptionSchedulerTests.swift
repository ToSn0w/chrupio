import Foundation
@testable import ChrupioCore
import XCTest

/// Whisper hears every chunk in `whisperLanguage`; Parakeet fails while `parakeetFails`. Records the calls.
private final class FakeEngines: SpeechEngines, @unchecked Sendable {
    private let lock = NSLock()
    var whisperLanguage: String? = "en"
    var whisperFails = false
    var parakeetFails = false
    private(set) var calls: [String] = []
    private var running = 0
    private(set) var maxRunning = 0

    private func record(_ call: String) { lock.withLock { calls.append(call) } }

    func whisper(_ wav: URL, transcriber: Transcriber) async throws -> Transcription {
        lock.withLock { running += 1; maxRunning = max(maxRunning, running) }
        defer { lock.withLock { running -= 1 } }
        try await Task.sleep(nanoseconds: 5_000_000)
        record("whisper \(wav.lastPathComponent)")
        if whisperFails { throw TranscriberError.failed("whisper broke") }
        return Transcription(speech: [RecognizedSpeech(start: 0, end: 1, text: "w \(wav.lastPathComponent)")], language: whisperLanguage)
    }

    func parakeet(_ wav: URL, language: String?, chunk: AudioChunk, vocabulary: [String], aliases: [String: [String]]) async throws -> Transcription {
        record("parakeet \(wav.lastPathComponent) \(language ?? "-")")
        if parakeetFails { throw TranscriberError.failed("no models") }
        return Transcription(speech: [RecognizedSpeech(start: 0, end: 1, text: "p \(wav.lastPathComponent)")], language: language)
    }

    func removeEcho(_ chunk: AudioChunk) async -> URL? { nil }
}

final class TranscriptionSchedulerTests: XCTestCase {
    private let transcriber = Transcriber(model: WhisperModel.all[1])

    private func chunk(_ name: String, track: AudioChunk.Track = .mic) -> AudioChunk {
        AudioChunk(track: track, index: 0, url: URL(fileURLWithPath: "/nonexistent/\(name).wav"), startOffset: 0, duration: 30, rms: 0.1)
    }

    private func job(parakeet: Bool, language: String? = nil) -> TranscriptionJob {
        TranscriptionJob(transcriber: transcriber, routing: EngineRouting(parakeetEnabled: parakeet, language: language))
    }

    // MARK: Engine fallback

    func testAPinnedPolishJobRunsParakeetOnceAndNeverWhisper() async throws {
        let engines = FakeEngines()
        engines.whisperLanguage = "pl"
        let pinned = TranscriptionJob(transcriber: transcriber, routing: EngineRouting(parakeetEnabled: true).pinned(toConfirmed: "pl"))
        let (result, engine) = await TranscriptionScheduler.transcribe(chunk("a").url, chunk: chunk("a"), job: pinned, engines: engines)
        XCTAssertEqual(engine, .parakeet)
        XCTAssertEqual(try result.get().speech.first?.text, "p a.wav")
        XCTAssertEqual(engines.calls, ["parakeet a.wav pl"])
    }

    func testAChunkWhoseParakeetPassFailedIsNotSentToParakeetAgain() async throws {
        let engines = FakeEngines()
        engines.whisperLanguage = "pl"
        engines.parakeetFails = true
        let pinned = TranscriptionJob(transcriber: transcriber, routing: EngineRouting(parakeetEnabled: true).pinned(toConfirmed: "pl"))
        let (result, engine) = await TranscriptionScheduler.transcribe(chunk("a").url, chunk: chunk("a"), job: pinned, engines: engines)
        XCTAssertEqual(engine, .whisper)
        XCTAssertEqual(try result.get().speech.first?.text, "w a.wav")
        XCTAssertEqual(engines.calls, ["parakeet a.wav pl", "whisper a.wav"])
    }

    func testAPinnedPolishJobFallsBackToWhisperWhenParakeetFails() async throws {
        let engines = FakeEngines()
        engines.parakeetFails = true
        let pinned = TranscriptionJob(transcriber: transcriber, routing: EngineRouting(parakeetEnabled: true).pinned(toConfirmed: "pl"))
        let (result, engine) = await TranscriptionScheduler.transcribe(chunk("a").url, chunk: chunk("a"), job: pinned, engines: engines)
        XCTAssertEqual(engine, .whisper)
        XCTAssertEqual(try result.get().speech.first?.text, "w a.wav")
        XCTAssertEqual(engines.calls, ["parakeet a.wav pl", "whisper a.wav"])
    }

    func testWhisperOnlyWhenParakeetIsOff() async throws {
        let engines = FakeEngines()
        engines.whisperLanguage = "pl"
        let (result, engine) = await TranscriptionScheduler.transcribe(chunk("a").url, chunk: chunk("a"), job: job(parakeet: false), engines: engines)
        XCTAssertEqual(engine, .whisper)
        XCTAssertEqual(try result.get().speech.first?.text, "w a.wav")
        XCTAssertEqual(engines.calls, ["whisper a.wav"])
    }

    func testAChunkWhisperHearsAsPolishIsRedoneOnParakeet() async throws {
        let engines = FakeEngines()
        engines.whisperLanguage = "pl"
        let (result, engine) = await TranscriptionScheduler.transcribe(chunk("a").url, chunk: chunk("a"), job: job(parakeet: true), engines: engines)
        XCTAssertEqual(engine, .parakeet)
        XCTAssertEqual(try result.get().speech.first?.text, "p a.wav")
        XCTAssertEqual(engines.calls, ["whisper a.wav", "parakeet a.wav pl"])
    }

    func testAFailedParakeetRedoKeepsWhispersText() async throws {
        let engines = FakeEngines()
        engines.whisperLanguage = "pl"
        engines.parakeetFails = true
        let (result, engine) = await TranscriptionScheduler.transcribe(chunk("a").url, chunk: chunk("a"), job: job(parakeet: true), engines: engines)
        XCTAssertEqual(engine, .whisper)
        XCTAssertEqual(try result.get().speech.first?.text, "w a.wav")
    }

    func testPinnedPolishGoesToParakeetFirstAndFallsBackToWhisper() async throws {
        let engines = FakeEngines()
        let (first, firstEngine) = await TranscriptionScheduler.transcribe(chunk("a").url, chunk: chunk("a"), job: job(parakeet: true, language: "pl"), engines: engines)
        XCTAssertEqual(firstEngine, .parakeet)
        XCTAssertEqual(try first.get().language, "pl")
        XCTAssertEqual(engines.calls, ["parakeet a.wav pl"])

        engines.parakeetFails = true
        engines.whisperLanguage = "en"
        let (second, secondEngine) = await TranscriptionScheduler.transcribe(chunk("b").url, chunk: chunk("b"), job: job(parakeet: true, language: "pl"), engines: engines)
        XCTAssertEqual(secondEngine, .whisper)
        XCTAssertEqual(try second.get().speech.first?.text, "w b.wav")
    }

    func testWhisperFailureIsTheResult() async {
        let engines = FakeEngines()
        engines.whisperFails = true
        let (result, engine) = await TranscriptionScheduler.transcribe(chunk("a").url, chunk: chunk("a"), job: job(parakeet: false), engines: engines)
        XCTAssertEqual(engine, .whisper)
        guard case .failure = result else { return XCTFail("expected a failure") }
    }

    // MARK: Queue

    @MainActor
    func testChunksRunOneAtATimeInQueueOrderAndWaitWhileHeld() async {
        let engines = FakeEngines()
        let scheduler = TranscriptionScheduler(engines: engines, makeTranscriber: { Transcriber(model: WhisperModel.all[1]) })
        var held = true
        scheduler.mayStart = { !held }
        let meetingA = UUID(), meetingB = UUID()
        var finished: [(String, UUID?)] = []
        let done = expectation(description: "all chunks")
        done.expectedFulfillmentCount = 4
        scheduler.onFinished = { chunk, meetingID, result, _, _ in
            XCTAssertNotNil(try? result.get())
            finished.append((chunk.url.lastPathComponent, meetingID))
            done.fulfill()
        }
        scheduler.enqueue(chunk("a1"), for: meetingA)
        scheduler.enqueue(chunk("a2"), for: meetingA)
        scheduler.enqueue(chunk("b1"), for: meetingB)
        scheduler.enqueue(chunk("b0"), for: meetingB, first: true)
        scheduler.processJobs()
        XCTAssertFalse(scheduler.isTranscribing, "held during a call")
        XCTAssertEqual(scheduler.queue.pending, [meetingA: 2, meetingB: 2])

        held = false
        scheduler.processJobs()
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(finished.map(\.0), ["b0.wav", "a1.wav", "a2.wav", "b1.wav"])
        XCTAssertEqual(finished.map(\.1), [meetingB, meetingA, meetingA, meetingB])
        XCTAssertEqual(engines.maxRunning, 1)
        XCTAssertFalse(scheduler.isTranscribing)
        XCTAssertTrue(scheduler.queue.pending.isEmpty)
    }

    @MainActor
    func testEachMeetingKeepsTheRoutingFixedWhenQueuedAndFailuresAreCounted() async {
        let engines = FakeEngines()
        engines.whisperLanguage = "pl"
        let scheduler = TranscriptionScheduler(engines: engines, makeTranscriber: { Transcriber(model: WhisperModel.all[1]) })
        let polish = UUID(), other = UUID()
        scheduler.fix(polish, transcriber: transcriber, routing: EngineRouting(parakeetEnabled: true))
        var engineUsed: [String: SpeechEngine] = [:]
        var prepared: [UUID?] = []
        scheduler.prepareJob = { _, _, owner in prepared.append(owner) }
        let done = expectation(description: "both")
        done.expectedFulfillmentCount = 2
        scheduler.onFinished = { chunk, _, _, engine, _ in
            engineUsed[chunk.url.lastPathComponent] = engine
            done.fulfill()
        }
        scheduler.startFinishing(polish)
        scheduler.enqueue(chunk("p"), for: polish)
        scheduler.enqueue(chunk("o"), for: other)
        scheduler.processJobs()
        await fulfillment(of: [done], timeout: 5)
        // The meeting without a fixed routing gets whisper only.
        XCTAssertEqual(engineUsed, ["p.wav": .parakeet, "o.wav": .whisper])
        XCTAssertEqual(prepared, [polish, other])
        XCTAssertTrue(scheduler.queue.isReady(polish, recording: false, deliveriesDone: true))
        XCTAssertEqual(scheduler.finish(polish), 0)
        XCTAssertFalse(scheduler.queue.finishing.contains(polish))
    }
}
