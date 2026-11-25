import XCTest
import ApplicationServices
@testable import ChrupioCore

final class ZoomWindowSelectionTests: XCTestCase {
    func ax(_ title: String?, _ subrole: String? = nil) -> ZoomMonitor.WindowInfo {
        .init(source: "ax", title: title, role: kAXWindowRole as String, subrole: subrole)
    }

    func testMeetingTitleWins() {
        let windows = [ax("Zoom Workplace"), ax("Zoom Meeting", kAXStandardWindowSubrole as String), ax("x")]
        XCTAssertEqual(ZoomMonitor.labelWindows(windows), [1])
    }

    func testSingleStandardWindowIsTaken() {
        let windows = [ax("Zoom Workplace", kAXStandardWindowSubrole as String),
                       ax("Weekly sync", kAXStandardWindowSubrole as String), ax("", "AXFloatingWindow")]
        XCTAssertEqual(ZoomMonitor.labelWindows(windows), [1])
    }

    func testAmbiguousFallsBackToAllButHome() {
        let windows = [ax("Zoom Workplace"), ax("A", kAXStandardWindowSubrole as String),
                       ax("B", kAXStandardWindowSubrole as String)]
        XCTAssertEqual(ZoomMonitor.labelWindows(windows), [1, 2])
    }
}
