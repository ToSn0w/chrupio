@testable import ChrupioCore
import XCTest

final class TicketGroundingTests: XCTestCase {
    func testAKeyWhoseDigitsWereSaidIsGrounded() {
        let transcript = "You: zamknąłem PRJ 2,366 i ticket 24 19 wczoraj"
        XCTAssertEqual(TicketGrounding.ungrounded(in: "- PRJ-2366 done\n- PRJ-2419 open", transcript: transcript, prefix: "PRJ"), [])
    }

    func testAKeyNeverSaidIsReportedOnce() {
        let transcript = "You: zamknąłem PRJ 2366"
        XCTAssertEqual(TicketGrounding.ungrounded(in: "PRJ-2366, PRJ-5120 and again PRJ-5120", transcript: transcript, prefix: "PRJ"), ["PRJ-5120"])
    }

    func testWarningTextListsTheKeys() {
        XCTAssertNil(TicketGrounding.warning(for: []))
        XCTAssertEqual(TicketGrounding.warning(for: ["PRJ-1", "PRJ-2"]), "Ticket keys not heard in the transcript: PRJ-1, PRJ-2")
    }

    func testDigitsMustMatchAWholeRun() {
        XCTAssertEqual(TicketGrounding.ungrounded(in: "PRJ-123", transcript: "You: budżet 4123 złotych", prefix: "PRJ"), ["PRJ-123"])
        XCTAssertEqual(TicketGrounding.ungrounded(in: "PRJ-123", transcript: "You: ticket 1234", prefix: "PRJ"), ["PRJ-123"])
        XCTAssertEqual(TicketGrounding.ungrounded(in: "PRJ-123", transcript: "You: ticket 123", prefix: "PRJ"), [])
    }

    func testDigitsOfAdjacentLinesAreNotMerged() {
        let transcript = "[00:00:01] You: mamy 24\n[00:00:09] Anna Nowak: 19 osób"
        XCTAssertEqual(TicketGrounding.ungrounded(in: "PRJ-2419", transcript: transcript, prefix: "PRJ"), ["PRJ-2419"])
        XCTAssertEqual(TicketGrounding.ungrounded(in: "PRJ-2419", transcript: "You: mamy 24\n19 osób", prefix: "PRJ"), ["PRJ-2419"])
    }

    func testTimestampsDoNotGroundAKey() {
        XCTAssertEqual(TicketGrounding.ungrounded(in: "PRJ-12", transcript: "[00:12:34] You: dzień dobry", prefix: "PRJ"), ["PRJ-12"])
    }

    func testOtherPrefixesAndNoPrefixAreIgnored() {
        XCTAssertEqual(TicketGrounding.ungrounded(in: "ABC-5120 and PRJ-5120", transcript: "You: hi", prefix: "PRJ"), ["PRJ-5120"])
        XCTAssertEqual(TicketGrounding.ungrounded(in: "PRJ-5120", transcript: "You: hi", prefix: nil), [])
    }
}
