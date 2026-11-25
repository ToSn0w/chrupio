import Foundation
import XCTest
@testable import ChrupioCore

/// A fake model folder in a temporary directory: the download writes a marker file, or fails.
private final class FakeModel: @unchecked Sendable {
    let folder: URL
    private let lock = NSLock()
    private var _downloads = 0
    var fail = false
    var downloads: Int { lock.withLock { _downloads } }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ondemand-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    var marker: URL { folder.appendingPathComponent("model.bin") }
    var isPresent: Bool { FileManager.default.fileExists(atPath: marker.path) }
    func download() throws {
        lock.withLock { _downloads += 1 }
        if fail { throw CocoaError(.fileWriteUnknown) }
        try Data("model".utf8).write(to: marker)
    }
}

final class OnDemandDownloadTests: XCTestCase {
    private func make(_ model: FakeModel) -> OnDemandDownload {
        OnDemandDownload(isPresent: { model.isPresent }, download: { try model.download() })
    }

    func testMissingModelsStartOneBackgroundDownloadAndReportNotReady() async throws {
        let model = try FakeModel()
        defer { try? FileManager.default.removeItem(at: model.folder) }
        let gate = make(model)
        let first = await gate.ensure()
        _ = await gate.ensure()
        XCTAssertFalse(first)
        await gate.waitForDownload()
        XCTAssertEqual(model.downloads, 1)
        XCTAssertTrue(model.isPresent)
        let afterwards = await gate.ensure()
        XCTAssertTrue(afterwards)
        XCTAssertEqual(model.downloads, 1)
    }

    func testPresentModelsNeverDownload() async throws {
        let model = try FakeModel()
        defer { try? FileManager.default.removeItem(at: model.folder) }
        try model.download()
        let gate = make(model)
        let ready = await gate.ensure()
        XCTAssertTrue(ready)
        XCTAssertEqual(model.downloads, 1)
    }

    func testAFailedDownloadIsTriedAgainOnTheNextCall() async throws {
        let model = try FakeModel()
        defer { try? FileManager.default.removeItem(at: model.folder) }
        model.fail = true
        let gate = make(model)
        _ = await gate.ensure()
        await gate.waitForDownload()
        model.fail = false
        _ = await gate.ensure()
        await gate.waitForDownload()
        XCTAssertEqual(model.downloads, 2)
        XCTAssertTrue(model.isPresent)
    }

    /// The whole path for a pinned Polish chunk: Parakeet's models are missing, so the gate starts the download and whisper writes the chunk.
    func testAPolishChunkGoesToWhisperWhileParakeetDownloads() async throws {
        let model = try FakeModel()
        defer { try? FileManager.default.removeItem(at: model.folder) }
        let engines = GatedEngines(gate: make(model))
        let job = TranscriptionJob(transcriber: Transcriber(model: WhisperModel.all[1]),
                                   routing: EngineRouting(parakeetEnabled: true).pinned(toConfirmed: "pl"))
        let chunk = AudioChunk(track: .mic, index: 0, url: URL(fileURLWithPath: "/nonexistent/a.wav"), startOffset: 0, duration: 30, rms: 0.1)
        let (first, firstEngine) = await TranscriptionScheduler.transcribe(chunk.url, chunk: chunk, job: job, engines: engines)
        XCTAssertEqual(firstEngine, .whisper)
        XCTAssertEqual(try first.get().speech.first?.text, "whisper")
        await engines.gate.waitForDownload()
        let (_, laterEngine) = await TranscriptionScheduler.transcribe(chunk.url, chunk: chunk, job: job, engines: engines)
        XCTAssertEqual(laterEngine, .parakeet)
        XCTAssertEqual(model.downloads, 1)
    }
}

/// Parakeet runs only once the gate says its models are there, like ParakeetTranscriber.prepare.
private struct GatedEngines: SpeechEngines {
    let gate: OnDemandDownload
    func whisper(_ wav: URL, transcriber: Transcriber) async throws -> Transcription {
        Transcription(speech: [RecognizedSpeech(start: 0, end: 1, text: "whisper")], language: "pl")
    }
    func parakeet(_ wav: URL, language: String?, chunk: AudioChunk, vocabulary: [String], aliases: [String: [String]]) async throws -> Transcription {
        guard await gate.ensure() else { throw TranscriberError.failed("models missing") }
        return Transcription(speech: [RecognizedSpeech(start: 0, end: 1, text: "parakeet")], language: language)
    }
    func removeEcho(_ chunk: AudioChunk) async -> URL? { nil }
}
