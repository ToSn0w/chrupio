@testable import ChrupioCore
import XCTest

final class PlatformTagTests: XCTestCase {
    func testEveryPlatformHasAShortUpperCaseTag() {
        XCTAssertEqual(Platform.allCases.map(\.tag), ["MEET", "TEAMS", "SLACK", "ZOOM", "CALL"])
        for platform in Platform.allCases {
            XCTAssertEqual(platform.tag, platform.tag.uppercased())
            XCTAssertLessThanOrEqual(platform.tag.count, 5, "fits the fixed-width tag box")
        }
    }
}
