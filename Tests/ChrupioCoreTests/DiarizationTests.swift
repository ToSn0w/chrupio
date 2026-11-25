import Foundation
@testable import ChrupioCore
import XCTest

final class DiarizationTests: XCTestCase {
    private let ann: [Float] = [1, 0, 0], bob: [Float] = [0, 1, 0]

    private func diarization() -> Diarization {
        Diarization(turns: [
            DiarizedTurn(start: 0, end: 5, cluster: "S1"),
            DiarizedTurn(start: 5, end: 10, cluster: "S2"),
            DiarizedTurn(start: 10, end: 15, cluster: "S1"),
        ], centroids: ["S1": ann, "S2": bob])
    }

    func testClusterByOverlapAndNearest() {
        let d = diarization()
        XCTAssertEqual(d.cluster(start: 3, end: 9), "S2")
        XCTAssertEqual(d.cluster(start: 4, end: 6), "S1", "a tie goes to the first cluster name")
        XCTAssertNil(d.cluster(start: 20, end: 21))
        XCTAssertEqual(d.nearestCluster(start: 16, end: 17), "S1")
        XCTAssertNil(d.nearestCluster(start: 18, end: 19))
    }

    func testLiveEventsNameClustersAndConfirmThem() {
        var meeting = Meeting(title: "m", platform: .meet, attendees: ["Ann", "Bob", "Me"], selfName: "Me")
        let lag = SpeakerAttribution.indicatorLag
        meeting.speakerEvents = [1, 2, 3, 11].map { SpeakerEvent(time: $0 + lag, names: ["Ann"]) }
            + [SpeakerEvent(time: 6 + lag, names: ["Bob", "Me"])]
        let outcome = DiarizationNaming.names(for: diarization(), meeting: meeting, prints: SpeakerPrints())
        XCTAssertEqual(outcome.names, ["S1": "Ann", "S2": "Bob"])
        XCTAssertEqual(outcome.confirmed, ["S1"], "one event isn't enough to learn Bob's voice")
    }

    func testStoredVoicesThenLastAttendeeThenNumbers() {
        var prints = SpeakerPrints()
        prints.learn("Bob", embedding: [0, 0.9, 0.1])
        let meeting = Meeting(title: "m", platform: .meet, attendees: ["Bob", "Cat"])
        XCTAssertEqual(DiarizationNaming.names(for: diarization(), meeting: meeting, prints: prints).names, ["S1": "Cat", "S2": "Bob"])

        let strangers = Meeting(title: "m", platform: .meet)
        XCTAssertEqual(DiarizationNaming.names(for: diarization(), meeting: strangers, prints: SpeakerPrints()).names,
                       ["S1": "Speaker 1", "S2": "Speaker 2"])
    }

    func testCloseRunnerUpNamesNobody() {
        var prints = SpeakerPrints()
        prints.learn("Ann", embedding: [1, 0.1, 0])
        prints.learn("Eve", embedding: [1, 0.12, 0])
        XCTAssertNil(prints.closest(to: ann, attendees: [], excluding: []))
        XCTAssertEqual(prints.closest(to: ann, attendees: [], excluding: ["eve"]), "Ann")
    }

    func testApplySplitsRemoteLinesAndLeavesMine() {
        var meeting = Meeting(title: "m", platform: .meet)
        let words = (0..<10).map { TimedWord(start: Double($0) + 1, end: Double($0) + 1.5, text: "w\($0)") }
        meeting.segments = [
            TranscriptSegment(start: 1, end: 10.5, speaker: .remote("Ann"), text: "x", words: words),
            TranscriptSegment(start: 2, end: 3, speaker: .me, text: "mine"),
            TranscriptSegment(start: 16, end: 17, speaker: .remote(nil), text: "late"),
        ]
        DiarizationNaming.apply(diarization(), names: ["S1": "Ann", "S2": "Bob"], to: &meeting)
        XCTAssertEqual(meeting.segments.map(\.speaker.label), ["Ann", "Bob", "You", "Ann"])
        XCTAssertEqual(meeting.segments[1].text, "w4 w5 w6 w7 w8 w9", "a half-second tail joins its neighbour")
    }

    func testBriefLiveEventDoesNotRelabelAnotherVoice() {
        let lag = SpeakerAttribution.indicatorLag
        var meeting = Meeting(title: "m", platform: .meet)
        // Bob's indicator lingers 0.3 s into Ann's 5 s turn (S1, 10-15).
        meeting.speakerEvents = [SpeakerEvent(time: 9.5 + lag, names: ["Bob"], end: 10.3 + lag)]
        meeting.segments = [TranscriptSegment(start: 10, end: 15, speaker: .remote(nil), text: "x")]
        DiarizationNaming.apply(diarization(), names: ["S1": "Ann", "S2": "Bob"], to: &meeting)
        XCTAssertEqual(meeting.segments.map(\.speaker.label), ["Ann"])
    }

