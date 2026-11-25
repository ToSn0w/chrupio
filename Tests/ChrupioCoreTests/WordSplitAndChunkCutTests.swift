import Foundation
@testable import ChrupioCore
import XCTest

final class WordSplitTests: XCTestCase {
    func testTokensJoinIntoWords() {
        let words = Transcriber.words([
            ("[_BEG_]", 0, 0), (" Can", 160, 160), (" av", 300, 400), ("alan", 400, 500), ("che", 500, 600), (".", 600, 650),
            (" doesn", 700, 800), ("'t", 800, 900), ("[_TT_50]", 900, 900),
        ])
        XCTAssertEqual(words.map(\.text), ["Can", "avalanche.", "doesn't"])
        XCTAssertEqual(words[1].start, 0.3)
        XCTAssertEqual(words[1].end, 0.65)
    }

    func testParseKeepsWordTimes() throws {
        let object: [String: Any] = ["transcription": [[
            "offsets": ["from": 0, "to": 2000], "text": " Tak, jasne.",
            "tokens": [["text": " Tak", "offsets": ["from": 100, "to": 400]], ["text": ",", "offsets": ["from": 400, "to": 450]],
                       ["text": " jasne", "offsets": ["from": 600, "to": 1100]], ["text": ".", "offsets": ["from": 1100, "to": 1200]]],
        ]]]
        let speech = try Transcriber.parse(json: JSONSerialization.data(withJSONObject: object), language: "pl")
        XCTAssertEqual(speech[0].words.map(\.text), ["Tak,", "jasne."])
        let chunk = AudioChunk(track: .system, index: 2, url: URL(fileURLWithPath: "/s-0002.wav"), startOffset: 30, duration: 30, rms: 0.1)
        let segment = TranscriptAssembler.segments(for: chunk, speech: speech)[0]
        XCTAssertEqual(segment.words?.first?.start, 30.1)
    }

    private func words(_ spec: [(String, Double)]) -> [TimedWord] {
        spec.map { TimedWord(start: $0.1, end: $0.1 + 0.4, text: $0.0) }
    }

    func testSplitsALineWhereTheSpeakerChanges() {
        // Ann 10-12.4, Bob 13-15.4 in one whisper line.
        let segment = TranscriptSegment(start: 10, end: 15.5, speaker: .remote(nil), text: "x",
                                        words: words([("a", 10), ("b", 11), ("c", 12), ("d", 13), ("e", 14), ("f", 15)]))
        let parts = SegmentSplitter.split(segment) { start, _ in start < 12.6 ? "Ann" : "Bob" }
        XCTAssertEqual(parts.map(\.1), ["Ann", "Bob"])
        XCTAssertEqual(parts.map(\.0.text), ["a b c", "d e f"])
        XCTAssertEqual(parts[0].0.id, segment.id)
        XCTAssertEqual(parts[0].0.start, 10)
        XCTAssertEqual(parts[1].0.end, 15.5)
    }

    func testShortBlipsAndUnlabelledWordsDoNotSplit() {
        let segment = TranscriptSegment(start: 0, end: 5, speaker: .remote(nil), text: "x",
                                        words: words([("a", 0), ("b", 1), ("c", 2), ("d", 3), ("e", 4)]))
        let parts = SegmentSplitter.split(segment) { start, _ in start > 1.5 && start < 2.5 ? "Bob" : start < 0.5 ? nil : "Ann" }
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].1, "Ann")
        XCTAssertEqual(parts[0].0.text, "x", "an unsplit line keeps its text")
        XCTAssertEqual(SegmentSplitter.split(segment) { _, _ in nil }.count, 1)
    }

    func testAttributionSplitsByLiveEvents() {
        var meeting = Meeting(title: "x", platform: .meet, attendees: ["Ann", "Bob", "Me"], selfName: "Me")
        meeting.segments = [TranscriptSegment(start: 10, end: 16, speaker: .remote(nil), text: "x",
                                              words: words([("a", 10), ("b", 11), ("c", 12), ("d", 13.5), ("e", 14.5), ("f", 15.5)]))]
        meeting.speakerEvents = [11, 12, 13].map { SpeakerEvent(time: $0, names: ["Ann"]) } + [14.3, 15, 16].map { SpeakerEvent(time: $0, names: ["Bob"]) }
        SpeakerAttribution.apply(to: &meeting)
        XCTAssertEqual(meeting.segments.map(\.speaker.label), ["Ann", "Bob"])
        XCTAssertEqual(meeting.segments.map(\.text), ["a b c", "d e f"])
        let again = meeting
        SpeakerAttribution.apply(to: &meeting)
        XCTAssertEqual(meeting.segments.map(\.text), again.segments.map(\.text), "applying twice changes nothing")
    }
}

final class ChunkCutTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cut-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { 0.2 * sin(Float($0) * 0.1) }
    }

    func testCutsInTheLastLongPause() {
        let writer = ChunkWriter(track: .mic, directory: directory())
        // Speech to 22 s, a 0.5 s pause, speech to 27.9 s, a 0.1 s gap (too short), speech on.
        let audio = tone(22) + [Float](repeating: 0, count: 8_000) + tone(5.4) + [Float](repeating: 0, count: 1_600) + tone(10)
        let chunks = writer.append(audio)
        XCTAssertEqual(chunks.first?.duration ?? 0, 22.25, accuracy: 0.03)
    }

    func testFallsBackToTheQuietestPointWithoutAPause() {
        let writer = ChunkWriter(track: .mic, directory: directory())
        XCTAssertEqual(writer.append(tone(40)).count, 1)
    }

    func testChunkInProgressIsOnDisk() {
        let dir = directory()
        let writer = ChunkWriter(track: .system, directory: dir)
        _ = writer.append(tone(6))
        let partial = AudioChunkScanner.chunks(in: dir)
        XCTAssertEqual(partial.count, 1)
        XCTAssertEqual(partial.first?.duration ?? 0, 6, accuracy: 0.01)
        let full = writer.append(tone(30)) + [writer.flush()].compactMap { $0 }
        XCTAssertEqual(full.count, 2)
        XCTAssertEqual(AudioChunkScanner.chunks(in: dir).map(\.duration).reduce(0, +), 36, accuracy: 0.01, "the partial was replaced, not kept beside")
    }
}
