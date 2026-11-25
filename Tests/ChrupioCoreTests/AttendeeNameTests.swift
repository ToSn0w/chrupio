import XCTest
@testable import ChrupioCore

final class AttendeeNameTests: XCTestCase {
    func testDropsSlugsEmojiCodesAllAndNotetakers() {
        var meeting = Meeting(title: "Huddle", platform: .slack)
        meeting.mergeAttendees(["acme-pl", "raised_hand::skin-tone-2", "All", "Diego's Grain Notetaker",
                                "Fireflies.ai Notetaker Łukasz", "Otter.ai", "Fathom", "Piotr Sadowski"])
        XCTAssertEqual(meeting.attendees, ["Piotr Sadowski"])
    }

    func testKeepsRealNamesThatContainBotWords() {
        var meeting = Meeting(title: "Call", platform: .meet)
        meeting.mergeAttendees(["Harry Potter", "Anna Hart", "Ola Alla"])
        XCTAssertEqual(meeting.attendees, ["Harry Potter", "Anna Hart", "Ola Alla"])
    }

    func testConversationWithKeepsTheName() {
        var meeting = Meeting(title: "Huddle", platform: .slack)
        meeting.mergeAttendees(["Conversation with Piotr Sadowski", "Piotr Sadowski"])
        XCTAssertEqual(meeting.attendees, ["Piotr Sadowski"])
    }

    func testSpellingVariantsAreOnePerson() {
        var meeting = Meeting(title: "Call", platform: .meet)
        meeting.mergeAttendees(["PiotrMazur", "Piotr Mazur", "oliver Grant", "Oliver Grant", "Marek Wrobel", "Marek Wróbel"])
        XCTAssertEqual(meeting.attendees, ["Piotr Mazur", "oliver Grant", "Marek Wrobel"])
    }

    func testKeySplitsCamelCaseAndFoldsAccents() {
        XCTAssertEqual(PersonName.key("PiotrMazur"), PersonName.key("piotr mazur"))
        XCTAssertEqual(PersonName.key("Marek Wrobel"), PersonName.key("Marek Wróbel"))
        XCTAssertEqual(PersonName.key("oliver Grant"), PersonName.key("Oliver Grant"))
    }

    func testCanonicalNameMatchesCamelCaseToRoster() {
        let context = MeetingContext(people: [.init(name: "Piotr Mazur")])
        XCTAssertEqual(context.canonicalName("PiotrMazur"), "Piotr Mazur")
    }
}
