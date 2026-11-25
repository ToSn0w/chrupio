import XCTest
@testable import ChrupioCore

final class WhisperBinariesTests: XCTestCase {
    let app = URL(fileURLWithPath: "/Applications/Chrupio.app/Contents/MacOS/Chrupio")
    let mcp = URL(fileURLWithPath: "/Applications/Chrupio.app/Contents/MacOS/chrupio-mcp")

    func testBundledCopyComesFirstForTheAppAndTheMCPHelper() {
        for executable in [app, mcp] {
            let found = WhisperBinaries.find("whisper-cli", executable: executable) { _ in true }
            XCTAssertEqual(found?.path, "/Applications/Chrupio.app/Contents/Helpers/whisper-cli")
            XCTAssertTrue(WhisperBinaries.isBundled(found!, executable: executable))
        }
    }

    func testFallsBackToHomebrew() {
        let found = WhisperBinaries.find("whisper-server", executable: app) { $0 == "/opt/homebrew/bin/whisper-server" }
        XCTAssertEqual(found?.path, "/opt/homebrew/bin/whisper-server")
        XCTAssertFalse(WhisperBinaries.isBundled(found!, executable: app))
        XCTAssertNil(WhisperBinaries.find("whisper-server", executable: app) { _ in false })
    }

    func testOutsideAnAppBundleOnlyHomebrewIsTried() {
        let swiftRun = URL(fileURLWithPath: "/src/chrupio/.build/debug/Chrupio")
        XCTAssertEqual(WhisperBinaries.candidates("whisper-cli", executable: swiftRun).map(\.path),
                       ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"])
    }
}
