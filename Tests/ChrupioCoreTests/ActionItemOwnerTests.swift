import XCTest
@testable import ChrupioCore

final class ActionItemOwnerTests: XCTestCase {
    func meeting() -> Meeting {
        var meeting = Meeting(title: "1:1", platform: .slack, attendees: ["Piotr Sadowski"], selfName: "Łukasz Żurek")
        meeting.segments = [TranscriptSegment(start: 0, end: 60, speaker: .me, text: "Piotr, take the export bug."),
                            TranscriptSegment(start: 60, end: 120, speaker: .remote("Anna Nowak"), text: "I'll review it."),
                            TranscriptSegment(start: 120, end: 180, speaker: .remote("Speaker 8"), text: "Sure.")]
        return meeting
    }

    func owners(_ owners: [String], knownPeople: [String] = []) -> [String] {
        let items = owners.enumerated().map { SummaryActionItem(action: "Distinct task number \($0.offset) about \($0.element)", owner: $0.element, confidence: 0.9) }
        return ActionItemRules.refine(items, meeting: meeting(), knownPeople: knownPeople).map(\.owner)
    }

    func testAttendeesNamedSpeakersSelfAndYouStay() {
        XCTAssertEqual(owners(["Piotr Sadowski", "Anna Nowak", "Łukasz Żurek", "You"]),
                       ["Piotr Sadowski", "Anna Nowak", "Łukasz Żurek", "You"])
    }

    func testUnnamedVoicesBecomeUnassigned() {
        XCTAssertEqual(owners(["Speaker 8", "mówca 3"]), ["Unassigned", "Unassigned"])
    }

    func testPeopleOnlyFromProjectContextBecomeUnassigned() {
        XCTAssertEqual(owners(["Hanna Kubiak", "Gustavo"], knownPeople: ["Hanna Kubiak"]), ["Unassigned", "Unassigned"])
    }

    func testMisspelledAttendeeIsSnappedThenAllowed() {
        XCTAssertEqual(owners(["piotr sadowski", "Sadowski Piot"]).first, "Piotr Sadowski")
    }
}
