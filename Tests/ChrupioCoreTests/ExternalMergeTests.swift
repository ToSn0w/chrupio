import Foundation
@testable import ChrupioCore
import XCTest

final class ExternalMergeTests: XCTestCase {
    func testStaleOnlyWhenDiskDateDiffers() {
        let id = UUID(), date = Date(timeIntervalSince1970: 100)
        var changes = ExternalChanges()
        XCTAssertFalse(changes.isStale(id, onDisk: nil), "no file yet")
        XCTAssertTrue(changes.isStale(id, onDisk: date), "a file the app never loaded")
        changes.loaded(id, modified: date)
        XCTAssertFalse(changes.isStale(id, onDisk: date))
        XCTAssertTrue(changes.isStale(id, onDisk: date.addingTimeInterval(1)))
    }

    func testDiskWinsForUserEditsAppWinsForLines() throws {
        let summaryDate = Date(timeIntervalSince1970: 1000)
        var app = Meeting(title: "Sync", platform: .meet, segments: [
            TranscriptSegment(start: 0, end: 1, speaker: .remote("Speaker 2"), text: "a"),
            TranscriptSegment(start: 1, end: 2, speaker: .remote("Anna"), text: "b"),
        ], summary: MeetingSummary(markdown: "- [ ] Send deck", model: "m", createdAt: summaryDate), status: .done)
        var disk = app
        _ = try MeetingEdit.rename(title: "Budget sync").apply(to: &disk)
        _ = try MeetingEdit.addNote(text: "check budget", author: "Claude").apply(to: &disk)
        _ = try MeetingEdit.setActionItem(item: "1", done: true).apply(to: &disk)
        _ = try MeetingEdit.assignSpeaker(speaker: "Speaker 2", name: "Marek").apply(to: &disk)
        // Meanwhile the app produced a new line.
        app.segments.append(TranscriptSegment(start: 2, end: 3, speaker: .remote("Speaker 2"), text: "c"))

        let merged = app.merging(disk: disk)
        XCTAssertEqual(merged.title, "Budget sync")
        XCTAssertEqual(merged.notes?.map(\.text), ["check budget"])
        XCTAssertEqual(merged.summary?.markdown, "- [x] Send deck")
        XCTAssertEqual(merged.segments.map(\.speaker.label), ["Marek", "Anna", "Speaker 2"])
        XCTAssertTrue(merged.attendees.contains("Marek"))
    }

    func testNewerAppSummaryIsKept() {
        let old = Meeting(title: "x", platform: .meet, summary: MeetingSummary(markdown: "old", model: "m", createdAt: Date(timeIntervalSince1970: 1)))
        var app = old
        app.summary = MeetingSummary(markdown: "new", model: "m", createdAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(app.merging(disk: old).summary?.markdown, "new")
    }

    func testSpeakerPrintsUpdateTakesAFileLock() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(atPath: url.path + ".lock") }
        // Another process holds the lock; the update waits for it.
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        flock(fd, LOCK_EX)
        let done = expectation(description: "update")
        DispatchQueue.global().async {
            try? SpeakerPrints.update(at: url) { $0.learn("Marek", embedding: [1, 0]) }
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "update ran while the lock was held")
        flock(fd, LOCK_UN)
        close(fd)
        wait(for: [done], timeout: 5)
        XCTAssertNotNil(SpeakerPrints.load(from: url).people["Marek"])
    }
}
