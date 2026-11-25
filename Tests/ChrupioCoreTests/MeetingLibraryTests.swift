import Foundation
@testable import ChrupioCore
import XCTest

@MainActor
final class MeetingLibraryTests: XCTestCase {
    private func make(_ meetings: [Meeting] = []) -> (MeetingLibrary, FakeSaver, FakeLibraryHooks, FakeNotifier) {
        let saver = FakeSaver()
        let library = MeetingLibrary(saver: saver)
        let hooks = FakeLibraryHooks()
        let notifier = FakeNotifier()
        library.hooks = hooks
        library.notifier = notifier
        library.add(meetings)
        return (library, saver, hooks, notifier)
    }

    func testDeferredSaveIsRetriedWhenDueWithTheMeetingAsItIsThen() async {
        let meeting = Meeting(title: "Call", platform: .meet)
        let (library, saver, hooks, _) = make([meeting])
        saver.script(.deferred)
        library.update(meeting.id) { $0.title = "v1" }
        await settle()
        XCTAssertTrue(library.pendingSaves.contains(meeting.id))
        // While deferred, later changes don't hit the busy lock again.
        library.update(meeting.id) { $0.title = "v2" }
        XCTAssertEqual(saver.saved.count, 1)
        library.retryDeferredSaves(now: Date().addingTimeInterval(60))
        await settle()
        XCTAssertEqual(saver.saved.last?.title, "v2")
        XCTAssertFalse(library.pendingSaves.contains(meeting.id))
        XCTAssertEqual(hooks.saved.map(\.title), ["v2"])
    }

    func testSaveFailureIsReportedOnceAndClearedBySuccess() async {
        let meeting = Meeting(title: "Call", platform: .meet)
        let (library, saver, _, notifier) = make([meeting])
        saver.script(.failed("disk full"), .failed("disk full"))
        XCTAssertFalse(library.persistNow(meeting))
        XCTAssertFalse(library.persistNow(meeting))
        XCTAssertEqual(library.lastError, "Couldn't save meeting notes: disk full")
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertTrue(notifier.posted[0].important)
        XCTAssertTrue(library.persistNow(meeting))
        XCTAssertNil(library.lastError)
    }

    func testMicAudioIsDeletedOnlyAfterItsTextIsSaved() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mic-0000.wav")
        try Data([1]).write(to: url)
        let chunk = AudioChunk(track: .mic, index: 0, url: url, startOffset: 0, duration: 30, rms: 0.1)
        let meeting = Meeting(title: "Call", platform: .meet)
        let (library, saver, hooks, _) = make([meeting])
        hooks.keepAudio = false
        library.removeAfterSave(chunk, of: meeting.id)
        saver.script(.failed("disk full"))
        XCTAssertFalse(library.persistNow(meeting))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "kept: its text isn't on disk")
        XCTAssertTrue(library.persistNow(meeting))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFailedDeleteShowsTheMeetingAgain() async {
        let meeting = Meeting(title: "Call", platform: .meet)
        let (library, saver, hooks, _) = make([meeting])
        saver.deleteError = CocoaError(.fileWriteNoPermission)
        library.delete(meeting)
        XCTAssertTrue(library.meetings.isEmpty, "gone from the list at once")
        XCTAssertEqual(hooks.removed, [meeting.id])
        let back = await until { library.meetings.count == 1 }
        XCTAssertTrue(back)
        XCTAssertTrue(library.lastError?.hasPrefix("Couldn't delete \"Call\"") == true)
    }

    func testDeleteRunsOffTheMainThreadAndClearsThePhase() async {
        let meeting = Meeting(title: "Call", platform: .meet)
        let (library, saver, _, _) = make([meeting])
        library.phases.send(.summaryStarted, to: meeting.id)
        library.delete(meeting)
        XCTAssertNil(library.phases[meeting.id])
        let deleted = await until { saver.deleted == [meeting.id] }
        XCTAssertTrue(deleted)
        XCTAssertNil(library.lastError)
    }

    func testExternalChangeOfABusyMeetingWaits() async throws {
        let meeting = Meeting(title: "Call", platform: .meet)
        let (library, saver, hooks, _) = make([meeting])
        var edited = meeting
        edited.title = "Renamed by MCP"
        try saver.store.save(edited)
        hooks.busy = [meeting.id]
        library.reloadExternalChanges()
        XCTAssertEqual(library.meetings.first?.title, "Call")
        hooks.busy = []
        library.reloadExternalChanges()
        XCTAssertEqual(library.meetings.first?.title, "Renamed by MCP")
        XCTAssertEqual(hooks.loaded.map(\.id), [meeting.id])
    }
}
