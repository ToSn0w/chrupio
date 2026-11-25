import CryptoKit
import Foundation
@testable import ChrupioCore
import XCTest

final class MeetingDetectorTests: XCTestCase {
    let meet = MeetingCandidate(key: "chrome-tab:1", platform: .meet, title: "Standup")
    let t0 = Date(timeIntervalSince1970: 1_000)

    func testStartsAfterDelayAndStopsAfterGrace() {
        var detector = MeetingDetector(startDelay: 3, endGrace: 15)
        XCTAssertNil(detector.update(candidates: [meet], now: t0))
        XCTAssertNil(detector.update(candidates: [meet], now: t0 + 2))
        XCTAssertEqual(detector.update(candidates: [meet], now: t0 + 3), .start(meet))
        XCTAssertNil(detector.update(candidates: [meet], now: t0 + 10))
        XCTAssertNil(detector.update(candidates: [], now: t0 + 20))
        XCTAssertEqual(detector.update(candidates: [], now: t0 + 25), .stop)
        XCTAssertNil(detector.active)
    }

    func testFlickerDoesNotStart() {
        var detector = MeetingDetector(startDelay: 3, endGrace: 15)
        XCTAssertNil(detector.update(candidates: [meet], now: t0))
        XCTAssertNil(detector.update(candidates: [], now: t0 + 2))
        XCTAssertNil(detector.update(candidates: [meet], now: t0 + 4))
        XCTAssertNil(detector.update(candidates: [meet], now: t0 + 6))
        XCTAssertEqual(detector.update(candidates: [meet], now: t0 + 7), .start(meet))
    }

    func testReturningWithinGraceKeepsMeeting() {
        var detector = MeetingDetector(startDelay: 0, endGrace: 15)
        XCTAssertEqual(detector.update(candidates: [meet], now: t0), .start(meet))
        XCTAssertNil(detector.update(candidates: [], now: t0 + 10))
        XCTAssertNil(detector.update(candidates: [meet], now: t0 + 12))
        XCTAssertNil(detector.update(candidates: [], now: t0 + 26))
        XCTAssertEqual(detector.update(candidates: [], now: t0 + 27), .stop)
    }

    func testActiveCandidateTitleRefreshes() {
        var detector = MeetingDetector(startDelay: 0, endGrace: 15)
        _ = detector.update(candidates: [meet], now: t0)
        var renamed = meet
        renamed.title = "Weekly sync"
        _ = detector.update(candidates: [renamed], now: t0 + 2)
        XCTAssertEqual(detector.active?.title, "Weekly sync")
    }
}

final class BrowserTrackerTests: XCTestCase {
    func testHeartbeatsAndEnd() {
        var tracker = BrowserMeetingTracker(staleAfter: 12)
        let now = Date()
        tracker.record(ExtensionEvent(type: .meeting, platform: .meet, tabId: 7, inMeeting: true, participants: ["Ann"]), now: now)
        tracker.record(ExtensionEvent(type: .meeting, platform: .teams, tabId: 8, inMeeting: false), now: now)
        XCTAssertEqual(tracker.candidates(now: now).map(\.key), ["chrome-tab:7"])
        XCTAssertEqual(tracker.state(forKey: "chrome-tab:7")?.participants, ["Ann"])
        tracker.record(ExtensionEvent(type: .ended, platform: .meet, tabId: 7), now: now)
        XCTAssertTrue(tracker.candidates(now: now).isEmpty)
    }

    func testStaleTabsExpire() {
        var tracker = BrowserMeetingTracker(staleAfter: 12)
        let now = Date()
        tracker.record(ExtensionEvent(type: .meeting, platform: .slack, tabId: 1, inMeeting: true), now: now)
        XCTAssertEqual(tracker.candidates(now: now + 11).count, 1)
        XCTAssertEqual(tracker.candidates(now: now + 13).count, 0)
    }
}

