import Foundation
@testable import ChrupioCore
import XCTest

final class FileLockTests: XCTestCase {
    private func holdLock(at path: String) -> () -> Void {
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        return { flock(fd, LOCK_UN); close(fd) }
    }

    func testSaveGivesUpWhenAnotherProcessHoldsTheLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let release = holdLock(at: root.appendingPathComponent(".write.lock").path)
        defer { release() }
        let start = Date()
        XCTAssertThrowsError(try store.withWriteLock(timeout: 0.2) {}) { XCTAssertTrue($0 is MeetingStore.LockTimeout) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testSpeakerPrintsUpdateTimesOutAndLeavesTheFileAlone() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prints-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(atPath: url.path + ".lock") }
        let release = holdLock(at: url.path + ".lock")
        XCTAssertThrowsError(try SpeakerPrints.update(at: url, timeout: 0.2) { $0.learn("Marek", embedding: [1, 0]) }) {
            XCTAssertTrue($0 is MeetingStore.LockTimeout)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        release()
        XCTAssertNoThrow(try SpeakerPrints.update(at: url, timeout: 0.2) { $0.learn("Marek", embedding: [1, 0]) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testWriteProbeThrowsWhenTheFolderIsNotWritable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let id = UUID()
        // A file where the meeting's folder should be.
        try Data().write(to: store.directory(for: id))
        XCTAssertThrowsError(try store.writeProbe(["a": .string("b")], for: id))
    }
}
