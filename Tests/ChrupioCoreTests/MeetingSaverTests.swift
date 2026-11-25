import XCTest
@testable import ChrupioCore

final class MeetingSaverTests: XCTestCase {
    var root: URL!
    var store: MeetingStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("saver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = MeetingStore(root: root)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// Holds the write lock from its own descriptor, as chrupio-mcp would, until the returned closure runs.
    func holdLock() -> () -> Void {
        let fd = open(root.appendingPathComponent(".write.lock").path, O_CREAT | O_RDWR, 0o600)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        return { flock(fd, LOCK_UN); close(fd) }
    }

    final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(String, MeetingSaver.Outcome)] = []
        func add(_ tag: String, _ outcome: MeetingSaver.Outcome) { lock.lock(); values.append((tag, outcome)); lock.unlock() }
        var all: [(String, MeetingSaver.Outcome)] { lock.lock(); defer { lock.unlock() }; return values }
    }

    /// The first save of a new recording finds the lock held: it is deferred and nothing is written; once the
    /// lock is free the retry writes the meeting.
    func testLockHeldAtStartDefersTheFirstSave() throws {
        let saver = MeetingSaver(store: store)
        saver.lockTimeout = 0.05
        let meeting = Meeting(title: "Call", platform: .meet)
        let release = holdLock()
        XCTAssertEqual(saver.saveNow(meeting), .deferred)
        XCTAssertNil(store.modificationDate(meeting.id), "nothing written")
        XCTAssertFalse(saver.isSaving(meeting.id))
        release()
        XCTAssertEqual(saver.saveNow(meeting), .saved(merged: nil))
        XCTAssertEqual(try store.load(meeting.id).title, "Call")
    }

    /// Snapshots queued while the queue is busy: only the newest is written, the older ones are skipped, and the
    /// file ends up with the newest even though the older ones were asked for first.
    func testOlderSnapshotNeverOverwritesANewerOne() throws {
        let saver = MeetingSaver(store: store)
        var meeting = Meeting(title: "v0", platform: .meet)
        let outcomes = Outcomes()
        let release = holdLock()
        saver.lockTimeout = 0.2
        // The first save waits on the lock, so the next ones queue up behind it.
        saver.save(meeting) { outcomes.add("v0", $0) }
        for n in 1...3 {
            meeting.title = "v\(n)"
            let tag = meeting.title
            saver.save(meeting) { outcomes.add(tag, $0) }
        }
        XCTAssertTrue(saver.isSaving(meeting.id))
        release()
        saver.flush()
        XCTAssertFalse(saver.isSaving(meeting.id))
        let results = outcomes.all
        XCTAssertEqual(results.map(\.0), ["v0", "v1", "v2", "v3"], "in order")
        // v0 was already being written when the others were queued; v1 and v2 are skipped.
        XCTAssertEqual(results[1...2].map(\.1), [.superseded, .superseded])
        XCTAssertEqual(results.last?.1, .saved(merged: nil))
        XCTAssertEqual(try store.load(meeting.id).title, "v3")
    }

    /// Deleting waits for the queued saves and drops the ones not started, so the folder doesn't come back.
    func testDeleteDropsQueuedSaves() throws {
        let saver = MeetingSaver(store: store)
        let meeting = Meeting(title: "Call", platform: .meet)
        XCTAssertEqual(saver.saveNow(meeting), .saved(merged: nil))
        let outcomes = Outcomes()
        saver.save(meeting) { outcomes.add("late", $0) }
        try saver.delete(meeting.id)
        saver.flush()
        XCTAssertNil(store.modificationDate(meeting.id))
        XCTAssertEqual(outcomes.all.map(\.1), [.superseded])
    }

    /// A file another process changed since the last save keeps that process's edits.
    func testExternalEditIsMerged() throws {
        let saver = MeetingSaver(store: store)
        var meeting = Meeting(title: "Call", platform: .meet)
        XCTAssertEqual(saver.saveNow(meeting), .saved(merged: nil))
        var disk = try store.load(meeting.id)
        disk.title = "Named elsewhere"
        try store.save(disk)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                                              ofItemAtPath: store.directory(for: meeting.id).appendingPathComponent("meeting.json").path)
        meeting.status = .transcribing
        guard case .saved(let merged?) = saver.saveNow(meeting) else { return XCTFail("expected a merge") }
        XCTAssertEqual(merged.title, "Named elsewhere")
        XCTAssertEqual(merged.status, .transcribing)
        XCTAssertEqual(try store.load(meeting.id).title, "Named elsewhere")
    }
}
