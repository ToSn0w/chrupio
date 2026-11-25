import Foundation
@testable import ChrupioCore
import XCTest

/// Regressions from the first two real Slack huddles (2026-10-19).
final class EchoFromRealHuddleTests: XCTestCase {
    private func me(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, speaker: .me, text: text)
    }

    private func remote(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, speaker: .remote(nil), text: text)
    }

    func testEchoWithDifferentMisspellingsIsDropped() {
        let segments = [
            me(292.6, 298.5, "Plan na dzisiaj. Mam dwa pilne tematy, jeden, który..."),
            remote(292.8, 294.7, "Plan na dzisiaj."),
            remote(294.7, 298.4, "Mam dwa pilnetymaty, jedyny kuturyb."),
        ]
        XCTAssertEqual(TranscriptAssembler.removeEcho(segments).map(\.speaker), [.remote(nil), .remote(nil)])
    }

    func testOwnLinesNextToRemoteSpeechAreKept() {
        let segments = [
            remote(972.8, 974.1, "Dziękuję bardzo."),
            me(970.3, 972.2, "Dzięki wszystkim."),
            me(974.2, 974.7, "Dzięki."),
            remote(667.2, 675.7, "To jest szybsze, dużo mniej tokenów przy komunikacji, dzięki."),
            me(673.5, 678.0, "Spoko, dzięki."),
            me(561.3, 563.0, "Łukasz, coś z twojej strony?"),
        ]
        XCTAssertEqual(TranscriptAssembler.removeEcho(segments).filter(\.speaker.isMe).count, 4)
    }
}

final class PolishTuningTests: XCTestCase {
    func testPromptPutsTermsFirstAndNamesLastWithinLimit() {
        let terms = (1...200).map { "Termin\($0)" }
        let transcriber = Transcriber(model: WhisperModel.all[1], language: "auto", preferredLanguage: "pl",
                                      vocabulary: ["Piotr Kaczmarek", "Sam Carter"], terms: ["Acme", "Kibana", "Sam Carter"] + terms)
        let prompt = transcriber.prompt()!
        XCTAssertTrue(prompt.hasPrefix("Acme, Kibana, Termin1"))
        XCTAssertTrue(prompt.hasSuffix(". Piotr Kaczmarek, Sam Carter."))
        XCTAssertLessThanOrEqual(prompt.count, Transcriber.promptCharacterLimit)
        XCTAssertEqual(prompt.components(separatedBy: "Sam Carter").count, 2)
    }

    func testEnglishPromptAndTermsField() {
        let transcriber = Transcriber(model: WhisperModel.all[1], language: "en", terms: Transcriber.terms(from: "booking,  studio\njob\n\n"))
        XCTAssertEqual(transcriber.prompt(), "booking, studio, job.")
        XCTAssertNil(Transcriber(model: WhisperModel.all[1]).prompt())
    }

    func testPreferredLanguageNeverPinsButReportsTheMajority() {
        var vote = LanguageVote(preferred: "pl")
        for (index, language) in ["en", "en", "en", "pl", "pl", "pl", "pl", "pl"].enumerated() {
            XCTAssertNil(vote.record(language, speechCount: 3, at: Double(index) * 30), "a mixed call keeps per-chunk detection")
        }
        XCTAssertEqual(vote.majority, "pl")
        var mixed = LanguageVote(preferred: "pl")
        _ = mixed.record("en", speechCount: 3, at: 0)
        _ = mixed.record("pl", speechCount: 3, at: 30)
        XCTAssertNil(mixed.majority, "no clear majority")
    }

    func testPreferredLanguageIgnoresAutoAndEmpty() {
        XCTAssertNil(Transcriber(model: WhisperModel.all[1], preferredLanguage: "").preferredLanguage)
        XCTAssertNil(Transcriber(model: WhisperModel.all[1], preferredLanguage: "auto").preferredLanguage)
    }
}

final class BackToBackCallTests: XCTestCase {
    func testCandidateGraceEndsBrowserFallbackSooner() {
        var detector = MeetingDetector(startDelay: 0, endGrace: 15)
        let start = Date()
        let browser = MeetingCandidate(key: "app:chrome", platform: .other, title: "Browser call", endGrace: 5)
        XCTAssertEqual(detector.update(candidates: [browser], now: start), .start(browser))
        XCTAssertNil(detector.update(candidates: [], now: start + 2))
        XCTAssertEqual(detector.update(candidates: [], now: start + 6), .stop)
    }

    func testChromeProfilesWithoutExtension() throws {
        let chrome = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-\(UUID())")
        defer { try? FileManager.default.removeItem(at: chrome) }
        func write(_ object: Any, _ path: String) throws {
            let url = chrome.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object).write(to: url)
        }
        try write(["profile": ["info_cache": ["Default": ["name": "Your Chrome"], "Profile 1": ["name": "Your Chrome"], "Profile 2": ["name": "Work"],
                                              "Profile 3": ["name": "Home"]]]], "Local State")
        let loaded: [String: Any] = ["path": "/Users/x/Library/Application Support/Chrupio/ChromeExtension", "location": 4]
        try write(["extensions": ["settings": ["abc": loaded]]], "Profile 1/Secure Preferences")
        try write(["extensions": ["settings": ["abc": loaded.merging(["disable_reasons": [1]]) { $1 }]]], "Profile 2/Secure Preferences")
        try write(["extensions": ["settings": ["abc": loaded]]], "Profile 3/Preferences")
        XCTAssertEqual(ExtensionPackage.chromeProfilesWithoutExtension(chromeFolder: chrome), ["Your Chrome (Default)", "Work"])
    }
}