final class TranscriptTests: XCTestCase {
    func testWhisperJSONParsingAndCleaning() throws {
        let json = """
        {"transcription":[
          {"offsets":{"from":0,"to":2000},"text":" Hello team."},
          {"offsets":{"from":2000,"to":4000},"text":" [BLANK_AUDIO]"},
          {"offsets":{"from":4000,"to":6000},"text":" Thank you."},
          {"offsets":{"from":6000,"to":9000},"text":" Ship it (laughs) on Friday."}
        ]}
        """
        let speech = try Transcriber.parse(json: Data(json.utf8))
        // "Thank you." next to other speech was said, so it stays.
        XCTAssertEqual(speech.map(\.text).count, 3)
        XCTAssertEqual(speech[0].text, "Hello team.")
        XCTAssertEqual(speech[1].text, "Thank you.")
        XCTAssertTrue(speech[2].text.hasPrefix("Ship it"))
        XCTAssertEqual(speech[2].start, 6)
    }

    func testSegmentsUseChunkOffsetAndTrack() {
        let chunk = AudioChunk(track: .system, index: 2, url: URL(fileURLWithPath: "/tmp/x.wav"), startOffset: 30, duration: 30, rms: 0.1)
        let segments = TranscriptAssembler.segments(for: chunk, speech: [RecognizedSpeech(start: 1, end: 40, text: "Hi")])
        XCTAssertEqual(segments[0].start, 31)
        XCTAssertEqual(segments[0].end, 60)
        XCTAssertEqual(segments[0].speaker, .remote(nil))
    }

    func testEchoRemoval() {
        let remote = TranscriptSegment(start: 10, end: 14, speaker: .remote(nil), text: "We should release the new build on Friday")
        let echo = TranscriptSegment(start: 10.5, end: 14.2, speaker: .me, text: "we should release the new build Friday")
        let mine = TranscriptSegment(start: 20, end: 22, speaker: .me, text: "Sounds good, I will prepare notes")
        let result = TranscriptAssembler.removeEcho([remote, echo, mine])
        XCTAssertEqual(result.map(\.text), [remote.text, mine.text])
    }

    func testSpeakerAttribution() {
        var meeting = Meeting(title: "x", platform: .meet, attendees: ["Ann", "Bob", "Me"], selfName: "Me")
        meeting.segments = [
            TranscriptSegment(start: 5, end: 9, speaker: .remote(nil), text: "a"),
            TranscriptSegment(start: 30, end: 33, speaker: .remote(nil), text: "b"),
            TranscriptSegment(start: 50, end: 52, speaker: .me, text: "c"),
        ]
        meeting.speakerEvents = [
            SpeakerEvent(time: 6, names: ["Ann"]), SpeakerEvent(time: 8, names: ["Ann", "Me"]),
            SpeakerEvent(time: 31, names: ["Bob"]),
        ]
        SpeakerAttribution.apply(to: &meeting)
        XCTAssertEqual(meeting.segments.map(\.speaker.label), ["Ann", "Bob", "You"])
    }

    func testLaggedEventsNameAQuickReplyCorrectly() {
        // Ann talks 10-14 and 15-20, Bob says "Tak" at 14.2-14.8; indicators light about 0.8 s late, once a second plus on change.
        var meeting = Meeting(title: "x", platform: .meet, attendees: ["Ann", "Bob", "Me"], selfName: "Me")
        meeting.segments = [
            TranscriptSegment(start: 10, end: 14, speaker: .remote(nil), text: "a"),
            TranscriptSegment(start: 14.2, end: 14.8, speaker: .remote(nil), text: "Tak"),
            TranscriptSegment(start: 15, end: 20, speaker: .remote(nil), text: "b"),
        ]
        meeting.speakerEvents = [11, 12, 13, 14].map { SpeakerEvent(time: $0, names: ["Ann"]) }
            + [SpeakerEvent(time: 15.1, names: ["Bob"])]
            + [16, 17, 18, 19, 20].map { SpeakerEvent(time: $0, names: ["Ann"]) }
        SpeakerAttribution.apply(to: &meeting)
        XCTAssertEqual(meeting.segments.map(\.speaker.label), ["Ann", "Bob", "Ann"])
    }

    func testEventTimeComesFromTheExtensionClock() {
        let received = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(SpeakerEvent.date(ts: 998_500, received: received), Date(timeIntervalSince1970: 998.5))
        XCTAssertEqual(SpeakerEvent.date(ts: 900_000, received: received), received, "a skewed clock is ignored")
        XCTAssertEqual(SpeakerEvent.date(ts: nil, received: received), received)
    }