    func testLiveNameCoveringMostOfAPartWins() {
        let lag = SpeakerAttribution.indicatorLag
        var meeting = Meeting(title: "m", platform: .meet)
        meeting.speakerEvents = [SpeakerEvent(time: 10 + lag, names: ["Cat"], end: 13 + lag)]
        meeting.segments = [TranscriptSegment(start: 10, end: 15, speaker: .remote(nil), text: "x")]
        DiarizationNaming.apply(diarization(), names: ["S1": "Ann", "S2": "Bob"], to: &meeting)
        XCTAssertEqual(meeting.segments.map(\.speaker.label), ["Cat"])
    }

    func testLiveSpeakerReportsCoverage() {
        let lag = SpeakerAttribution.indicatorLag
        let events = [SpeakerEvent(time: 1 + lag, names: ["Ann"], end: 3 + lag)]
        let live = SpeakerAttribution.liveSpeakerCoverage(start: 0, end: 10, events: events, selfName: nil, lookAhead: false)
        XCTAssertEqual(live?.name, "Ann")
        XCTAssertGreaterThan(live?.seconds ?? 0, 1.5)
        XCTAssertLessThan(live?.seconds ?? 99, 5)
    }

    func testThirdVoiceMatchedBeforeOneToOneRule() {
        var prints = SpeakerPrints()
        prints.learn("Eve", embedding: [0, 0.95, 0.05])
        var meeting = Meeting(title: "m", platform: .meet, attendees: ["Ann", "Me"], selfName: "Me")
        meeting.speakerEvents = [SpeakerEvent(time: 2, names: ["Ann"], end: 4)]
        XCTAssertEqual(DiarizationNaming.names(for: diarization(), meeting: meeting, prints: prints).names,
                       ["S1": "Ann", "S2": "Speaker 1"], "a voice that is someone outside the meeting is neither them nor the attendee")
    }

    func testStoredVoiceOfSomeoneNotInTheMeetingNamesNobody() {
        var prints = SpeakerPrints()
        prints.learn("Eve Outsider", embedding: [0, 0.99, 0.01])
        prints.learn("Ann Inside", embedding: [0.98, 0.02, 0])
        let meeting = Meeting(title: "huddle", platform: .slack, attendees: ["Ann Inside", "Cat Inside", "Dan Inside", "Me"], selfName: "Me")
        XCTAssertEqual(DiarizationNaming.names(for: diarization(), meeting: meeting, prints: prints).names,
                       ["S1": "Ann Inside", "S2": "Speaker 1"])
    }

    func testPrintSpelledDifferentlyNamesTheAttendeeAsReported() {
        var prints = SpeakerPrints()
        prints.learn("Łukasz Żółć", embedding: [0, 1, 0])
        prints.learn("Anna-Maria Wiśniewska", embedding: [1, 0, 0])
        let meeting = Meeting(title: "huddle", platform: .slack,
                              attendees: ["LUKASZ  ZOLC", "Anna Maria Wisniewska.", "Ola Inna", "Me"], selfName: "Me")
        XCTAssertEqual(DiarizationNaming.names(for: diarization(), meeting: meeting, prints: prints).names,
                       ["S1": "Anna Maria Wisniewska.", "S2": "LUKASZ  ZOLC"])
    }

    func testTwoPrintsWithOneSpellingKeyNameNobody() {
        var prints = SpeakerPrints()
        prints.learn("Łukasz Żółć", embedding: [0, 1, 0])
        prints.learn("Lukasz Zolc", embedding: [0, 0, 1])
        let meeting = Meeting(title: "huddle", platform: .slack, attendees: ["Lukasz Zolc", "Ola Inna", "Ewa Inna", "Me"], selfName: "Me")
        XCTAssertEqual(DiarizationNaming.names(for: diarization(), meeting: meeting, prints: prints).names["S2"], "Speaker 2")
    }

    func testPersonNameKeyFoldsPolishLettersAndPunctuation() {
        XCTAssertEqual(PersonName.key("ŁUKASZ Żółć"), PersonName.key("lukasz zolc"))
        XCTAssertEqual(PersonName.key("Anna-Maria Wiśniewska."), PersonName.key("Anna Maria  Wisniewska"))
    }

    func testOutsiderNeverNamedEvenWhenContextExpectsThem() {
        var prints = SpeakerPrints()
        prints.learn("Eve Expected", embedding: [0, 1, 0])
        var meeting = Meeting(title: "huddle", platform: .slack, attendees: ["Ann Inside", "Cat Inside", "Me"], selfName: "Me")
        meeting.expectedAttendees = ["Eve Expected"]
        XCTAssertEqual(DiarizationNaming.names(for: diarization(), meeting: meeting, prints: prints).names["S2"], "Speaker 2")
    }

