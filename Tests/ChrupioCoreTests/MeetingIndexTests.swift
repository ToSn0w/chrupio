import Foundation
@testable import ChrupioCore
import XCTest

final class MeetingIndexTests: XCTestCase {
    var root: URL!
    var store: MeetingStore!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("index-\(UUID())")
        store = MeetingStore(root: root)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func meeting(_ title: String, summary: String? = nil, transcript: String = "hello there") -> Meeting {
        Meeting(title: title, platform: .meet, startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                endedAt: Date(timeIntervalSince1970: 1_790_001_800), attendees: ["Sam Doe"], selfName: "Lukasz",
                segments: [TranscriptSegment(start: 0, end: 2, speaker: .me, text: transcript)],
                summary: summary.map { MeetingSummary(markdown: $0, model: "m") }, status: .done)
    }

    private func storedIndex() throws -> MeetingIndex {
        try MeetingStore.decoder.decode(MeetingIndex.self, from: Data(contentsOf: store.indexURL))
    }

    func testSaveAndDeleteMaintainIndex() throws {
        let a = meeting("Pricing", summary: "- [ ] Sam: send contract\n- [x] done one\n- [ ] You: deck")
        let b = meeting("Standup")
        try store.save(a)
        try store.save(b)
        var index = try storedIndex()
        XCTAssertEqual(Set(index.entries.keys), [a.id, b.id])
        let entry = try XCTUnwrap(index.entries[a.id])
        XCTAssertEqual(entry.title, "Pricing")
        XCTAssertEqual(entry.openActionItems, 2)
        XCTAssertEqual(entry.selfName, "Lukasz")
        XCTAssertEqual(entry.attendees, ["Sam Doe"])
        XCTAssertTrue(entry.terms.contains("sam doe"))
        XCTAssertFalse(entry.terms.contains("hello there"), "the transcript stays out of the index")

        var renamed = a
        renamed.title = "Pricing v2"
        try store.save(renamed)
        XCTAssertEqual(try storedIndex().entries[a.id]?.title, "Pricing v2")

        try store.delete(b.id)
        index = try storedIndex()
        XCTAssertEqual(Set(index.entries.keys), [a.id])
        XCTAssertEqual(store.index().map(\.id), [a.id])
    }

    func testIndexRebuildsWhenMissingOrStale() throws {
        let a = meeting("One")
        let b = meeting("Two")
        try store.save(a)
        try store.save(b)
        try FileManager.default.removeItem(at: store.indexURL)
        XCTAssertEqual(Set(store.index().map(\.id)), [a.id, b.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.indexURL.path))

        // Another writer (an older app) changes a file without touching the index.
        var changed = b
        changed.title = "Two, renamed"
        let data = try MeetingStore.encoder.encode(changed)
        try data.write(to: store.directory(for: b.id).appendingPathComponent("meeting.json"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: store.directory(for: b.id).appendingPathComponent("meeting.json").path)
        // And a meeting folder disappears behind its back.
        try FileManager.default.removeItem(at: store.directory(for: a.id))
        let entries = store.index()
        XCTAssertEqual(entries.map(\.id), [b.id])
        XCTAssertEqual(entries.first?.title, "Two, renamed")
        XCTAssertEqual(try storedIndex().entries.count, 1)
    }

    func testEntryGivesLightMeetingForHooks() throws {
        let a = meeting("Acme sync", summary: "- [ ] You: ship")
        try store.save(a)
        let light = try XCTUnwrap(store.index().first).meeting
        XCTAssertTrue(light.segments.isEmpty)
        XCTAssertEqual(light.summary?.markdown, "- [ ] You: ship")
        XCTAssertEqual(light.duration, 1_800)
        XCTAssertTrue(ProjectContext(name: "acme", terms: ["acme"]).matches(try XCTUnwrap(store.index().first)))
    }
}

final class SmallerFilesTests: XCTestCase {
    var root: URL!

    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("small-\(UUID())") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testMeetingFilesAreCompactAndPrettyOnesStillLoad() throws {
        let store = MeetingStore(root: root)
        let meeting = Meeting(title: "Compact", platform: .meet, segments: [TranscriptSegment(start: 0, end: 1, speaker: .me, text: "hi")])
        try store.save(meeting)
        let file = store.directory(for: meeting.id).appendingPathComponent("meeting.json")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("\n"))
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
        pretty.dateEncodingStrategy = .iso8601
        try pretty.encode(meeting).write(to: file)
        XCTAssertEqual(try store.load(meeting.id).title, "Compact")
    }