    func testOneOnOneAttributesTheOtherPerson() {
        XCTAssertEqual(SpeakerAttribution.remoteSpeaker(start: 0, end: 5, events: [], attendees: ["Me", "Kate"], selfName: "Me"), "Kate")
        XCTAssertNil(SpeakerAttribution.remoteSpeaker(start: 0, end: 5, events: [], attendees: ["Me", "Kate", "Joe"], selfName: "Me"))
    }

    func testGroupingAndPlainText() {
        let segments = [
            TranscriptSegment(start: 0, end: 2, speaker: .me, text: "Hi."),
            TranscriptSegment(start: 2.5, end: 4, speaker: .me, text: "Ready?"),
            TranscriptSegment(start: 65, end: 67, speaker: .remote("Ann"), text: "Yes."),
        ]
        XCTAssertEqual(TranscriptFormatter.plainText(segments), "[00:00] You: Hi. Ready?\n[01:05] Ann: Yes.")
        XCTAssertEqual(TranscriptFormatter.timestamp(3725), "1:02:05")
    }

    func testMarkdownExportContainsSections() {
        var meeting = Meeting(title: "Planning", platform: .zoom, attendees: ["Ann"])
        meeting.endedAt = meeting.startedAt.addingTimeInterval(600)
        meeting.summary = MeetingSummary(markdown: "## Summary\nDone.", model: "m")
        meeting.segments = [TranscriptSegment(start: 1, end: 2, speaker: .remote("Ann"), text: "Hello")]
        let markdown = TranscriptFormatter.markdown(meeting)
        XCTAssertTrue(markdown.contains("# Planning"))
        XCTAssertTrue(markdown.contains("**Attendees:** Ann"))
        XCTAssertTrue(markdown.contains("## Summary"))
        XCTAssertTrue(markdown.contains("**Ann** [00:01]: Hello"))
        XCTAssertTrue(markdown.contains("10 min"))
    }

    func testMarkdownExportShowsSummaryWarningsAfterSummary() {
        var meeting = Meeting(title: "Planning", platform: .zoom)
        meeting.summary = MeetingSummary(markdown: "## Summary\nDone.", model: "m")
        meeting.summary?.warnings = ["Ticket keys not heard in the transcript: ZZ-9", "Part 2 of 3: the notes couldn't be read."]
        meeting.segments = [TranscriptSegment(start: 1, end: 2, speaker: .remote("Ann"), text: "Hello")]
        let markdown = TranscriptFormatter.markdown(meeting)
        XCTAssertTrue(markdown.contains("## Summary\nDone.\n\n> Warning: Ticket keys not heard in the transcript: ZZ-9\n> Warning: Part 2 of 3: the notes couldn't be read.\n\n## Transcript"))
        meeting.summary?.warnings = nil
        XCTAssertFalse(TranscriptFormatter.markdown(meeting).contains("Warning:"))
        meeting.summary?.warnings = []
        XCTAssertFalse(TranscriptFormatter.markdown(meeting).contains("Warning:"))
    }

    func testMergeAttendeesDedupes() {
        var meeting = Meeting(title: "x", platform: .meet, attendees: ["Ann"])
        meeting.mergeAttendees(["ann", " Bob ", "", "Bob"])
        XCTAssertEqual(meeting.attendees, ["Ann", "Bob"])
    }

    func testMissingSpeakersWarningNeedsOtherPeopleAndTime() {
        let call = ExtensionEvent(type: .meeting, platform: .meet, tabId: 1, participants: ["Me", "Ann Lee", "Bob Smith"], selfName: "Me")
        XCTAssertNotNil(call.missingSpeakersWarning(speakerEventCount: 0, elapsed: 150))
        XCTAssertNil(call.missingSpeakersWarning(speakerEventCount: 0, elapsed: 60), "too early")
        XCTAssertNil(call.missingSpeakersWarning(speakerEventCount: 3, elapsed: 600), "detection works")
        let alone = ExtensionEvent(type: .meeting, platform: .slack, tabId: 1, participants: ["Me"], selfName: "Me")
        XCTAssertNil(alone.missingSpeakersWarning(speakerEventCount: 0, elapsed: 600), "nobody else to detect")
    }

    func testMergeAttendeesDropsMeetUIText() {
        var meeting = Meeting(title: "x", platform: .meet)
        meeting.mergeAttendees([
            "Others might still see your full video.", "Stickers", "Anna K.",
            "John Smith Jr.", "Maria de la Cruz", "Ana Maria de la Cruz", "Backgrounds and effects"
        ])
        XCTAssertEqual(meeting.attendees, ["Anna K.", "John Smith Jr.", "Maria de la Cruz"])
    }
}

