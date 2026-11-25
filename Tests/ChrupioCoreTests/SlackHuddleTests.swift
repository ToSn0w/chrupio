import Foundation
@testable import ChrupioCore
import XCTest

final class CallDiagnosticsTests: XCTestCase {
    func testSnapshotEntryReadsTheCallKey() throws {
        let body = #"{"platform":"slack","tabId":12,"callId":1700000000000,"ts":1,"snapshot":{"v":2,"popOut":false}}"#
        let entry = try XCTUnwrap(CallDiagnostics.snapshotEntry(Data(body.utf8)))
        XCTAssertEqual(entry.key, BrowserMeetingTracker.key(tabId: 12, callId: 1_700_000_000_000))
        XCTAssertEqual(entry.snapshot, .object(["v": .number(2), "popOut": .bool(false)]))
        // Extensions before 0.4.3 sent no tabId.
        XCTAssertNil(CallDiagnostics.snapshotEntry(Data(#"{"platform":"slack","snapshot":{}}"#.utf8))?.key)
        XCTAssertNil(CallDiagnostics.snapshotEntry(Data("nope".utf8)))
    }

    func testKeepsTheNewestProbeAndSnapshotPerCall() {
        var diagnostics = CallDiagnostics()
        diagnostics.limit = 2
        diagnostics.record(probe: .string("a1"), key: "a")
        diagnostics.record(probe: .string("a2"), key: "a")
        diagnostics.record(snapshot: .string("s"), key: "a")
        XCTAssertEqual(diagnostics.entries(for: "a"), ["extension": .string("a2"), "snapshot": .string("s")])
        diagnostics.record(probe: .string("b"), key: "b")
        diagnostics.record(probe: .string("c"), key: "c")
        XCTAssertEqual(diagnostics.entries(for: "a"), [:])
        XCTAssertEqual(diagnostics.entries(for: "c"), ["extension": .string("c")])
    }
}

final class PersonNameTests: XCTestCase {
    let context = MeetingContext(people: [
        MeetingContext.Person(name: "Marek Wróbel", aliases: ["Marek", "Marek K"]),
        MeetingContext.Person(name: "Łukasz Żurek", aliases: ["Lukasz"]),
        MeetingContext.Person(name: "Piotr Sadowski", aliases: ["Piotr"]),
        MeetingContext.Person(name: "Piotr Mazur", aliases: ["Piotr"]),
    ], profiles: [
        MeetingContext.Profile(name: "core", match: ["acme-core"], attendees: ["Marek", "Łukasz Żurek", "marek wrobel", "Zofia"]),
    ])

    func testStripMarkersDropsRoleMarkers() {
        XCTAssertEqual(PersonName.stripMarkers("Marek Unverified"), "Marek")
        XCTAssertEqual(PersonName.stripMarkers("Jane Doe (Guest)"), "Jane Doe")
        XCTAssertEqual(PersonName.stripMarkers("Jane Doe [External] (You)"), "Jane Doe")
        XCTAssertEqual(PersonName.stripMarkers(" Jane (Organizer) "), "Jane")
        XCTAssertEqual(PersonName.stripMarkers("Unverified"), "Unverified")
        XCTAssertEqual(PersonName.stripMarkers("You"), "You")
    }

    func testKeyFoldsCaseDiacriticsAndSpacing() {
        XCTAssertEqual(PersonName.key("Łukasz  Żurek"), PersonName.key("lukasz zurek"))
        XCTAssertNotEqual(PersonName.key("Łukasz"), PersonName.key("Lukas"))
    }

    func testCanonicalNameUsesRosterAndUniqueAliases() {
        XCTAssertEqual(context.canonicalName("Marek Unverified"), "Marek Wróbel")
        XCTAssertEqual(context.canonicalName("marek wrobel (Guest)"), "Marek Wróbel")
        XCTAssertEqual(context.canonicalName("Lukasz"), "Łukasz Żurek")
        // Two people answer to "Piotr": not guessed.
        XCTAssertEqual(context.canonicalName("Piotr"), "Piotr")
        XCTAssertEqual(context.canonicalName("Zofia (External)"), "Zofia")
    }

    func testExpectedAttendeesAreRosterSpelledAndUnique() {
        XCTAssertEqual(context.expectedAttendees(for: "Huddle in team-acme-core"), ["Marek Wróbel", "Łukasz Żurek", "Zofia"])
        XCTAssertEqual(context.expectedAttendees(for: "Weekly"), [])
    }

    func testCanonicalizeNamesRenamesEverywhere() {
        var meeting = Meeting(title: "Huddle", platform: .slack, attendees: ["Marek Unverified", "Marek Wróbel", "Lukasz"],
                              selfName: "Lukasz",
                              segments: [TranscriptSegment(start: 0, end: 1, speaker: .remote("Marek Unverified"), text: "hi")],
                              speakerEvents: [SpeakerEvent(time: 0, names: ["Marek K"])])
        meeting.canonicalizeNames(context.canonicalName)
        XCTAssertEqual(meeting.attendees, ["Marek Wróbel", "Łukasz Żurek"])
        XCTAssertEqual(meeting.selfName, "Łukasz Żurek")
        XCTAssertEqual(meeting.segments[0].speaker, .remote("Marek Wróbel"))
        XCTAssertEqual(meeting.speakerEvents[0].names, ["Marek Wróbel"])
    }

    func testNormalizedMergesPrintsByCount() {
        var prints = SpeakerPrints(people: [
            "Marek Unverified": .init(embedding: [1, 0], count: 1),
            "Marek Wróbel": .init(embedding: [0, 1], count: 3),
        ])
        prints.learnedMeetings = [UUID()]
        let normalized = prints.normalized(context.canonicalName)
        XCTAssertEqual(Array(normalized.people.keys), ["Marek Wróbel"])
        XCTAssertEqual(normalized.people["Marek Wróbel"], .init(embedding: [0.25, 0.75], count: 4))
        XCTAssertEqual(normalized.learnedMeetings, prints.learnedMeetings)
    }
}

final class CandidateNamingTests: XCTestCase {
    /// A unit vector whose cosine with [1, 0] is `c`.
    func voice(_ c: Float) -> [Float] { [c, (1 - c * c).squareRoot()] }

    func names(_ centroids: [String: [Float]], prints: [String: [Float]], expected: [String]? = nil,
               attendees: [String] = ["Ann", "Cid"]) -> [String: String] {
        let turns = centroids.keys.sorted().enumerated().map { DiarizedTurn(start: Double($0.offset) * 10, end: Double($0.offset) * 10 + 5, cluster: $0.element) }
        var meeting = Meeting(title: "Huddle", platform: .slack, attendees: attendees, selfName: "Me")
        meeting.expectedAttendees = expected
        let stored = SpeakerPrints(people: prints.mapValues { .init(embedding: $0, count: 1) })
        return DiarizationNaming.names(for: Diarization(turns: turns, centroids: centroids), meeting: meeting, prints: stored).names
    }

    func testAttendeeNeedsTheAttendeeBar() {
        let prints: [String: [Float]] = ["Ann": [1, 0], "Bob": [0, -1]]
        XCTAssertEqual(names(["A": voice(0.66)], prints: prints), ["A": "Ann"])
        XCTAssertEqual(names(["A": voice(0.58)], prints: prints), ["A": "Speaker 1"])
    }

    func testOutsiderIsNeverNamedEvenOnANearCertainMatch() {
        let prints: [String: [Float]] = ["Bob": [1, 0], "Ann": [0, -1]]
        XCTAssertEqual(names(["A": voice(0.99)], prints: prints, expected: ["Bob"]), ["A": "Speaker 1"])
        XCTAssertEqual(names(["A": voice(0.99)], prints: prints), ["A": "Speaker 1"])
    }

    func testWithoutAttendeesNoStoredVoiceNamesAnyone() {
        XCTAssertEqual(names(["A": voice(0.99)], prints: ["Ann": [1, 0]], attendees: []), ["A": "Speaker 1"])
    }

    func testVoiceCloserToAnOutsiderNamesNobody() {
        let prints: [String: [Float]] = ["Ann": [1, 0, 0], "Bob": [0, 1, 0]]
        XCTAssertEqual(names(["A": [0.65, 0.7, 0.3]], prints: prints, expected: ["Ann"]), ["A": "Speaker 1"])
    }

    func testClosestClusterClaimsAVoiceFirst() {
        let prints: [String: [Float]] = ["Ann": [1, 0]]
        XCTAssertEqual(names(["A": voice(0.66), "B": voice(0.95)], prints: prints, attendees: ["Ann", "Cid", "Dan"]),
                       ["A": "Speaker 1", "B": "Ann"])
    }

    func testAttendeeBarAppliesWithoutContext() {
        let prints: [String: [Float]] = ["Ann": [1, 0], "Bob": [0, -1]]
        XCTAssertEqual(names(["A": voice(0.8)], prints: prints), ["A": "Ann"])
        XCTAssertEqual(names(["A": voice(0.6)], prints: prints), ["A": "Speaker 1"])
    }
}

final class AssignSpeakerTests: XCTestCase {
    func huddle(status: MeetingStatus = .done) -> Meeting {
        var meeting = Meeting(title: "Huddle in project-acme", platform: .slack, attendees: ["Łukasz Żurek"], selfName: "Łukasz Żurek",
                              segments: [
                                  TranscriptSegment(start: 0, end: 2, speaker: .remote("Speaker 2"), text: "a"),
                                  TranscriptSegment(start: 2, end: 4, speaker: .me, text: "b"),
                                  TranscriptSegment(start: 4, end: 6, speaker: .remote("Speaker 2"), text: "c"),
                                  TranscriptSegment(start: 6, end: 8, speaker: .remote("Tomasz Lis"), text: "d"),
                              ], status: status)
        meeting.speakerVoices = ["Speaker 2": [1, 0], "Tomasz Lis": [0, 1]]
        return meeting
    }

    func testRenamesTheLabelsLinesAndMovesItsVoice() throws {
        var meeting = huddle()
        let message = try MeetingEdit.assignSpeaker(speaker: "speaker 2", name: "Marek Wróbel (Guest)").apply(to: &meeting)
        XCTAssertEqual(message, "Named 2 lines of speaker 2 as Marek Wróbel in \"Huddle in project-acme\".")
        XCTAssertEqual(meeting.segments.map(\.speaker.label), ["Marek Wróbel", "You", "Marek Wróbel", "Tomasz Lis"])
        XCTAssertEqual(meeting.speakerVoices, ["Marek Wróbel": [1, 0], "Tomasz Lis": [0, 1]])
        XCTAssertEqual(meeting.attendees, ["Łukasz Żurek", "Marek Wróbel"])
    }

    func testRefusesUnknownLabelsEmptyNamesAndBusyMeetings() {
        var meeting = huddle()
        XCTAssertThrowsError(try MeetingEdit.assignSpeaker(speaker: "Speaker 7", name: "Marek").apply(to: &meeting)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Labels: Speaker 2, Tomasz Lis."), error.localizedDescription)
        }
        XCTAssertThrowsError(try MeetingEdit.assignSpeaker(speaker: "Speaker 2", name: "  ").apply(to: &meeting))
        XCTAssertThrowsError(try MeetingEdit.assignSpeaker(speaker: "Speaker 2", name: "Speaker 3").apply(to: &meeting))
        var busy = huddle(status: .transcribing)
        XCTAssertThrowsError(try MeetingEdit.assignSpeaker(speaker: "Speaker 2", name: "Marek").apply(to: &busy))
        XCTAssertEqual(meeting.segments.map(\.speaker.label), ["Speaker 2", "You", "Speaker 2", "Tomasz Lis"])
    }

    func testNamingDuringASummaryAlsoRenamesTheLabelInTheSummary() throws {
        var meeting = huddle(status: .summarizing)
        meeting.summary = MeetingSummary(markdown: "- [ ] Speaker 2: send the sheet\n- [ ] Speaker 21: review", model: "m", createdAt: Date())
        _ = try MeetingEdit.assignSpeaker(speaker: "speaker 2", name: "Marek Wróbel").apply(to: &meeting)
        XCTAssertEqual(meeting.summary?.markdown, "- [ ] Marek Wróbel: send the sheet\n- [ ] Speaker 21: review")
        XCTAssertEqual(meeting.segments.map(\.speaker.label), ["Marek Wróbel", "You", "Marek Wróbel", "Tomasz Lis"])
    }

    func testLearnAssignmentTeachesTheVoiceUnderTheCanonicalName() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prints-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try SpeakerPrints(people: ["Marek Unverified": .init(embedding: [0, 1], count: 1)]).save(to: url)
        let context = MeetingContext(people: [MeetingContext.Person(name: "Marek Wróbel", aliases: ["Marek"])])
        SpeakerPrints.learnAssignment(.assignSpeaker(speaker: "Speaker 2", name: "Marek"), before: huddle(), at: url, canonical: context.canonicalName)
        let prints = SpeakerPrints.load(from: url)
        XCTAssertEqual(Array(prints.people.keys), ["Marek Wróbel"])
        XCTAssertEqual(prints.people["Marek Wróbel"], .init(embedding: [0.5, 0.5], count: 2))
        // A label without a stored voice teaches nothing.
        SpeakerPrints.learnAssignment(.assignSpeaker(speaker: "Speaker 9", name: "Marek"), before: huddle(), at: url, canonical: context.canonicalName)
        XCTAssertEqual(SpeakerPrints.load(from: url), prints)
    }

    func testVoicesAverageClustersSharingAName() {
        let diarization = Diarization(turns: [], centroids: ["S1": [1, 0], "S2": [0, 1], "S3": [1, 1]])
        XCTAssertEqual(DiarizationNaming.voices(diarization, names: ["S1": "Ann", "S2": "Ann", "S3": "Speaker 1"]),
                       ["Ann": [0.5, 0.5], "Speaker 1": [1, 1]])
    }

    func testCandidatesPutExpectedPeopleFirstWithoutSelfOrSpeakers() {
        var meeting = huddle()
        meeting.expectedAttendees = ["Marek Wróbel", "Łukasz Zurek"]
        XCTAssertEqual(meeting.speakerCandidates(roster: ["Zofia Jabłońska", "marek wrobel"]),
                       ["Marek Wróbel", "Tomasz Lis", "Zofia Jabłońska"])
        XCTAssertTrue(Meeting.isUnnamedSpeaker("Speaker 12"))
        XCTAssertFalse(Meeting.isUnnamedSpeaker("Speaker"))
    }

    func testMCPAssignSpeakerEditsThroughTheEditor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcpa-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let meeting = huddle()
        try store.save(meeting)
        let server = MCPServer(store: store) { id, edit in try store.edit(id, edit).message }
        func call(_ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
            let message: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "assign_speaker", "arguments": arguments]]
            let line = String(data: try JSONSerialization.data(withJSONObject: message), encoding: .utf8)!
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(server.handle(line: line)).utf8)) as? [String: Any])
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            return (content[0]["text"] as? String ?? "", result["isError"] as? Bool ?? false)
        }
        let id = String(meeting.id.uuidString.prefix(8))
        XCTAssertTrue(try call(["meeting_id": id, "speaker": "Speaker 2", "name": "Marek Wróbel"]).text.contains("Named 2 lines"))
        XCTAssertEqual(try store.load(meeting.id).segments[0].speaker, .remote("Marek Wróbel"))
        XCTAssertTrue(try call(["meeting_id": id, "speaker": "Speaker 2", "name": "Marek"]).isError)
        XCTAssertTrue(try call(["meeting_id": id, "speaker": "Speaker 2"]).isError)
    }
}
