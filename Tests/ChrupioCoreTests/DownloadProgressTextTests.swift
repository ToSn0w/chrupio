@testable import ChrupioCore
import XCTest

final class DownloadProgressTextTests: XCTestCase {
    func testMockupExample() {
        XCTAssertEqual(DownloadProgressText.text(completed: 303_000_000, total: 488_000_000), "62% · 303/488 MB")
    }

    func testPercentRoundsDownSoItNeverShowsDoneEarly() {
        XCTAssertEqual(DownloadProgressText.text(completed: 487_900_000, total: 488_000_000), "99% · 488/488 MB")
        XCTAssertEqual(DownloadProgressText.text(completed: 488_000_000, total: 488_000_000), "100% · 488/488 MB")
    }

    func testStartAndOvershoot() {
        XCTAssertEqual(DownloadProgressText.text(completed: 0, total: 488_000_000), "0% · 0/488 MB")
        XCTAssertEqual(DownloadProgressText.text(completed: 500_000_000, total: 488_000_000), "100% · 500/488 MB")
    }

    func testUnknownTotalShowsOnlyTheBytes() {
        XCTAssertEqual(DownloadProgressText.text(completed: 5_400_000, total: -1), "5 MB")
        XCTAssertEqual(DownloadProgressText.text(completed: 5_400_000, total: 0), "5 MB")
    }

    func testLargeModelStaysInMegabytes() {
        XCTAssertEqual(DownloadProgressText.text(completed: 774_000_000, total: 1_550_000_000), "49% · 774/1550 MB")
    }

    func testExactPercentIsNotLostToFloatingPoint() {
        XCTAssertEqual(DownloadProgressText.text(completed: 29, total: 100), "29% · 0/0 MB")
    }

    func testNegativeCompletedClampsToZero() {
        XCTAssertEqual(DownloadProgressText.text(completed: -5, total: 100), "0% · 0/0 MB")
    }

    func testZeroCompletedWithUnknownTotal() {
        XCTAssertEqual(DownloadProgressText.text(completed: 0, total: -1), "0 MB")
    }

    func testMegabytesRoundToNearest() {
        XCTAssertEqual(DownloadProgressText.text(completed: 999_999, total: 0), "1 MB")
        XCTAssertEqual(DownloadProgressText.text(completed: 499_999, total: 0), "0 MB")
    }
}