final class SummarizerTests: XCTestCase {
    func testSplitKeepsLines() {
        let text = (1...10).map { "line \($0) " + String(repeating: "x", count: 20) }.joined(separator: "\n")
        let chunks = Summarizer.split(text, maxCharacters: 90)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 90 })
        XCTAssertEqual(chunks.joined(), text)
    }

    func testTidyRemovesThinkingAndFences() {
        XCTAssertEqual(Summarizer.tidy("<think>hmm</think>\n```markdown\n## Summary\nOk\n```"), "## Summary\nOk")
        XCTAssertEqual(Summarizer.tidy("## Action items\n- [ ] Unassigned: None recorded\n* [ ] none"), "## Action items\n- None recorded\n- None recorded")
        XCTAssertEqual(Summarizer.tidy("- [ ] Sam: none of the slides, redo them"), "- [ ] Sam: none of the slides, redo them")
        XCTAssertEqual(Summarizer.tidy("<notes-4f9a1c2e>\n## Summary\nOk </transcript-0a1b2c3d> done\n</NOTES-4f9a1c2e>\n<user_notes-deadbeef>\n</project_context-12345678>"),
                       "## Summary\nOk  done", "fence tags a local model echoes don't stay in the summary")
        XCTAssertEqual(Summarizer.tidy("<transcripts-4f9a1c2e> <notes-xyz> <b>"), "<transcripts-4f9a1c2e> <notes-xyz> <b>")
    }

    func testPromptMentionsAttendeesAndSelf() {
        let meeting = Meeting(title: "Sync", platform: .teams, attendees: ["Ann", "Łukasz"], selfName: "Łukasz")
        let prompt = Prompts.summaryUser(meeting: meeting, material: "[00:00] You: hi", isNotes: false)
        XCTAssertTrue(prompt.contains("Attendees: Ann, Łukasz"))
        XCTAssertTrue(prompt.contains("\"You\" in the transcript is Łukasz"))
    }
}

final class AudioFileTests: XCTestCase {
    func testChunkWriterCutsAndWritesSidecars() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = ChunkWriter(track: .mic, directory: dir, trackOffset: 1, targetSeconds: 2, searchSeconds: 1)
        let rate = ChunkWriter.sampleRate
        // 5 s tone with a silent gap at 1.5–1.7 s.
        var samples = (0..<(rate * 5)).map { Float(sin(Double($0) * 0.05)) * 0.3 }
        for i in Int(1.5 * Double(rate))..<Int(1.7 * Double(rate)) { samples[i] = 0 }
        let chunks = writer.append(samples)
        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].startOffset, 1)
        // The first cut lands in the silent gap rather than at exactly 2 s.
        XCTAssertLessThan(chunks[0].duration, 1.75)
        XCTAssertGreaterThan(chunks[0].duration, 1.45)
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(previous.startOffset + previous.duration, next.startOffset, accuracy: 0.001)
        }
        let all = chunks + [writer.flush()].compactMap { $0 }
        XCTAssertEqual(all.last!.startOffset + all.last!.duration, 6, accuracy: 0.5)

        let scanned = AudioChunkScanner.chunks(in: dir)
        XCTAssertEqual(scanned.map(\.index), all.map(\.index))
        let header = try Data(contentsOf: chunks[0].url).prefix(4)
        XCTAssertEqual(String(decoding: header, as: UTF8.self), "RIFF")
    }

    func testSilenceDetection() {
        XCTAssertTrue(AudioChunk(track: .mic, index: 1, url: URL(fileURLWithPath: "/x"), startOffset: 0, duration: 1, rms: 0.0005).isSilent)
        XCTAssertEqual(WAVFile.rms([0.5, -0.5]), 0.5)
    }
}

final class StoreTests: XCTestCase {
    func testRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var older = Meeting(title: "Old", platform: .zoom, startedAt: Date(timeIntervalSince1970: 0))
        older.segments = [TranscriptSegment(start: 0, end: 1, speaker: .remote("Ann"), text: "hi")]
        let newer = Meeting(title: "New", platform: .meet)
        try store.save(older)
        try store.save(newer)
        let all = store.loadAll()
        XCTAssertEqual(all.map(\.title), ["New", "Old"])
        XCTAssertEqual(all[1].segments.first?.speaker, .remote("Ann"))
        try store.delete(newer.id)
        XCTAssertEqual(store.loadAll().count, 1)
    }
}

