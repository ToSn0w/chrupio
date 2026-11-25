import Foundation
@testable import ChrupioCore
import XCTest

final class TranscriptQualityTests: XCTestCase {
    private func whisperJSON(_ texts: [String], language: String? = "pl") -> Data {
        let items = texts.enumerated().map { index, text in
            ["offsets": ["from": index * 1000, "to": index * 1000 + 900], "text": text] as [String: Any]
        }
        var object: [String: Any] = ["transcription": items]
        if let language { object["result"] = ["language": language] }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testDropsRepeatLoopsButKeepsLaterRepeats() throws {
        let json = whisperJSON([
            "Bardzo się cieszymy.", "Bardzo się cieszymy.", "Coś innego.", "Bardzo się cieszymy!",
            "Tak.", "Tak.", "Tak.", "Trzecie.", "Tak.",
        ])
        let texts = try Transcriber.parse(json: json, language: "pl").map(\.text)
        XCTAssertEqual(texts, ["Bardzo się cieszymy.", "Coś innego.", "Bardzo się cieszymy!", "Tak.", "Tak.", "Trzecie.", "Tak."])
    }

    func testPromptCarriesThePreviousChunkTail() {
        var transcriber = Transcriber(model: WhisperModel.all[1], preferredLanguage: "pl", vocabulary: ["Ann"])
        transcriber.previousText = String(repeating: "słowo ", count: 60) + "i wtedy powiedział"
        let prompt = transcriber.prompt() ?? ""
        XCTAssertTrue(prompt.hasPrefix("Ann. "))
        XCTAssertTrue(prompt.hasSuffix("i wtedy powiedział"))
        XCTAssertLessThanOrEqual(prompt.count, 5 + Transcriber.previousTextLimit)
        XCTAssertTrue(transcriber.arguments(wav: URL(fileURLWithPath: "/a.wav"), outBase: URL(fileURLWithPath: "/a"), useVAD: true).contains("--carry-initial-prompt"))
        XCTAssertFalse(transcriber.arguments(wav: URL(fileURLWithPath: "/a.wav"), outBase: URL(fileURLWithPath: "/a"), useVAD: false).contains("--prompt"))
    }

    func testPreviousTextOnlyWhenSpeechRunsOn() {
        let chunk = AudioChunk(track: .system, index: 1, url: URL(fileURLWithPath: "/m-0001.wav"), startOffset: 30, duration: 30, rms: 0.1)
        let segments = [
            TranscriptSegment(start: 20, end: 25, speaker: .remote(nil), text: "first part"),
            TranscriptSegment(start: 26, end: 29.5, speaker: .remote("Ann"), text: "second part"),
            TranscriptSegment(start: 27, end: 29.9, speaker: .me, text: "mine"),
        ]
        XCTAssertEqual(TranscriptAssembler.previousText(segments, before: chunk), "first part second part")
        XCTAssertNil(TranscriptAssembler.previousText(Array(segments.prefix(1)), before: chunk), "a 5 s gap starts fresh")
    }

    func testDropsWrongScriptForLatinLanguage() throws {
        let json = whisperJSON(["ეს არის ტესტი", "Zażółć gęślą jaźń", "Café déjà vu"])
        XCTAssertEqual(try Transcriber.parse(json: json, language: "pl").map(\.text), ["Zażółć gęślą jaźń", "Café déjà vu"])
        XCTAssertEqual(try Transcriber.parse(json: json, language: "ka").count, 3)
        XCTAssertEqual(try Transcriber.parse(json: json).count, 3)
    }

    func testKeepsSpokenParenthesesAndDropsMarkers() {
        XCTAssertEqual(Transcriber.cleanText("It costs (roughly) ten (music) euros [BLANK_AUDIO]"), "It costs (roughly) ten  euros")
        XCTAssertEqual(Transcriber.cleanText("(Applause)"), "")
        XCTAssertEqual(Transcriber.cleanText("Napisy wykonane przez Jan Kowalski"), "")
        XCTAssertEqual(Transcriber.cleanText("Thanks for watching!"), "")
        XCTAssertEqual(Transcriber.cleanText("Thank you very much."), "Thank you very much.")
    }

    func testDetectedLanguage() {
        XCTAssertEqual(Transcriber.detectedLanguage(json: whisperJSON(["a"], language: "de")), "de")
        XCTAssertNil(Transcriber.detectedLanguage(json: whisperJSON(["a"], language: nil)))
        XCTAssertNil(Transcriber.detectedLanguage(json: whisperJSON(["a"], language: "auto")))
    }

    func testArgumentsUseVADAndNamePromptOnlyTogether() {
        let transcriber = Transcriber(model: WhisperModel.all[1], language: "pl", vocabulary: ["Anna Nowak", " ", "Piotr"])
        let wav = URL(fileURLWithPath: "/tmp/a.wav"), out = URL(fileURLWithPath: "/tmp/out")
        let withVAD = transcriber.arguments(wav: wav, outBase: out, useVAD: true)
        XCTAssertTrue(withVAD.contains("--vad"))
        XCTAssertEqual(withVAD.last, "Anna Nowak, Piotr.")
        let plain = transcriber.arguments(wav: wav, outBase: out, useVAD: false)
        XCTAssertFalse(plain.contains("--vad"))
        XCTAssertFalse(plain.contains("--prompt"))
        XCTAssertEqual(plain[plain.firstIndex(of: "-l")! + 1], "pl")
    }

    func testEchoSpanningTwoRemoteSegmentsAndShortEcho() {
        let remote1 = TranscriptSegment(start: 10, end: 12, speaker: .remote(nil), text: "We should release the new build")
        let remote2 = TranscriptSegment(start: 12, end: 14, speaker: .remote(nil), text: "on Friday after the review")
        let echo = TranscriptSegment(start: 10.3, end: 14.1, speaker: .me, text: "release the new build on Friday after review")
        let shortEcho = TranscriptSegment(start: 12.2, end: 13, speaker: .me, text: "Friday")
        let myReply = TranscriptSegment(start: 30, end: 31, speaker: .me, text: "Yes, exactly")
        let result = TranscriptAssembler.removeEcho([remote1, remote2, echo, shortEcho, myReply])
        XCTAssertEqual(result.map(\.text), [remote1.text, remote2.text, myReply.text])
    }
}

final class ChunkWriterFailureTests: XCTestCase {
    func testKeepsAudioWhenDiskWriteFailsAndRecovers() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("cw-\(UUID())")
        let directory = parent.appendingPathComponent("audio")
        defer { try? FileManager.default.removeItem(at: parent) }
        let writer = ChunkWriter(track: .mic, directory: directory, targetSeconds: 1, searchSeconds: 0.2)
        // A file where the folder should be makes every write fail.
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        let second = [Float](repeating: 0.1, count: ChunkWriter.sampleRate)
        XCTAssertTrue(writer.append(second).isEmpty)
        XCTAssertNotNil(writer.writeError)
        XCTAssertEqual(writer.endOffset, 1, accuracy: 0.01)

