import Foundation
@testable import ChrupioCore
import XCTest

final class SelfNameTests: XCTestCase {
    func testSelfMatchIgnoresAccentsAndCase() {
        XCTAssertTrue(PersonName.same("Łukasz Zurek", "Lukasz Zurek"))
        XCTAssertTrue(PersonName.same("Łukasz Żurek", "lukasz zurek"))
        XCTAssertFalse(PersonName.same("Łukasz Żurek", "Marek"))
        XCTAssertFalse(PersonName.same("Marek", nil))
    }

    func testParsesNamesFromCommasAndLines() {
        XCTAssertEqual(SelfNames.parse("Łukasz Żurek, Lukasz Z.\n\n  ŁŻ "), ["Łukasz Żurek", "Lukasz Z.", "ŁŻ"])
    }

    func testUsualNameIsTheMostFrequent() {
        let meetings = ["Łukasz Żurek", "Łukasz Żurek", "Other", nil].map { Meeting(title: "x", platform: .meet, selfName: $0) }
        XCTAssertEqual(SelfNames.usual(in: meetings), "Łukasz Żurek")
        XCTAssertNil(SelfNames.usual(in: [Meeting(title: "x", platform: .meet)]))
    }

    func testConfiguredNameFillsMissingSelfAndLeavesAttendees() {
        var meeting = Meeting(title: "1:1", platform: .teams, attendees: ["Łukasz Zurek", "Marek", "ŁŻ"])
        meeting.applySelf(["Łukasz Żurek", "ŁŻ"])
        XCTAssertEqual(meeting.selfName, "Łukasz Żurek")
        XCTAssertEqual(meeting.attendees, ["Marek"])
        // A reported self name stays.
        var zoom = Meeting(title: "z", platform: .zoom, attendees: ["Lukasz Zurek (me)"], selfName: "Lukasz Zurek")
        zoom.applySelf(["Łukasz Żurek"])
        XCTAssertEqual(zoom.selfName, "Lukasz Zurek")
    }

    func testMergeAttendeesSkipsSelfAndCleansNames() {
        var meeting = Meeting(title: "x", platform: .teams, selfName: "Łukasz Żurek")
        meeting.mergeAttendees(["Lukasz Zurek", "Marek Unverified", "Marek (Unverified)", "Anna"])
        XCTAssertEqual(meeting.attendees, ["Marek", "Anna"])
    }

    func testSlackSidebarTextIsNotAName() {
        XCTAssertTrue(Meeting.isUIText("View Adam Nowicki's Profile"))
        XCTAssertTrue(Meeting.isUIText("View Adam’s Profile"))
        XCTAssertTrue(Meeting.isUIText("Channels and direct messages"))
        XCTAssertTrue(Meeting.isUIText("Channel team-ops (private)"))
        XCTAssertFalse(Meeting.isUIText("Adam Nowicki"))
    }

    func testSelfFilteredAccentInsensitivelyInAttribution() {
        let events = [SpeakerEvent(time: 1, names: ["Lukasz Zurek", "Marek"], end: 3)]
        let votes = SpeakerAttribution.votes(start: 0, end: 4, events: events, selfName: "Łukasz Żurek")
        XCTAssertEqual(Array(votes.keys), ["Marek"])
        XCTAssertEqual(SpeakerAttribution.remoteSpeaker(start: 10, end: 11, events: [], attendees: ["Łukasz Zurek", "Marek"],
                                                        selfName: "Łukasz Żurek"), "Marek")
    }

    // MARK: - Repair

    private func fixtureStore() throws -> (MeetingStore, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = MeetingStore(root: base.appendingPathComponent("meetings", isDirectory: true))
        var meeting = Meeting(title: "Sync", platform: .teams,
                              attendees: ["Marek Unverified", "Łukasz Zurek", "View Adam Nowicki's Profile", "Channels and direct messages"],
                              segments: [TranscriptSegment(start: 0, end: 1, speaker: .remote("Marek Unverified"), text: "hi"),
                                         TranscriptSegment(start: 1, end: 2, speaker: .me, text: "hello")],
                              summary: MeetingSummary(markdown: "- [ ] Marek Unverified: send the deck", model: "m", createdAt: Date()),
                              status: .done)
        meeting.id = UUID(uuidString: "872422FE-0000-0000-0000-000000000000")!
        try store.writeUnlocked(meeting)
        return (store, base)
    }

    func testRepairBacksUpThenCleansStoredMeetings() throws {
        let (store, base) = try fixtureStore()
        let day = ISO8601DateFormatter().date(from: "2026-10-22T10:00:00Z")!
        let result = try MeetingRepair.run(store: store, selfNames: ["Łukasz Żurek"], now: day)
        XCTAssertEqual(result.backup.lastPathComponent, "meetings-backup-20261022")
        XCTAssertEqual(result.changed, 1)
        let backup = MeetingStore(root: result.backup)
        XCTAssertEqual(try backup.load(UUID(uuidString: "872422FE-0000-0000-0000-000000000000")!).attendees.count, 4)

        let fixed = try store.load(UUID(uuidString: "872422FE-0000-0000-0000-000000000000")!)
        XCTAssertEqual(fixed.attendees, ["Marek", "Adam Nowicki"])
        XCTAssertEqual(fixed.selfName, "Łukasz Żurek")
        XCTAssertEqual(fixed.segments.map(\.speaker.label), ["Marek", "You"])
        XCTAssertEqual(fixed.summary?.markdown, "- [ ] Marek: send the deck")
        // A second run changes nothing.
        XCTAssertEqual(try MeetingRepair.run(store: store, selfNames: ["Łukasz Żurek"], now: day).changed, 0)
        try? FileManager.default.removeItem(at: base)
    }

    func testSlackProfileButtonKeepsTheName() {
        var meeting = Meeting(title: "Huddle", platform: .slack)
        meeting.mergeAttendees(["View Adam Nowicki’s Profile", "View Nina Wolna's Profile", "Channels and direct messages"])
        XCTAssertEqual(meeting.attendees, ["Adam Nowicki", "Nina Wolna"])
    }
}
