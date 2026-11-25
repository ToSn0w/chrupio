import XCTest
@testable import ChrupioCore

final class MeetingTitleTests: XCTestCase {
    func testGenericTitles() {
        for title in ["Browser call", "Zoom", "Zoom meeting", "Recovered recording 27 Oct 15:15", "Slack Huddle", "  zoom  "] {
            XCTAssertTrue(MeetingTitle.isGeneric(title), title)
        }
        for title in ["PRJ daily", "Zoom with Acme", "Browser call review"] {
            XCTAssertFalse(MeetingTitle.isGeneric(title), title)
        }
    }

    func testSuggestedTitleReplacesOnlyAGenericOne() {
        var meeting = Meeting(title: "Browser call", platform: .other)
        meeting.adoptSuggestedTitle("“Przegląd raportów PRJ.”")
        XCTAssertEqual(meeting.title, "Przegląd raportów PRJ")
        // Renamed by the user: kept.
        meeting.adoptSuggestedTitle("Something else")
        XCTAssertEqual(meeting.title, "Przegląd raportów PRJ")
        var other = Meeting(title: "Zoom", platform: .zoom)
        other.adoptSuggestedTitle("Zoom meeting")
        other.adoptSuggestedTitle("  ")
        other.adoptSuggestedTitle(nil)
        XCTAssertEqual(other.title, "Zoom", "a placeholder or empty suggestion changes nothing")
    }

    func testAttendeesFromNamedSpeakers() {
        var meeting = Meeting(title: "Browser call", platform: .other, selfName: "Łukasz Żurek")
        meeting.segments = [
            TranscriptSegment(start: 0, end: 1, speaker: .me, text: "a"),
            TranscriptSegment(start: 1, end: 2, speaker: .remote("Speaker 2"), text: "b"),
            TranscriptSegment(start: 2, end: 3, speaker: .remote("Marek Unverified"), text: "c"),
            TranscriptSegment(start: 3, end: 4, speaker: .remote(nil), text: "d"),
            TranscriptSegment(start: 4, end: 5, speaker: .remote("Others"), text: "e"),
            TranscriptSegment(start: 5, end: 6, speaker: .remote("Anna Nowak (Guest)"), text: "f"),
            TranscriptSegment(start: 6, end: 7, speaker: .remote("Łukasz Żurek"), text: "g"),
            TranscriptSegment(start: 7, end: 8, speaker: .remote("Marek"), text: "h"),
        ]
        meeting.fillAttendeesFromSpeakers()
        XCTAssertEqual(meeting.attendees, ["Marek", "Anna Nowak"])
        // Attendees the call reported are left alone.
        var reported = meeting
        reported.attendees = ["Jan"]
        reported.fillAttendeesFromSpeakers()
        XCTAssertEqual(reported.attendees, ["Jan"])
    }
}
