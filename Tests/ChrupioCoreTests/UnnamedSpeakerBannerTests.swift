import XCTest
@testable import ChrupioCore

final class UnnamedSpeakerBannerTests: XCTestCase {
    func meeting(owners: [String], speakers: [String?]) -> Meeting {
        var meeting = Meeting(title: "Sync", platform: .meet, attendees: [], selfName: "Łukasz Żurek")
        meeting.segments = speakers.enumerated().map { index, label in
            TranscriptSegment(start: Double(index) * 10, end: Double(index) * 10 + 5, speaker: label.map { .remote($0) } ?? .me, text: "Line \(index)")
        }
        meeting.summary = MeetingSummary(markdown: "", model: "claude", actionItems: owners.map {
            SummaryActionItem(action: "Do the thing for \($0)", owner: $0, confidence: 0.9)
        })
        return meeting
    }

    func testUnassignedItemWithUnnamedVoicesListsThemOnce() {
        let speakers = meeting(owners: ["Unassigned", "Anna Nowak"], speakers: [nil, "Speaker 2", "Anna Nowak", "Speaker 1", "Speaker 2"])
            .unnamedSpeakersBlockingOwners
        XCTAssertEqual(speakers, ["Speaker 2", "Speaker 1"])
    }

    func testNoBannerWhenEveryItemHasAnOwner() {
        XCTAssertEqual(meeting(owners: ["Anna Nowak"], speakers: ["Speaker 2"]).unnamedSpeakersBlockingOwners, [])
    }

    func testNoBannerWhenEveryVoiceIsNamed() {
        XCTAssertEqual(meeting(owners: ["Unassigned"], speakers: [nil, "Anna Nowak"]).unnamedSpeakersBlockingOwners, [])
    }

    func testNoBannerWithoutSummary() {
        var plain = meeting(owners: ["Unassigned"], speakers: ["Speaker 2"])
        plain.summary = nil
        XCTAssertEqual(plain.unnamedSpeakersBlockingOwners, [])
    }

    func testFreeTextSummaryChecksMarkdown() {
        var plain = meeting(owners: [], speakers: ["Speaker 3"])
        plain.summary = MeetingSummary(markdown: "- [ ] Unassigned: Send the deck", model: "claude")
        XCTAssertEqual(plain.unnamedSpeakersBlockingOwners, ["Speaker 3"])
    }
}
