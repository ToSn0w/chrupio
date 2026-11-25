import XCTest
@testable import ChrupioCore

final class UserHomeTests: XCTestCase {
    func testSnapshotRunNeverUsesTheRealHome() throws {
        let real = FileManager.default.homeDirectoryForCurrentUser
        let fake = UserHome.resolve(environment: ["CHRUPIO_SNAPSHOT_DIR": "/nonexistent"], real: real)
        defer { try? FileManager.default.removeItem(at: fake) }
        XCTAssertNotEqual(fake.standardizedFileURL.path, real.standardizedFileURL.path)
        XCTAssertFalse(fake.path.hasPrefix(real.path + "/"))
        // A fresh empty folder: no Chrome profiles and no Desktop copy to read.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fake.path), [])
        let chrome = ExtensionPackage.chromeFolder(home: fake)
        XCTAssertTrue(chrome.path.hasPrefix(fake.path + "/"))
        XCTAssertEqual(ExtensionPackage.chromeProfilesWithoutExtension(chromeFolder: chrome), [])
        XCTAssertFalse(ExtensionPackage.hasLegacyDesktopCopy(home: fake))
    }

    func testNormalRunUsesTheRealHome() {
        let real = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        XCTAssertEqual(UserHome.resolve(environment: [:], real: real), real)
    }

    func testDisplayWritesHomeAsTilde() {
        let home = URL(fileURLWithPath: "/var/x/home", isDirectory: true)
        XCTAssertEqual(UserHome.display("/var/x/home/Chrupio Notes", home: home), "~/Chrupio Notes")
        XCTAssertEqual(UserHome.display("/var/x/homeother", home: home), "/var/x/homeother")
    }
}