    func testSearchTextIsCachedPerFileVersion() throws {
        let store = MeetingStore(root: root)
        var meeting = Meeting(title: "Pricing", platform: .meet, endedAt: Date(), status: .done)
        meeting.segments = [TranscriptSegment(start: 0, end: 1, speaker: .me, text: "the zebra plan", voice: [1, 2], words: [])]
        meeting.speakerVoices = ["Speaker 2": [0.1]]
        try store.save(meeting)
        let server = MCPServer(store: store, editor: { _, _ in "" })
        XCTAssertTrue(try server.searchMeetings(["query": "zebra"]).contains("Pricing"))
        let cached = try XCTUnwrap(server.allMeetings().first)
        XCTAssertNil(cached.speakerVoices)
        XCTAssertNil(cached.segments[0].voice)
        XCTAssertNil(cached.segments[0].words)

        meeting.segments[0].text = "the giraffe plan"
        try store.save(meeting)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                                              ofItemAtPath: store.directory(for: meeting.id).appendingPathComponent("meeting.json").path)
        XCTAssertTrue(try server.searchMeetings(["query": "zebra"]).hasPrefix("No meetings"))
        XCTAssertTrue(try server.searchMeetings(["query": "giraffe"]).contains("the giraffe plan"))
    }
}

final class PromptHookWindowTests: XCTestCase {
    let since = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(_ title: String, modified: Date) -> MeetingIndex.Entry {
        let meeting = Meeting(title: title, platform: .meet, startedAt: since - 600, endedAt: since + 60, status: .done)
        return MeetingIndex.Entry(meeting, modified: modified)
    }

    func testWindowAdvancesWithEachCheck() {
        var state = HookSessionState(since: since)
        XCTAssertEqual(state.changedSince, since - 6 * 3600)
        let first = PromptUpdates.lines([entry("A", modified: since + 10)], state: state, project: nil, now: since + 20)
        XCTAssertEqual(first.lines.count, 3, "notice, meeting, pointer to the tools")
        XCTAssertEqual(first.state.lastChecked, since + 20)
        state = first.state
        XCTAssertEqual(state.changedSince, since + 18)

        // A meeting whose file changed before the last check is not looked at again, even if not yet announced.
        let old = entry("B", modified: since + 5)
        let second = PromptUpdates.lines([entry("A", modified: since + 10), old], state: state, project: nil, now: since + 100)
        XCTAssertTrue(second.lines.isEmpty)
        XCTAssertEqual(second.state.lastChecked, since + 100)

        let fresh = entry("C", modified: since + 150)
        let third = PromptUpdates.lines([fresh], state: second.state, project: nil, now: since + 200)
        XCTAssertTrue(third.lines.dropFirst().first?.contains("\"C\"") ?? false)
    }

    func testOldStateFilesDecodeWithoutLastChecked() throws {
        let json = #"{"since":"2026-10-20T10:00:00Z","announced":[],"announcedLive":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(HookSessionState.self, from: Data(json.utf8))
        XCTAssertNil(state.lastChecked)
    }

    func testStaleSessionsRemovedAtMostHourly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        HookSessionState(since: now).save("a", in: dir, now: now)
        let old = dir.appendingPathComponent("old.json")
        FileManager.default.createFile(atPath: old.path, contents: Data("{}".utf8),
                                       attributes: [.modificationDate: now.addingTimeInterval(-20 * 86_400)])
        HookSessionState(since: now).save("a", in: dir, now: now.addingTimeInterval(60))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "cleanup ran less than an hour ago")
        HookSessionState(since: now).save("a", in: dir, now: now.addingTimeInterval(3_700))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }
}
