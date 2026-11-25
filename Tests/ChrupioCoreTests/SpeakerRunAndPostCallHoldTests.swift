import Foundation
@testable import ChrupioCore
import XCTest

/// Fixes from the 20 Oct critical review that touch the coordinator: post-call work, Zoom scans, speaker events, names.
final class CoordinatorReviewTests: XCTestCase {
    // MARK: - Post-call work waits for the call

    func testNothingTranscribesDuringACall() {
        XCTAssertFalse(PostCallHold.mayTranscribe(recording: true))
        XCTAssertTrue(PostCallHold.mayTranscribe(recording: false))
    }

    func testSummariesAskedDuringACallWaitAndComeBackInOrderOnce() {
        var hold = PostCallHold()
        let first = UUID(), second = UUID(), deleted = UUID()
        XCTAssertFalse(hold.holdSummary(first, recording: false), "with no call the summary runs now")
        XCTAssertTrue(hold.holdSummary(first, recording: true))
        XCTAssertTrue(hold.holdSummary(second, recording: true))
        XCTAssertTrue(hold.holdSummary(first, recording: true), "asking twice holds it once")
        XCTAssertTrue(hold.holdSummary(deleted, recording: true))
        hold.forget(deleted)
        XCTAssertTrue(hold.isHolding(first))
        XCTAssertEqual(hold.release(), [first, second])
        XCTAssertEqual(hold.release(), [], "released summaries are forgotten")
        XCTAssertFalse(hold.isHolding(first))
    }

    // MARK: - Zoom scans

    func testZoomWalksAreCappedAndParsingStillWorks() {
        XCTAssertLessThanOrEqual(ZoomMonitor.maxVisited, 500)
        let row = ZoomMonitor.parseParticipantRow("Anna Nowak (Host, me), Computer audio muted, Video off")
        XCTAssertEqual(row?.name, "Anna Nowak")
        XCTAssertEqual(row?.isMe, true)
        XCTAssertEqual(ZoomMonitor.parseParticipantRow("Bob (Guest")?.name, "Bob", "an unclosed bracket is dropped too")
        XCTAssertEqual(ZoomMonitor.tileName(fromLabel: "Cat Lee (Host), computer audio unmuted"), "Cat Lee")
        XCTAssertNil(ZoomMonitor.tileName(fromLabel: "Cat Lee, Host"))
        XCTAssertEqual(ZoomMonitor.speakerName(fromLabel: "Talking: Anna Nowak (Host)"), "Anna Nowak")
    }

    func testSharedRegularExpressionsParseEveryLabel() {
        let labels = (0..<200).map { $0 % 2 == 0 ? "Person \($0) is talking" : "Person \($0), Video on" }
        XCTAssertEqual(labels.compactMap(ZoomMonitor.speakerName(fromLabel:)).count, 100)
        XCTAssertEqual(labels.compactMap(ZoomMonitor.tileName(fromLabel:)), (0..<100).map { "Person \($0 * 2 + 1)" })
    }

    // MARK: - Speaker events store changes, not heartbeats

    func testHeartbeatsOfTheSameSpeakersExtendOneEvent() {
        var run = SpeakerRun()
        var stored: [SpeakerEvent] = []
        let reports: [(TimeInterval, [String])] = [
            (10, ["Ann"]), (11, ["Ann"]), (12.1, ["Ann"]), (11.9, ["Ann"]), (13, ["Ann"]),
            (14, ["Bob", "Ann"]), (15, ["Ann", "Bob"]),
            (16, ["Ann"]), (25, ["Ann"]),
        ]
        for (time, names) in reports {
            if let finished = run.record(names, at: time) { stored.append(finished) }
        }
        XCTAssertEqual(stored, [
            SpeakerEvent(time: 10, names: ["Ann"], end: 13),
            SpeakerEvent(time: 14, names: ["Bob", "Ann"], end: 15),
            SpeakerEvent(time: 16, names: ["Ann"]),
        ], "a pause longer than the gap starts a new event; order of names doesn't matter")
        XCTAssertEqual(run.close(), SpeakerEvent(time: 25, names: ["Ann"]))
        XCTAssertNil(run.close())
    }

    func testARunVotesLikeTheHeartbeatsItReplaces() {
        let beats = (10...20).map { SpeakerEvent(time: Double($0), names: ["Ann"]) }
        let run = [SpeakerEvent(time: 10, names: ["Ann"], end: 20)]
        for (start, end) in [(9.0, 12.0), (12.0, 18.0), (18.5, 21.0), (25.0, 26.0)] {
            let fromBeats = SpeakerAttribution.votes(start: start, end: end, events: beats, selfName: nil)["Ann"] ?? 0
            let fromRun = SpeakerAttribution.votes(start: start, end: end, events: run, selfName: nil)["Ann"] ?? 0
            // Heartbeats overlap each other by 0.2 s, so they count a little more speech than the run.
            XCTAssertEqual(fromRun, fromBeats, accuracy: 0.25 * fromBeats + 0.01, "\(start)-\(end)")
        }
        var meeting = Meeting(title: "m", platform: .meet, attendees: ["Ann", "Bob"])
        meeting.speakerEvents = run + [SpeakerEvent(time: 30, names: ["Bob"], end: 31)]
        meeting.segments = [
            TranscriptSegment(start: 12, end: 15, speaker: .remote(nil), text: "a"),
            TranscriptSegment(start: 29.5, end: 30.5, speaker: .remote(nil), text: "b"),
        ]
        SpeakerAttribution.apply(to: &meeting)
        XCTAssertEqual(meeting.segments.map(\.speaker.label), ["Ann", "Bob"])
    }

