@testable import ChrupioCore
import XCTest

final class ActionItemDatesTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let start = ISO8601DateFormatter().date(from: "2026-11-12T10:00:00Z")!

    func testHeaderLineNamesTheDateAndWeekday() {
        XCTAssertEqual(ActionItemDates.headerLine(start, timeZone: utc), "Date: 2026-11-12 (Thursday)\n")
    }

    func testKeepsADateOnOrAfterTheMeetingDay() {
        XCTAssertEqual(ActionItemDates.valid("2026-11-12", meetingStart: start, timeZone: utc), "2026-11-12")
        XCTAssertEqual(ActionItemDates.valid(" 2026-11-13 ", meetingStart: start, timeZone: utc), "2026-11-13")
    }

    func testDropsPastFarAndMalformedDates() {
        XCTAssertNil(ActionItemDates.valid("2026-11-11", meetingStart: start, timeZone: utc))
        XCTAssertNil(ActionItemDates.valid("2027-11-14", meetingStart: start, timeZone: utc))
        XCTAssertNil(ActionItemDates.valid("piątek", meetingStart: start, timeZone: utc))
        XCTAssertNil(ActionItemDates.valid("2026-02-30", meetingStart: start, timeZone: utc))
        XCTAssertNil(ActionItemDates.valid(nil, meetingStart: start, timeZone: utc))
    }

    func testTranscriptHeaderCarriesTheMeetingDate() {
        var meeting = Meeting(title: "Sync", platform: .meet, attendees: ["Anna Nowak"], status: .done)
        meeting.startedAt = start
        XCTAssertTrue(Prompts.header(meeting).hasPrefix("Meeting: Sync (\(meeting.platform.displayName))\n" + ActionItemDates.headerLine(start)))
    }

    func testRefineKeepsAValidDeadlineDateDropsAnInvalidOneAndMergesDuplicates() {
        var meeting = Meeting(title: "Sync", platform: .meet, attendees: ["Anna Nowak"], status: .done)
        meeting.startedAt = start
        meeting.segments = (0..<12).map {
            TranscriptSegment(start: TimeInterval($0 * 10), end: TimeInterval($0 * 10 + 8), speaker: .remote("Anna Nowak"),
                              text: "Line \($0) about the release plan and the billing page for the quarter.")
        }
        let items = [
            SummaryActionItem(action: "Send the deck", owner: "Anna Nowak", deadline: "Friday", deadlineDate: "2026-11-13"),
            SummaryActionItem(action: "Fix the build", owner: "Anna Nowak", deadlineDate: "2020-01-01"),
            SummaryActionItem(action: "Send the deck", owner: "Anna Nowak", deadlineDate: nil),
        ]
        let kept = ActionItemRules.refine(items, meeting: meeting, knownPeople: [])
        XCTAssertEqual(kept.map(\.deadlineDate), ["2026-11-13", nil])
    }

    func testPromptsAskForTheDeadlineDate() {
        XCTAssertTrue(ClaudePrompts.system.contains("\"deadline_date\""))
        XCTAssertTrue(Prompts.actionItemsRule.contains("\"deadline_date\""))
    }
}
