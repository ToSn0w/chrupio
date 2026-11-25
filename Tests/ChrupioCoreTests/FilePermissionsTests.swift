import Foundation
@testable import ChrupioCore
import XCTest

final class FilePermissionsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("perm-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testWritePrivatelyReplacesAReadableFileWithAPrivateOne() throws {
        try FilePermissions.ensurePrivateDirectory(folder)
        XCTAssertEqual(try mode(folder), 0o700)
        let file = folder.appendingPathComponent("a.md")
        FileManager.default.createFile(atPath: file.path, contents: Data("old".utf8), attributes: [.posixPermissions: 0o644])
        try FilePermissions.writePrivately(Data("new".utf8), to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["a.md"], "no temporary file is left")
    }

    func testWritePrivatelyWritesAFileWhoseNameIsNearTheLimit() throws {
        try FilePermissions.ensurePrivateDirectory(folder)
        let name = String(repeating: "\u{00e9}", count: 123) + "aa.md" // 246 + 5 = 251 bytes; 255 is the limit
        let file = folder.appendingPathComponent(name)
        XCTAssertGreaterThanOrEqual(file.lastPathComponent.utf8.count, 250)
        try FilePermissions.writePrivately(Data("long".utf8), to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "long")
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1, "no temporary file is left")
    }

    func testTightenFixesChrupioNotesAndTheFolderOnlyWhenAsked() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let note = folder.appendingPathComponent("2026-11-18 0900 Sync [abcdef12].md")
        let userNote = folder.appendingPathComponent("my notes.md"), other = folder.appendingPathComponent("keep.txt")
        for file in [note, userNote, other] {
            FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o644])
        }
        XCTAssertEqual(FilePermissions.tighten(folder: folder, includingFolder: false), 1)
        XCTAssertEqual(try mode(note), 0o600)
        XCTAssertEqual(try mode(userNote), 0o644, "a Markdown file the user wrote is not ours")
        XCTAssertEqual(try mode(other), 0o644, "only the notes are ours")
        XCTAssertEqual(try mode(folder), 0o755, "a folder the user picked keeps its mode")
        XCTAssertEqual(FilePermissions.tighten(folder: folder, includingFolder: true), 0, "the note is already private")
        XCTAssertEqual(try mode(folder), 0o700)
    }

    func testTightenLeavesSymlinksAndTheirTargetsAlone() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("perm-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let target = outside.appendingPathComponent("target.md")
        FileManager.default.createFile(atPath: target.path, contents: Data(), attributes: [.posixPermissions: 0o644])
        let link = folder.appendingPathComponent("2026-11-18 0900 Sync [abcdef12].md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(FilePermissions.tighten(folder: folder, includingFolder: false), 0)
        XCTAssertEqual(try mode(target), 0o644, "the link's target outside the folder is untouched")
        var info = stat()
        XCTAssertEqual(lstat(link.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK, "the link is still a link")
    }

    func testExportFileNamesAreRecognised() {
        XCTAssertTrue(MeetingExporter.isExportFileName("2026-11-18 0900 Sync [abcdef12].md"))
        XCTAssertFalse(MeetingExporter.isExportFileName("my notes.md"))
        XCTAssertFalse(MeetingExporter.isExportFileName("Sync [ABCDEF12].md"))
        XCTAssertFalse(MeetingExporter.isExportFileName("Sync [abcdef12].md.tmp"))
    }

    func testDefaultFolderIsRecognisedWhateverTheSpelling() {
        XCTAssertTrue(MeetingExporter.isDefaultFolder(MeetingExporter.defaultFolder))
        XCTAssertTrue(MeetingExporter.isDefaultFolder(URL(fileURLWithPath: MeetingExporter.defaultFolder.path + "/", isDirectory: true)))
        XCTAssertTrue(MeetingExporter.isDefaultFolder(MeetingExporter.defaultFolder.appendingPathComponent("x").appendingPathComponent("..")))
        XCTAssertFalse(MeetingExporter.isDefaultFolder(folder))
    }

    func testTightenOnAMissingFolderDoesNothing() {
        XCTAssertEqual(FilePermissions.tighten(folder: folder, includingFolder: true), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
    func testReadPrivatelyReadsOnlyAPrivateFileOfThisAccount() throws {
        try FilePermissions.ensurePrivateDirectory(folder)
        let file = folder.appendingPathComponent("local-api-token")
        XCTAssertNil(try FilePermissions.readPrivately(file), "a missing file is no file")

        try FilePermissions.writePrivately(Data("secret".utf8), to: file)
        XCTAssertEqual(try FilePermissions.readPrivately(file), Data("secret".utf8))

        XCTAssertThrowsError(try FilePermissions.readPrivately(file, owner: getuid() + 1)) { error in
            XCTAssertEqual((error as? FilePermissions.UnsafeFile)?.reason, .notOwned)
            XCTAssertEqual(error.localizedDescription, "local-api-token belongs to another account")
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        XCTAssertThrowsError(try FilePermissions.readPrivately(file)) { error in
            XCTAssertEqual((error as? FilePermissions.UnsafeFile)?.reason, .readableByOthers)
            XCTAssertEqual(error.localizedDescription, "local-api-token can be read by other accounts")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o604], ofItemAtPath: file.path)
        XCTAssertThrowsError(try FilePermissions.readPrivately(file))
    }

    func testReadPrivatelyRefusesALinkEvenToAPrivateFile() throws {
        try FilePermissions.ensurePrivateDirectory(folder)
        let target = folder.appendingPathComponent("elsewhere")
        try FilePermissions.writePrivately(Data("secret".utf8), to: target)
        let link = folder.appendingPathComponent("local-api-endpoint")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try FilePermissions.readPrivately(link)) { error in
            XCTAssertEqual((error as? FilePermissions.UnsafeFile)?.reason, .link)
            XCTAssertEqual(error.localizedDescription, "local-api-endpoint is a link to another file")
        }
        XCTAssertThrowsError(try FilePermissions.readPrivately(folder)) { error in
            XCTAssertEqual((error as? FilePermissions.UnsafeFile)?.reason, .folder)
            XCTAssertEqual((error as? FilePermissions.UnsafeFile)?.path, self.folder.path)
        }
    }
}