    func testARunConfirmsADiarizedVoiceLikeItsHeartbeats() {
        let lag = SpeakerAttribution.indicatorLag
        let diarization = Diarization(turns: [DiarizedTurn(start: 0, end: 5, cluster: "S1")], centroids: ["S1": [1, 0]])
        var meeting = Meeting(title: "m", platform: .meet, attendees: ["Ann"])
        meeting.speakerEvents = [SpeakerEvent(time: 1 + lag, names: ["Ann"], end: 4 + lag)]
        let outcome = DiarizationNaming.names(for: diarization, meeting: meeting, prints: SpeakerPrints())
        XCTAssertEqual(outcome.names, ["S1": "Ann"])
        XCTAssertEqual(outcome.confirmed, ["S1"], "a 3 s run is several heartbeats, enough to learn the voice")
    }

    func testOldEventsWithoutAnEndStillLoadAndSplitKeepsTheRun() throws {
        let json = "{\"time\":4,\"names\":[\"Ann\"]}"
        let old = try JSONDecoder().decode(SpeakerEvent.self, from: Data(json.utf8))
        XCTAssertEqual(old, SpeakerEvent(time: 4, names: ["Ann"]))
        XCTAssertEqual(old.lastSeen, 4)
        XCTAssertEqual(SpeakerEvent(time: 70, names: ["Ann"], end: 80).shifted(by: -60), SpeakerEvent(time: 10, names: ["Ann"], end: 20))
    }

    // MARK: - Diarization keeps the extension's names

    /// Ann's voice split into S1 and S3 (say after a mic change); Bob is S2.
    private let splitVoice = Diarization(turns: [
        DiarizedTurn(start: 0, end: 5, cluster: "S1"),
        DiarizedTurn(start: 5, end: 10, cluster: "S2"),
        DiarizedTurn(start: 10, end: 20, cluster: "S3"),
    ], centroids: ["S1": [1, 0, 0], "S2": [0, 1, 0], "S3": [0, 0, 1]])

    private func line(_ start: TimeInterval, _ end: TimeInterval, _ speaker: Speaker = .remote(nil)) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, speaker: speaker, text: "\(start)")
    }

    func testLiveNamesSurviveAVoiceSplitInTwo() {
        let lag = SpeakerAttribution.indicatorLag
        var meeting = Meeting(title: "m", platform: .meet, attendees: ["Ann", "Bob", "Cat", "Dan", "Me"], selfName: "Me")
        meeting.speakerEvents = [
            SpeakerEvent(time: 1 + lag, names: ["Ann"], end: 4 + lag),
            SpeakerEvent(time: 6 + lag, names: ["Bob"], end: 9 + lag),
            SpeakerEvent(time: 11 + lag, names: ["Ann"], end: 12 + lag),
        ]
        meeting.segments = [line(1, 4, .remote("Ann")), line(6, 9, .remote("Bob")), line(11, 12, .remote("Ann")),
                            line(15, 18), line(16, 17, .me)]
        let outcome = DiarizationNaming.names(for: splitVoice, meeting: meeting, prints: SpeakerPrints())
        XCTAssertEqual(outcome.names, ["S1": "Ann", "S2": "Bob", "S3": "Speaker 1"], "one name per cluster")
        DiarizationNaming.apply(splitVoice, names: outcome.names, to: &meeting)
        XCTAssertEqual(meeting.segments.map(\.speaker.label), ["Ann", "Bob", "Ann", "Speaker 1", "You"],
                       "the extension's name stays where its events cover the line; the cluster name fills the rest")
    }

    func testOneOtherAttendeeNamesEveryRemoteVoice() {
        var prints = SpeakerPrints()
        prints.learn("Eve", embedding: [0, 0, 1])
        var meeting = Meeting(title: "m", platform: .meet, attendees: ["Ann", "Me"], selfName: "Me")
        meeting.speakerEvents = [SpeakerEvent(time: 2, names: ["Ann"], end: 4)]
        meeting.segments = [line(1, 4), line(6, 9), line(12, 18)]
        let outcome = DiarizationNaming.names(for: splitVoice, meeting: meeting, prints: prints)
        // S3 is Eve's stored voice: someone outside the attendee list joined, so the 1:1 rule doesn't claim it, and Eve,
        // not reported in this meeting, isn't named either.
        XCTAssertEqual(outcome.names, ["S1": "Ann", "S2": "Ann", "S3": "Speaker 1"], "a stored outsider voice blocks the 1:1 rule")
        XCTAssertEqual(outcome.confirmed, ["S1"], "only the cluster the live events named teaches a voice")
        DiarizationNaming.apply(splitVoice, names: outcome.names, to: &meeting)
        XCTAssertEqual(Set(meeting.segments.map(\.speaker.label)), ["Ann", "Speaker 1"])
    }
}
