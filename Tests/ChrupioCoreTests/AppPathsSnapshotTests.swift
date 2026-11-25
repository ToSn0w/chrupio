import XCTest
@testable import ChrupioCore

/// CHRUPIO_SUPPORT_DIR moves the support folder only in the app's snapshot run, and chrupio-mcp refuses that run.
final class AppPathsSnapshotTests: XCTestCase {
    func testSupportDirIgnoredOutsideSnapshotRun() {
        XCTAssertNil(AppPaths.customSupport(environment: ["CHRUPIO_SUPPORT_DIR": "/tmp/x"]))
    }

    func testSupportDirHonouredInSnapshotRun() {
        let url = AppPaths.customSupport(environment: ["CHRUPIO_SUPPORT_DIR": "/tmp/x", "CHRUPIO_SNAPSHOT_DIR": "/tmp/s"])
        XCTAssertEqual(url?.path, "/tmp/x")
        XCTAssertNil(AppPaths.customSupport(environment: ["CHRUPIO_SUPPORT_DIR": "", "CHRUPIO_SNAPSHOT_DIR": "/tmp/s"]))
    }

    func testHelperRefusesSnapshotRun() {
        XCTAssertNil(AppPaths.helperRefusal(environment: [:]))
        XCTAssertNil(AppPaths.helperRefusal(environment: ["CHRUPIO_SUPPORT_DIR": "/tmp/x"]))
        let message = AppPaths.helperRefusal(environment: ["CHRUPIO_SNAPSHOT_DIR": "/tmp/s", "CHRUPIO_SUPPORT_DIR": "/tmp/x"])
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("CHRUPIO_SNAPSHOT_DIR") ?? false)
        XCTAssertTrue(message?.contains("Nothing was changed") ?? false)
    }
}
