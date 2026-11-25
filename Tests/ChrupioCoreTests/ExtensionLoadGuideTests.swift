import Foundation
@testable import ChrupioCore
import XCTest

final class ExtensionLoadGuideTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("load-guide-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ object: [String: Any], _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func profiles(_ names: [String]) throws {
        try write(["profile": ["info_cache": Dictionary(uniqueKeysWithValues: names.map { ($0, ["name": $0]) })]], "Local State")
    }

    func testReportsProfileLoadingDesktopCopy() throws {
        try profiles(["Default", "Profile 1"])
        try write(["extensions": ["settings": ["a": ["path": "/Users/x/Library/Application Support/Chrupio/ChromeExtension"]]]], "Default/Secure Preferences")
        try write(["extensions": ["settings": ["b": ["path": "/Users/x/Desktop/Chrupio Chrome Extension"]]]], "Profile 1/Preferences")
        XCTAssertTrue(ExtensionPackage.anyProfileLoadsLegacyCopy(chromeFolder: root))
    }

    func testNoProfileLoadingDesktopCopy() throws {
        try profiles(["Default"])
        try write(["extensions": ["settings": ["a": ["path": "/Users/x/Library/Application Support/Chrupio/ChromeExtension"]]]], "Default/Secure Preferences")
        XCTAssertFalse(ExtensionPackage.anyProfileLoadsLegacyCopy(chromeFolder: root))
    }

    func testMissingChromeFolderLoadsNothing() {
        XCTAssertFalse(ExtensionPackage.anyProfileLoadsLegacyCopy(chromeFolder: root.appendingPathComponent("none")))
    }

    func testMovedNoticeShownWhenLoadedOrPresent() {
        XCTAssertNil(ExtensionLoadGuide.movedFolderNotice(profileLoadsLegacy: false, legacyExists: false))
        XCTAssertNotNil(ExtensionLoadGuide.movedFolderNotice(profileLoadsLegacy: false, legacyExists: true))
        let loaded = ExtensionLoadGuide.movedFolderNotice(profileLoadsLegacy: true, legacyExists: false)
        XCTAssertNotNil(loaded)
        XCTAssertNotEqual(loaded, ExtensionLoadGuide.movedFolderNotice(profileLoadsLegacy: false, legacyExists: true))
    }

    func testStepsAreInOrderAndNameThePicker() {
        let steps = ExtensionLoadGuide.steps
        XCTAssertEqual(steps.count, 5)
        XCTAssertTrue(steps[0].contains("chrome://extensions"))
        XCTAssertTrue(steps[3].contains("Cmd+Shift+G"))
        XCTAssertFalse((steps + [ExtensionLoadGuide.developerModeNote]).joined().localizedCaseInsensitiveContains("web store"))
    }
}