final class ServerTests: XCTestCase {
    func testParsesRequestsAndRejectsWebOrigins() throws {
        let body = #"{"type":"meeting","platform":"meet","tabId":3,"inMeeting":true,"participants":["Ann"]}"#
        let raw = "POST /v1/event HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nOrigin: \(ExtensionServer.extensionOrigin)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .complete(let request) = HTTPRequest.parse(Data(raw.utf8)) else { return XCTFail("parse") }
        let received = LockedBox<ExtensionEvent?>(nil)
        let server = ExtensionServer(port: 0) { received.value = $0 }
        let response = String(decoding: server.respond(to: request), as: UTF8.self)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(received.value?.participants, ["Ann"])

        var webRequest = request
        webRequest.headers["origin"] = "https://evil.example"
        XCTAssertTrue(String(decoding: server.respond(to: webRequest), as: UTF8.self).hasPrefix("HTTP/1.1 403"))

        guard case .incomplete = HTTPRequest.parse(Data(raw.dropLast(5).utf8)) else { return XCTFail("should wait for body") }

        webRequest.headers["origin"] = "chrome-extension://someotherextensionid"
        XCTAssertTrue(String(decoding: server.respond(to: webRequest), as: UTF8.self).hasPrefix("HTTP/1.1 403"))
        webRequest.headers["origin"] = nil
        XCTAssertTrue(String(decoding: server.respond(to: webRequest), as: UTF8.self).hasPrefix("HTTP/1.1 403"))
    }

    func testHelloReportsVersionWithoutEvent() throws {
        let body = #"{"extensionVersion":"0.2.1"}"#
        let raw = "POST /v1/hello HTTP/1.1\r\nOrigin: \(ExtensionServer.extensionOrigin)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .complete(let request) = HTTPRequest.parse(Data(raw.utf8)) else { return XCTFail("parse") }
        let hello = LockedBox<String?>(nil)
        let events = LockedBox<Int>(0)
        let server = ExtensionServer(port: 0, onHello: { hello.value = $0 }) { _ in events.value += 1 }
        XCTAssertTrue(String(decoding: server.respond(to: request), as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(hello.value, "0.2.1")
        XCTAssertEqual(events.value, 0)

        var webRequest = request
        webRequest.headers["origin"] = "https://evil.example"
        hello.value = nil
        XCTAssertTrue(String(decoding: server.respond(to: webRequest), as: UTF8.self).hasPrefix("HTTP/1.1 403"))
        XCTAssertNil(hello.value)
    }

    func testSnapshotRouteNeedsOurOriginAndAnObject() {
        func request(_ body: String, origin: String? = ExtensionServer.extensionOrigin) -> HTTPRequest {
            let raw = "POST /v1/snapshot HTTP/1.1\r\n" + (origin.map { "Origin: \($0)\r\n" } ?? "") + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
            guard case .complete(let parsed) = HTTPRequest.parse(Data(raw.utf8)) else { fatalError("parse") }
            return parsed
        }
        let saved = LockedBox<Int>(0)
        let server = ExtensionServer(port: 0, onSnapshot: { _ in saved.value += 1 }) { _ in }
        func status(_ r: HTTPRequest) -> String { String(String(decoding: server.respond(to: r), as: UTF8.self).prefix(12)) }
        XCTAssertEqual(status(request(#"{"platform":"slack","snapshot":{}}"#)), "HTTP/1.1 200")
        XCTAssertEqual(status(request("[1]")), "HTTP/1.1 400")
        XCTAssertEqual(status(request("{}", origin: "https://app.slack.com")), "HTTP/1.1 403")
        XCTAssertEqual(status(request("{}", origin: nil)), "HTTP/1.1 403")
        XCTAssertEqual(saved.value, 1)
    }

    func testSnapshotStoreKeepsTheNewest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var store = SnapshotStore(directory: dir)
        store.keep = 2
        for i in 0..<4 { store.save(Data("{}".utf8), platform: i == 3 ? "../zoom" : "slack", now: Date(timeIntervalSince1970: 1_800_000_000 + Double(i))) }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names[1].hasSuffix("-zoom.json"))
        XCTAssertTrue(names[0].hasSuffix("-slack.json"))
    }

    func testRejectsBadContentLength() {
        for length in ["-1", "99999999", "abc"] {
            let raw = "POST /v1/event HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n{}"
            guard case .invalid = HTTPRequest.parse(Data(raw.utf8)) else { return XCTFail("accepted Content-Length \(length)") }
        }
    }

    func testManifestKeyMatchesAllowedOrigin() throws {
        let manifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../extension/manifest.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        let key = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(json["key"] as? String)))
        let id = SHA256.hash(data: key).prefix(16).flatMap { [$0 >> 4, $0 & 0xF] }
            .map { String(UnicodeScalar(UInt8(ascii: "a") + $0)) }.joined()
        XCTAssertEqual("chrome-extension://\(id)", ExtensionServer.extensionOrigin)
    }

    func testLiveServerHealth() async throws {
        let port: UInt16 = 47_899
        let server = ExtensionServer(port: port) { _ in }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"ok\":true"))
    }
}

