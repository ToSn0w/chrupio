import XCTest
@testable import ChrupioCore

final class MeetingMergeTests: XCTestCase {
    var root: URL!
    var store: MeetingStore!
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString)")
        store = MeetingStore(root: root)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func line(_ start: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 2, speaker: .remote("Anna"), text: text,
                          words: [TimedWord(start: start, end: start + 1, text: text)])
    }

    func writeChunk(_ id: UUID, track: AudioChunk.Track, index: Int, offset: TimeInterval) throws {
        let dir = store.audioDirectory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent(String(format: "%@-%04d.wav", track.rawValue, index))
        try WAVFile.write([Float](repeating: 0.1, count: 1600), sampleRate: ChunkWriter.sampleRate, to: wav)
        let chunk = AudioChunk(track: track, index: index, url: wav, startOffset: offset, duration: 30, rms: 0.1)
        try JSONEncoder().encode(chunk).write(to: wav.deletingPathExtension().appendingPathExtension("json"))
    }

    func testOverlappingRecordingsKeepEachLineOnce() {
        var target = Meeting(title: "Sync", platform: .meet, startedAt: start, attendees: [])
        target.endedAt = start.addingTimeInterval(120)
        target.segments = [line(10, "Let's start with the billing page."), line(100, "Anna, can you send the deck?")]
        // Started 90 s later, so its 12 s is the target's 102 s.
        var source = Meeting(title: "Sync", platform: .meet, startedAt: start.addingTimeInterval(90), attendees: [])
        source.endedAt = start.addingTimeInterval(240)
        var relabelled = line(12, "anna can you send the deck")
        relabelled.speaker = .remote("Speaker 2")
        source.segments = [line(8, "Anna, can you send the deck"), relabelled, line(40, "Sure, I'll send it today."),
                           line(60, "Let's start with the billing page.")]
        let texts = MeetingMerge.merged(source, into: target).meeting.segments.map(\.text)
        // The repeat at 60 s (150 s on the merged timeline) is far from the target's line, so it stays.
        XCTAssertEqual(texts, ["Let's start with the billing page.", "Anna, can you send the deck?", "Sure, I'll send it today.",
                               "Let's start with the billing page."])
        XCTAssertTrue(MeetingMerge.isNearDuplicate("We ship the export on Friday", "we ship the export on friday then"))
        XCTAssertFalse(MeetingMerge.isNearDuplicate("We ship on Friday", "We ship on Monday"))
    }

    func testFragmentRule() {
        var meeting = Meeting(title: "Call", platform: .meet, startedAt: start, endedAt: start + 16, segments: [line(0, "Hej")])
        XCTAssertTrue(MeetingFragment.isFragment(meeting))
        meeting.endedAt = start + 600
        XCTAssertTrue(MeetingFragment.isFragment(meeting), "one line in ten minutes")
        meeting.segments = [line(0, "a"), line(10, "b"), line(20, "c")]
        XCTAssertFalse(MeetingFragment.isFragment(meeting))
        meeting.endedAt = start + 59
        XCTAssertTrue(MeetingFragment.isFragment(meeting))
    }

    func testNeighboursAreAdjacentOrOverlappingOnTheSamePlatform() {
        let fragment = Meeting(title: "Frag", platform: .slack, startedAt: start + 3600, endedAt: start + 3660, status: .done)
        let before = Meeting(title: "Before", platform: .slack, startedAt: start, endedAt: start + 3300, status: .done)
        let overlapping = Meeting(title: "Overlap", platform: .slack, startedAt: start + 3000, endedAt: start + 4000, status: .done)
        let otherPlatform = Meeting(title: "Zoom", platform: .zoom, startedAt: start + 3500, endedAt: start + 3700, status: .done)
        let after = Meeting(title: "After", platform: .slack, startedAt: start + 3900, endedAt: start + 5000, status: .done)
        let farAfter = Meeting(title: "Far", platform: .slack, startedAt: start + 9000, endedAt: start + 9500, status: .done)
        let all = [fragment, before, overlapping, otherPlatform, after, farAfter]
        let (previous, next) = MeetingMerge.neighbours(of: fragment, in: all)
        XCTAssertEqual(previous?.title, "Overlap")
        XCTAssertEqual(next?.title, "After")
        let lonely = MeetingMerge.neighbours(of: farAfter, in: all)
        XCTAssertNil(lonely.previous, "more than 10 minutes after the last call")
        XCTAssertNil(lonely.next)
    }

    func testMergeCombinesTranscriptsAttendeesNotesAndAudio() throws {
        var target = Meeting(title: "Daily", platform: .meet, startedAt: start + 60, endedAt: start + 600, attendees: ["Anna"],
                             segments: [line(5, "target first"), line(100, "target later")], speakerEvents: [SpeakerEvent(time: 5, names: ["Anna"])],
                             summary: MeetingSummary(markdown: "old", model: "m"), status: .done, language: "pl",
                             notes: [MeetingNote(createdAt: start + 1000, author: "Claude", text: "note B")])
        target.typedNotes = "outline B"
        var source = Meeting(title: "Daily", platform: .meet, startedAt: start, endedAt: start + 50, attendees: ["Jan Kowalski"],
                             segments: [line(10, "source")], status: .done,
                             notes: [MeetingNote(createdAt: start + 10, author: "Claude", text: "note A")])
        source.typedNotes = "outline A"
        source.fragment = true
        try store.save(target)
        try store.save(source)
        try writeChunk(target.id, track: .mic, index: 1, offset: 0)
        try writeChunk(target.id, track: .system, index: 1, offset: 0)
        try writeChunk(source.id, track: .mic, index: 1, offset: 0)
        try writeChunk(source.id, track: .mic, index: 2, offset: 30)

        let merged = try store.merge(source.id, into: target.id)

        XCTAssertEqual(merged.id, target.id)
        XCTAssertEqual(merged.startedAt, start)
        XCTAssertEqual(merged.endedAt, start + 600)
        XCTAssertEqual(merged.segments.map(\.text), ["source", "target first", "target later"])
        XCTAssertEqual(merged.segments.map(\.start), [10, 65, 160])
        XCTAssertEqual(merged.segments[1].words?.first?.start, 65)
        XCTAssertEqual(merged.speakerEvents.map(\.time), [65])
        XCTAssertEqual(merged.attendees, ["Anna", "Jan Kowalski"])
        XCTAssertEqual(merged.notes?.map(\.text), ["note A", "note B"])
        XCTAssertEqual(merged.typedNotes, "outline A\n\noutline B")
        XCTAssertNil(merged.summary)
        XCTAssertNil(merged.fragment)
        XCTAssertEqual(try store.load(target.id), merged)
        XCTAssertThrowsError(try store.load(source.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: source.id).path))

        let chunks = AudioChunkScanner.chunks(in: store.audioDirectory(for: target.id))
        let mic = chunks.filter { $0.track == .mic }.sorted { $0.index < $1.index }
        XCTAssertEqual(mic.map(\.index), [1, 2, 3])
        XCTAssertEqual(mic.map(\.startOffset), [60, 0, 30], "the target's chunk moves 60 s later, the source's keep theirs")
        XCTAssertEqual(mic.map { $0.url.lastPathComponent }, ["mic-0001.wav", "mic-0002.wav", "mic-0003.wav"])
        XCTAssertEqual(chunks.filter { $0.track == .system }.map(\.startOffset), [60])
    }
}