    func testOneToOneRuleSkipsManyDissimilarVoices() {
        let d = Diarization(turns: (0..<3).map { DiarizedTurn(start: Double($0) * 5, end: Double($0) * 5 + 5, cluster: "S\($0 + 1)") },
                            centroids: ["S1": [1, 0, 0], "S2": [0, 1, 0], "S3": [0, 0, 1]])
        let meeting = Meeting(title: "m", platform: .meet, attendees: ["Ann", "Me"], selfName: "Me")
        XCTAssertEqual(DiarizationNaming.names(for: d, meeting: meeting, prints: SpeakerPrints()).names,
                       ["S1": "Speaker 1", "S2": "Speaker 2", "S3": "Speaker 3"])
        let alike = Diarization(turns: d.turns, centroids: ["S1": [1, 0, 0], "S2": [0.9, 0.1, 0], "S3": [0.95, 0, 0.1]])
        XCTAssertEqual(DiarizationNaming.names(for: alike, meeting: meeting, prints: SpeakerPrints()).names,
                       ["S1": "Ann", "S2": "Ann", "S3": "Ann"])
    }

    func testOneToOneRuleSkipsTwoDissimilarVoices() {
        let d = Diarization(turns: [DiarizedTurn(start: 0, end: 5, cluster: "S1"), DiarizedTurn(start: 5, end: 10, cluster: "S2")],
                            centroids: ["S1": [1, 0, 0], "S2": [0, 1, 0]])
        let meeting = Meeting(title: "m", platform: .meet, attendees: ["Ann", "Me"], selfName: "Me")
        XCTAssertEqual(DiarizationNaming.names(for: d, meeting: meeting, prints: SpeakerPrints()).names,
                       ["S1": "Speaker 1", "S2": "Speaker 2"], "two different voices are not both the one attendee")
        let alike = Diarization(turns: d.turns, centroids: ["S1": [1, 0, 0], "S2": [0.9, 0.1, 0]])
        XCTAssertEqual(DiarizationNaming.names(for: alike, meeting: meeting, prints: SpeakerPrints()).names,
                       ["S1": "Ann", "S2": "Ann"])
        let one = Diarization(turns: [d.turns[0]], centroids: ["S1": [1, 0, 0]])
        XCTAssertEqual(DiarizationNaming.names(for: one, meeting: meeting, prints: SpeakerPrints()).names, ["S1": "Ann"])
    }

    func testLearnsOncePerMeeting() {
        let outcome = DiarizationNaming.Outcome(names: ["S1": "Ann", "S2": "Bob"], confirmed: ["S1"])
        var prints = SpeakerPrints()
        let id = UUID()
        DiarizationNaming.learn(outcome, diarization: diarization(), meetingID: id, into: &prints)
        DiarizationNaming.learn(outcome, diarization: diarization(), meetingID: id, into: &prints)
        XCTAssertEqual(prints.people.keys.sorted(), ["Ann"])
        XCTAssertEqual(prints.people["Ann"]?.count, 1)
    }

    func testTimelinePlacesChunksAtTheirOffsets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tl-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rate = 100
        func chunk(_ index: Int, start: Double, value: Float) throws -> AudioChunk {
            let url = directory.appendingPathComponent("system-\(index).wav")
            try WAVFile.write([Float](repeating: value, count: rate), sampleRate: rate, to: url)
            return AudioChunk(track: .system, index: index, url: url, startOffset: start, duration: 1, rms: value)
        }
        let out = directory.appendingPathComponent("timeline.wav")
        let length = try WAVFile.writeTimeline([try chunk(2, start: 3, value: 0.5), try chunk(1, start: 0, value: 0.25)], sampleRate: rate, to: out)
        XCTAssertEqual(length, 4)
        let samples = try WAVFile.read(out)
        XCTAssertEqual(samples.count, 4 * rate)
        XCTAssertEqual(samples[50], 0.25, accuracy: 0.001)
        XCTAssertEqual(samples[150], 0)
        XCTAssertEqual(samples[350], 0.5, accuracy: 0.001)
    }
}

final class EchoReferenceTests: XCTestCase {
    func testLinesUpSystemAudioWithTheMicChunk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("er-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rate = 100
        func chunk(_ track: AudioChunk.Track, _ index: Int, start: Double, seconds: Int, value: Float) throws -> AudioChunk {
            let url = directory.appendingPathComponent("\(track.rawValue)-\(index).wav")
            try WAVFile.write([Float](repeating: value, count: seconds * rate), sampleRate: rate, to: url)
            return AudioChunk(track: track, index: index, url: url, startOffset: start, duration: Double(seconds), rms: value)
        }
        let mic = try chunk(.mic, 1, start: 2, seconds: 4, value: 0.1)
        let system = [try chunk(.system, 1, start: 0, seconds: 3, value: 0.2), try chunk(.system, 2, start: 5, seconds: 3, value: 0.4)]
        let reference = try XCTUnwrap(EchoReference.samples(for: mic, system: system, sampleRate: rate))
        XCTAssertEqual(reference.count, 400)
        XCTAssertEqual(reference[50], 0.2, accuracy: 0.001)
        XCTAssertEqual(reference[150], 0, "a gap between system chunks stays silent")
        XCTAssertEqual(reference[350], 0.4, accuracy: 0.001)

        let quiet = [try chunk(.system, 3, start: 2, seconds: 4, value: 0.001)]
        XCTAssertNil(EchoReference.samples(for: mic, system: quiet, sampleRate: rate), "silent call audio leaves the mic alone")
    }
}