final class ZoomParsingTests: XCTestCase {
    func testParticipantRows() {
        XCTAssertEqual(ZoomMonitor.parseParticipantRow("Anna Nowak (Host, me), Computer audio muted, Video off")?.name, "Anna Nowak")
        XCTAssertEqual(ZoomMonitor.parseParticipantRow("Anna Nowak (Host, me), Computer audio muted")?.isMe, true)
        XCTAssertEqual(ZoomMonitor.parseParticipantRow("Bob (Guest), Video on")?.isMe, false)
        XCTAssertNil(ZoomMonitor.parseParticipantRow("Participants (3)"))
        XCTAssertNil(ZoomMonitor.parseParticipantRow("Invite"))
        XCTAssertTrue(ZoomMonitor.isMeetingWindowTitle("Zoom Meeting"))
        XCTAssertFalse(ZoomMonitor.isMeetingWindowTitle("Zoom Workplace"))
        XCTAssertTrue(ZoomMonitor.isHomeWindowTitle("Zoom Workplace"))
        XCTAssertFalse(ZoomMonitor.isHomeWindowTitle("Weekly sync with Oliver"))
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class RoundOneFixTests: XCTestCase {
    func testTabTakesOverChromeMicRecording() {
        var detector = MeetingDetector(startDelay: 3, endGrace: 15)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let chrome = MeetingCandidate(key: "app:chrome", platform: .other, title: "Browser call")
        XCTAssertNil(detector.update(candidates: [chrome], now: t0))
        XCTAssertEqual(detector.update(candidates: [chrome], now: t0 + 3), .start(chrome))
        let tab = MeetingCandidate(key: "chrome-tab:7", platform: .meet, title: "Standup", replaces: "app:chrome")
        XCTAssertEqual(detector.update(candidates: [tab], now: t0 + 5), .handOver(tab))
        XCTAssertNil(detector.update(candidates: [tab], now: t0 + 30))
        XCTAssertEqual(detector.active?.key, "chrome-tab:7")
    }

    func testRemovingSegmentsCoveredByChunks() {
        let segments = [
            TranscriptSegment(start: 1, end: 3, speaker: .me, text: "mine early"),
            TranscriptSegment(start: 2, end: 4, speaker: .remote("Ann"), text: "theirs early"),
            TranscriptSegment(start: 35, end: 37, speaker: .me, text: "mine late"),
        ]
        let chunk = AudioChunk(track: .mic, index: 1, url: URL(fileURLWithPath: "/tmp/x.wav"), startOffset: 0, duration: 30, rms: 0.1)
        let kept = TranscriptAssembler.removing(segments, coveredBy: [chunk]).map(\.text)
        XCTAssertEqual(kept, ["theirs early", "mine late"])
    }

    func testWAVDurationAndProcessTimeout() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dur-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try WAVFile.write([Float](repeating: 0, count: 16_000 * 2), sampleRate: 16_000, to: url)
        XCTAssertEqual(WAVFile.duration(of: url), 2, accuracy: 0.001)

        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
    }

    func testEndOffsetTracksBufferedAudio() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("end-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = ChunkWriter(track: .system, directory: directory, trackOffset: 2)
        _ = writer.append([Float](repeating: 0.1, count: 16_000 * 40))
        XCTAssertEqual(writer.endOffset, 42, accuracy: 0.001)
    }
}
