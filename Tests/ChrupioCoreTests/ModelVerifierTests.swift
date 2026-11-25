import Darwin
import Foundation
@testable import ChrupioCore
import XCTest

final class ModelVerifierTests: XCTestCase {
    private var folder: URL!
    private var file: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("model-verifier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("download.tmp")
        try Data("hello".utf8).write(to: file)
    }

    override func tearDownWithError() throws {
        // A test may leave a folder read-only; make everything writable again so it can be deleted.
        if let items = FileManager.default.enumerator(atPath: folder.path) {
            for case let item as String in items {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appendingPathComponent(item).path)
            }
        }
        try? FileManager.default.removeItem(at: folder)
    }

    private let hello = PinnedFile(bytes: 5, sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")

    func testMatchingFilePasses() throws {
        XCTAssertNoThrow(try ModelVerifier.verify(file, against: hello))
        XCTAssertTrue(ModelVerifier.hasExpectedSize(file, hello))
    }

    func testUppercasePinStillMatches() {
        XCTAssertNoThrow(try ModelVerifier.verify(file, against: PinnedFile(bytes: 5, sha256: hello.sha256.uppercased())))
    }

    func testWrongSizeFailsBeforeHashing() {
        let pin = PinnedFile(bytes: 6, sha256: hello.sha256)
        XCTAssertThrowsError(try ModelVerifier.verify(file, against: pin)) {
            XCTAssertEqual($0 as? ModelVerifier.Failure, .incomplete(got: 5, expected: 6))
            XCTAssertEqual($0.localizedDescription, "The download was incomplete (5 of 6 bytes). Try again.")
        }
        XCTAssertFalse(ModelVerifier.hasExpectedSize(file, pin))
    }

    func testTooLargeFileSaysSo() {
        let pin = PinnedFile(bytes: 4, sha256: hello.sha256)
        XCTAssertThrowsError(try ModelVerifier.verify(file, against: pin)) {
            XCTAssertEqual($0 as? ModelVerifier.Failure, .tooLarge(got: 5, expected: 4))
            XCTAssertEqual($0.localizedDescription,
                           "The download is larger than expected (5 bytes, expected 4), so it was deleted. Try again.")
        }
    }

    func testMissingFileIsIncomplete() {
        let missing = folder.appendingPathComponent("nope.bin")
        XCTAssertThrowsError(try ModelVerifier.verify(missing, against: hello)) {
            XCTAssertEqual($0 as? ModelVerifier.Failure, .incomplete(got: 0, expected: 5))
        }
        XCTAssertFalse(ModelVerifier.hasExpectedSize(missing, hello))
    }

    func testWrongHashFails() {
        let pin = PinnedFile(bytes: 5, sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try ModelVerifier.verify(file, against: pin)) {
            XCTAssertEqual($0 as? ModelVerifier.Failure, .mismatch)
            XCTAssertEqual($0.localizedDescription,
                           "The downloaded file isn't the expected model (checksum mismatch), so it was deleted. Try again.")
        }
    }

    func testHashIsStreamedOverChunks() throws {
        let big = Data((0..<(3 * 1_048_576 + 7)).map { UInt8($0 % 251) })
        try big.write(to: file)
        XCTAssertEqual(try ModelVerifier.sha256(of: file, chunk: 1_048_576), ModelVerifier.sha256(big))
    }

    /// Hashing a big file keeps memory flat: each chunk is released before the next is read.
    func testHashingABigFileKeepsMemoryFlat() throws {
        guard Self.residentBytes() != nil else { throw XCTSkip("resident memory size isn't available here") }
        let chunk = Data(repeating: 0xA5, count: 4 * 1_048_576)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let writer = try FileHandle(forWritingTo: file)
        for _ in 0..<50 { try autoreleasepool { try writer.write(contentsOf: chunk) } } // 200 MB
        try writer.close()

        let before = try XCTUnwrap(Self.residentBytes())
        _ = try ModelVerifier.sha256(of: file)
        let growth = try XCTUnwrap(Self.residentBytes()) - before
        XCTAssertLessThan(growth, 50 * 1_048_576, "hashing 200 MB grew resident memory by \(growth / 1_048_576) MB")
    }

    private static func residentBytes() -> Int64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : nil
    }

    func testInstallMovesAMatchingFileIntoPlace() throws {
        let destination = folder.appendingPathComponent("ggml-test.bin")
        try Data("old".utf8).write(to: destination)
        try ModelVerifier.install(file, to: destination, pin: hello)
        XCTAssertEqual(try Data(contentsOf: destination), Data("hello".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testInstallDeletesAMismatchAndKeepsWhatWasThere() throws {
        let destination = folder.appendingPathComponent("ggml-test.bin")
        try Data("old".utf8).write(to: destination)
        for pin in [PinnedFile(bytes: 5, sha256: String(repeating: "0", count: 64)), PinnedFile(bytes: 9, sha256: hello.sha256)] {
            try Data("hello".utf8).write(to: file)
            XCTAssertThrowsError(try ModelVerifier.install(file, to: destination, pin: pin))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the bad download is deleted")
            XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8), "the file already in place is untouched")
        }
        let fresh = folder.appendingPathComponent("fresh.bin")
        try Data("hello".utf8).write(to: file)
        XCTAssertThrowsError(try ModelVerifier.install(file, to: fresh, pin: PinnedFile(bytes: 5, sha256: String(repeating: "0", count: 64))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path), "nothing is moved into place")
    }

    /// When the move itself fails (here: the download's folder is read-only), the model already in place survives.
    func testInstallKeepsTheOldModelWhenTheMoveFails() throws {
        let downloads = folder.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let download = downloads.appendingPathComponent("download.tmp")
        try Data("hello".utf8).write(to: download)
        let destination = folder.appendingPathComponent("ggml-test.bin")
        try Data("old".utf8).write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: downloads.path)

        XCTAssertThrowsError(try ModelVerifier.install(download, to: destination, pin: hello))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8), "the model already in place is kept")
    }

    func testEveryModelIsPinnedToACommit() {
        for model in WhisperModel.all {
            XCTAssertEqual(model.pin.sha256.count, 64, model.name)
            XCTAssertGreaterThan(model.pin.bytes, 100_000_000, model.name)
            XCTAssertTrue(model.downloadURL.absoluteString.contains("/resolve/\(WhisperModel.revision)/"), model.name)
            XCTAssertFalse(model.downloadURL.absoluteString.contains("/resolve/main/"), model.name)
        }
        XCTAssertEqual(WhisperModel.revision.count, 40)
        XCTAssertEqual(VADModel.revision.count, 40)
        XCTAssertEqual(VADModel.pin.bytes, 885_098)
        XCTAssertTrue(VADModel.downloadURL.absoluteString.contains("/resolve/\(VADModel.revision)/"))
        XCTAssertFalse(VADModel.downloadURL.absoluteString.contains("/resolve/main/"))
    }

    /// install.sh carries its own copy of the pins; they must stay the same as the app's.
    func testInstallScriptUsesTheSamePins() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/install.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("WHISPER_REV=\(WhisperModel.revision)"))
        XCTAssertTrue(script.contains("VAD_REV=\(VADModel.revision)"))
        let small = try XCTUnwrap(WhisperModel.all.first { $0.name == "small" })
        // Each checksum must sit on the line that verifies its own file, so swapping the two hashes fails.
        let lines = script.split(separator: "\n").map(String.init)
        func verifyLine(_ file: String) -> String? { lines.first { $0.contains("verify_sha256") && $0.contains("\(file).part") } }
        let smallLine = try XCTUnwrap(verifyLine("ggml-small.bin"))
        let vadLine = try XCTUnwrap(verifyLine("ggml-silero-v5.1.2.bin"))
        XCTAssertTrue(smallLine.contains(small.pin.sha256), smallLine)
        XCTAssertTrue(vadLine.contains(VADModel.pin.sha256), vadLine)
        XCTAssertEqual(small.downloadURL.lastPathComponent, "ggml-small.bin")
        XCTAssertEqual(VADModel.downloadURL.lastPathComponent, "ggml-silero-v5.1.2.bin")
        XCTAssertTrue(script.contains("/resolve/$WHISPER_REV/ggml-small.bin"))
        XCTAssertTrue(script.contains("/resolve/$VAD_REV/ggml-silero-v5.1.2.bin"))
        XCTAssertFalse(script.contains("/resolve/main/"))
    }
}