        try FileManager.default.removeItem(at: directory)
        let chunks = writer.append(second)
        XCTAssertNil(writer.writeError)
        XCTAssertEqual(chunks.map(\.index), [1, 2])
        XCTAssertEqual(chunks.first?.startOffset, 0)
        XCTAssertEqual(AudioChunkScanner.chunks(in: directory).count, 2)
    }
}

final class SummaryPromptTests: XCTestCase {
    func testSystemPromptNamesLanguageAndForbidsOthersAsOwner() {
        let polish = Prompts.summarySystem(language: "pl")
        XCTAssertTrue(polish.contains("in Polish"))
        XCTAssertTrue(polish.contains("never use \"Others\" as an owner"))
        XCTAssertTrue(polish.contains("## Action items"))
        XCTAssertTrue(Prompts.summarySystem(language: nil).contains("language most of the transcript is in"))
    }

    func testUserPromptExplainsYouWithoutSelfName() {
        let meeting = Meeting(title: "Sync", platform: .zoom)
        XCTAssertTrue(Prompts.summaryUser(meeting: meeting, material: "x", isNotes: false).contains("\"You\" is the person who recorded"))
    }

    func testMeetingDecodesWithoutLanguage() throws {
        var meeting = Meeting(title: "Old", platform: .meet)
        meeting.language = "pl"
        var json = try JSONSerialization.jsonObject(with: MeetingStore.encoder.encode(meeting)) as! [String: Any]
        json["language"] = nil
        let decoded = try MeetingStore.decoder.decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.language)
    }
}
