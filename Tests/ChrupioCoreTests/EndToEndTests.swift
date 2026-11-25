import Foundation
@testable import ChrupioCore
import XCTest

/// Runs the real pipeline: macOS speech synthesis → whisper.cpp → Claude Haiku.
/// Opt in with CHRUPIO_E2E=1; needs whisper-cli, a downloaded model and Claude Code logged in.
final class EndToEndTests: XCTestCase {
    func testSpeechToSummary() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHRUPIO_E2E"] == "1", "set CHRUPIO_E2E=1")
        let model = try XCTUnwrap(WhisperModel.all.first { $0.name == "base.en" && $0.isDownloaded }
            ?? WhisperModel.all.first { $0.isDownloaded }, "no whisper model downloaded")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chrupio-e2e-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("speech.wav")
        let script = "Good morning everyone. We decided to ship the new billing page on Friday. Anna will write the release notes by Thursday."
        try run("/usr/bin/say", ["-o", wav.path, "--data-format=LEI16@16000", script])

        let speech = try await Transcriber(model: model, language: "en").transcribe(wav: wav)
        let text = speech.map(\.text).joined(separator: " ").lowercased()
        print("E2E transcript: \(text)")
        XCTAssertTrue(text.contains("billing"), text)
        XCTAssertTrue(text.contains("friday"), text)

        let chunk = AudioChunk(track: .system, index: 0, url: wav, startOffset: 0, duration: 10, rms: 0.1)
        var meeting = Meeting(title: "Billing sync", platform: .meet, attendees: ["Anna", "Me"], selfName: "Me")
        meeting.segments = TranscriptAssembler.segments(for: chunk, speech: speech)
        let claude = try XCTUnwrap(ClaudeSummarizer.findExecutable(), "Claude Code not installed")
        let summary = try await ClaudeSummarizer(executable: claude).summarize(meeting)
        XCTAssertTrue(summary.markdown.localizedCaseInsensitiveContains("billing"), summary.markdown)
        print("E2E summary:\n\(summary.markdown)")
    }

    private func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
