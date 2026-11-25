import Darwin
import ChrupioAudio
import ChrupioCore
import XCTest

/// Runs Parakeet on a real recording. Needs the downloaded models and a WAV outside the repo:
/// CHRUPIO_PARAKEET_SAMPLE=/path/to/call.wav swift test --filter ParakeetEndToEndTests
final class ParakeetEndToEndTests: XCTestCase {
    func testTranscribesARecordingWithWordTimes() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHRUPIO_PARAKEET_SAMPLE"] else {
            throw XCTSkip("set CHRUPIO_PARAKEET_SAMPLE to a WAV file")
        }
        try XCTSkipUnless(ParakeetTranscriber.isDownloaded, "run: Chrupio --download-parakeet")
        let wav = URL(fileURLWithPath: path)
        let transcriber = ParakeetTranscriber()

        let loadStart = Date()
        try await transcriber.prepare()
        let loaded = Date().timeIntervalSince(loadStart)
        let start = Date()
        let transcription = try await transcriber.transcribe(wav: wav, language: "pl")
        let elapsed = Date().timeIntervalSince(start)
        await transcriber.release()

        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let words = transcription.speech.flatMap(\.words)
        let duration = WAVFile.duration(of: wav)
        print("""
            Parakeet: \(String(format: "%.0f", duration)) s of audio, model load \(String(format: "%.1f", loaded)) s, \
            transcription \(String(format: "%.1f", elapsed)) s, peak RSS \(usage.ru_maxrss / 1_048_576) MB, \
            \(transcription.speech.count) lines, \(words.count) words
            """)
        for line in transcription.speech.prefix(5) {
            print(String(format: "[%6.2f-%6.2f] ", line.start, line.end) + line.text)
        }

        XCTAssertFalse(transcription.speech.isEmpty)
        XCTAssertGreaterThan(words.count, 50)
        XCTAssertEqual(words.map(\.start), words.map(\.start).sorted(), "word times run forward")
        XCTAssertLessThanOrEqual(words.last?.end ?? 0, duration + 0.5)
        for line in transcription.speech {
            XCTAssertFalse(line.words.isEmpty)
            XCTAssertEqual(line.start, line.words.first?.start)
        }
    }
}