final class MeetingSplitTests: XCTestCase {
    func testSplitMovesTranscriptAndAudioToSecondMeeting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("split-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var meeting = Meeting(
            title: "Browser call", platform: .other, startedAt: start, endedAt: start + 120,
            segments: [
                TranscriptSegment(start: 10, end: 14, speaker: .me, text: "Fajny weekend"),
                TranscriptSegment(start: 70, end: 75, speaker: .remote(nil), text: "Cześć, spóźnienie"),
            ],
            speakerEvents: [SpeakerEvent(time: 5, names: ["A"]), SpeakerEvent(time: 80, names: ["B"])],
            summary: MeetingSummary(markdown: "both calls", model: "m"), status: .done
        )
        meeting.error = "Claude Code took too long to write the summary."
        meeting.summaryError = "Claude Code took too long to write the summary."
        try store.save(meeting)
        let audio = store.audioDirectory(for: meeting.id)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        for (index, offset) in [0.0, 30, 60, 90].enumerated() {
            let url = audio.appendingPathComponent(String(format: "mic-%04d.wav", index + 1))
            try WAVFile.write([Float](repeating: index == 2 ? 0.5 : 0, count: 16_000 * 30), sampleRate: 16_000, to: url)
            let chunk = AudioChunk(track: .mic, index: index + 1, url: url, startOffset: offset, duration: 30, rms: 0.01)
            try JSONEncoder().encode(chunk).write(to: url.deletingPathExtension().appendingPathExtension("json"))
        }

        let (first, second) = try store.split(meeting.id, at: 65, retranscribe: true)

        XCTAssertEqual(first.segments.map(\.text), ["Fajny weekend"])
        XCTAssertNil(first.summary)
        XCTAssertNil(first.error)
        XCTAssertNil(first.summaryError, "the summary it described is gone")
        XCTAssertEqual(first.status, .transcribing)
        XCTAssertEqual(first.endedAt, start + 65)
        XCTAssertEqual(second.startedAt, start + 65)
        XCTAssertEqual(second.endedAt, start + 120)
        XCTAssertEqual(second.segments.map(\.start), [5])
        XCTAssertEqual(second.speakerEvents.map(\.time), [15])
        // The chunk from 60 to 90 s is cut at 65 s: 5 s stay, 25 s move.
        let kept = AudioChunkScanner.chunks(in: audio)
        XCTAssertEqual(kept.map(\.startOffset), [0, 30, 60])
        XCTAssertEqual(kept[2].duration, 5, accuracy: 0.001)
        XCTAssertEqual(WAVFile.duration(of: kept[2].url), 5, accuracy: 0.001)
        let moved = AudioChunkScanner.chunks(in: store.audioDirectory(for: second.id))
        XCTAssertEqual(moved.map(\.startOffset), [0, 25])
        XCTAssertEqual(moved[0].duration, 25, accuracy: 0.001)
        XCTAssertEqual(moved[0].rms, 0.5, accuracy: 0.001)
        XCTAssertEqual(moved.map { $0.url.lastPathComponent }, ["mic-0001.wav", "mic-0002.wav"])
        XCTAssertEqual(try store.load(second.id).status, .transcribing)
        XCTAssertThrowsError(try store.split(meeting.id, at: 500, retranscribe: false))
    }

    func testFailedSplitLeavesMeetingAndAudioAsTheyWere() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("split-\(UUID())")
        let store = MeetingStore(root: root)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = Meeting(title: "Browser call", platform: .other, startedAt: start, endedAt: start + 120,
                              segments: [TranscriptSegment(start: 70, end: 75, speaker: .remote(nil), text: "Hi")], status: .done)
        try store.save(meeting)
        let audio = store.audioDirectory(for: meeting.id)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        for (index, offset) in [0.0, 30, 60, 90].enumerated() {
            let url = audio.appendingPathComponent(String(format: "mic-%04d.wav", index + 1))
            try WAVFile.write([Float](repeating: 0.1, count: 16_000 * 30), sampleRate: 16_000, to: url)
            let chunk = AudioChunk(track: .mic, index: index + 1, url: url, startOffset: offset, duration: 30, rms: 0.1)
            try JSONEncoder().encode(chunk).write(to: url.deletingPathExtension().appendingPathExtension("json"))
        }
        // A read-only audio folder: the cut chunk's tail is written, then moving the 90 s chunk out fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: audio.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: audio.path)
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertThrowsError(try store.split(meeting.id, at: 65, retranscribe: true))

        XCTAssertEqual(store.loadAll().map(\.id), [meeting.id], "no second meeting is left behind")
        XCTAssertEqual(try store.load(meeting.id), meeting)
        let chunks = AudioChunkScanner.chunks(in: audio)
        XCTAssertEqual(chunks.map(\.startOffset), [0, 30, 60, 90])
        XCTAssertEqual(chunks.map { WAVFile.duration(of: $0.url) }, [30, 30, 30, 30])
        let folders = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { UUID(uuidString: $0) != nil }
        XCTAssertEqual(folders, [meeting.id.uuidString], "no audio is orphaned in a folder without a meeting")
    }
}
