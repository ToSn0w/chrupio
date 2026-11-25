import Foundation
@testable import ChrupioCore
import XCTest

final class InstallLocationTests: XCTestCase {
    func testOnlyTheApplicationsFoldersAreAllowed() {
        let home = "/Users/x"
        func refusal(_ path: String) -> String? { InstallLocation.refusal(bundleURL: URL(fileURLWithPath: path), home: home) }
        XCTAssertNil(refusal("/Applications/Chrupio.app"))
        XCTAssertNil(refusal("/Users/x/Applications/Chrupio.app"))
        XCTAssertNil(refusal("/Applications/Tools/Chrupio.app"))
        XCTAssertNotNil(refusal("/Users/x/Downloads/Chrupio.app"))
        XCTAssertNotNil(refusal("/Users/x/orca/KRISP/dist/Chrupio.app"), "a build in the repo")
        XCTAssertNotNil(refusal("/Users/x/orca/KRISP/.build/debug"), "swift run: the bundle is the build folder")
        XCTAssertNotNil(refusal("/private/var/folders/ab/T/AppTranslocation/1234/d/Chrupio.app"))
        XCTAssertNotNil(refusal("/Applications/AppTranslocation/1234/d/Chrupio.app"), "a translocated copy anywhere")
        XCTAssertNotNil(refusal("/Volumes/Chrupio/Chrupio.app"), "the disk image")
        XCTAssertNotNil(refusal("/Applications-old/Chrupio.app"), "a prefix of the name isn't the folder")
        XCTAssertNotNil(refusal("/Applications"), "the folder itself isn't an app in it")
        XCTAssertNotNil(refusal("/Applications/../Users/x/Downloads/Chrupio.app"), "dot-dot leaves the folder")
        XCTAssertNotNil(refusal("/Users/y/Applications/Chrupio.app"), "another account's folder")
        XCTAssertEqual(refusal("/tmp/Chrupio.app"), InstallLocation.message)
    }

    func testSymlinksMustStayInsideTheApplicationsFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InstallLocationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // The temporary folder is /var/folders/…, a symlink into /private: the home is given unresolved on purpose.
        let home = root.appendingPathComponent("home")
        let fm = FileManager.default
        let downloaded = home.appendingPathComponent("Downloads/Chrupio.app")
        let installed = home.appendingPathComponent("Applications/Real.app")
        try fm.createDirectory(at: downloaded, withIntermediateDirectories: true)
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)
        // ~/Applications/Chrupio.app -> ~/Downloads/Chrupio.app: the real copy sits in a download folder.
        let linkIntoDownloads = home.appendingPathComponent("Applications/Chrupio.app")
        try fm.createSymbolicLink(at: linkIntoDownloads, withDestinationURL: downloaded)
        // ~/Desktop/Chrupio.app -> ~/Applications/Real.app: Claude Code would store the Desktop path.
        let linkFromDesktop = home.appendingPathComponent("Desktop/Chrupio.app")
        try fm.createDirectory(at: linkFromDesktop.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkFromDesktop, withDestinationURL: installed)

        XCTAssertNil(InstallLocation.refusal(bundleURL: installed, home: home.path))
        XCTAssertNil(InstallLocation.refusal(bundleURL: installed.resolvingSymlinksInPath(), home: home.path), "resolved /private path")
        XCTAssertNil(InstallLocation.refusal(bundleURL: installed, home: home.resolvingSymlinksInPath().path), "resolved home")
        XCTAssertNotNil(InstallLocation.refusal(bundleURL: linkIntoDownloads, home: home.path))
        XCTAssertNotNil(InstallLocation.refusal(bundleURL: linkFromDesktop, home: home.path))
        XCTAssertNotNil(InstallLocation.refusal(bundleURL: downloaded, home: home.path))
    }

    func testBundleOfTheServerBinary() {
        let binary = URL(fileURLWithPath: "/Applications/Chrupio.app/Contents/MacOS/chrupio-mcp")
        XCTAssertEqual(InstallLocation.bundle(ofServerBinary: binary).path, "/Applications/Chrupio.app")
    }

    func testServerBinaryRefusal() {
        let home = "/Users/x"
        XCTAssertNil(InstallLocation.refusal(serverBinary: URL(fileURLWithPath: "/Users/x/Applications/Chrupio.app/Contents/MacOS/chrupio-mcp"), home: home))
        XCTAssertEqual(InstallLocation.refusal(serverBinary: URL(fileURLWithPath: "/Users/x/orca/KRISP/dist/Chrupio.app/Contents/MacOS/chrupio-mcp"), home: home),
                       InstallLocation.message)
        XCTAssertEqual(InstallLocation.refusal(serverBinary: URL(fileURLWithPath: "/Users/x/orca/KRISP/.build/debug/chrupio-mcp"), home: home),
                       InstallLocation.message, "swift run chrupio-mcp setup")
    }

    func testTheCommandLineRefusalSaysRunSetupAgain() {
        let home = "/Users/x"
        let downloaded = URL(fileURLWithPath: "/Users/x/Downloads/Chrupio.app/Contents/MacOS/chrupio-mcp")
        XCTAssertEqual(InstallLocation.refusal(serverBinary: downloaded, home: home, commandLine: true), InstallLocation.commandLineMessage)
        XCTAssertTrue(InstallLocation.commandLineMessage.hasPrefix("Move Chrupio.app to your Applications folder, then run setup again. "))
        XCTAssertNil(InstallLocation.refusal(serverBinary: URL(fileURLWithPath: "/Applications/Chrupio.app/Contents/MacOS/chrupio-mcp"),
                                             home: home, commandLine: true))
    }
}
