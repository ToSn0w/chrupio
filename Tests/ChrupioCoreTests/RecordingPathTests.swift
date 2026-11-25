import XCTest
@testable import ChrupioCore

/// The recording path: orphan recovery, start ordering, deferred saves and chunk merging.
final class RecordingPathTests: XCTestCase {
    var root: URL!
    var store: MeetingStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-path-\(UUID().uuidString)")
        store = MeetingStore(root: root)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// Writes a 30 s chunk at `offset` whose file is dated `written`.
    @discardableResult
    func writeChunk(_ id: UUID, track: AudioChunk.Track, index: Int, offset: TimeInterval, written: Date) throws -> AudioChunk {
        let dir = store.audioDirectory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("\(track.rawValue)-\(String(format: "%04d", index)).wav")
        let samples = [Float](repeating: 0.1, count: 1600)
        try WAVFile.write(samples, sampleRate: ChunkWriter.sampleRate, to: wav)
        let chunk = AudioChunk(track: track, index: index, url: wav, startOffset: offset, duration: 30, rms: 0.1)
        try JSONEncoder().encode(chunk).write(to: wav.deletingPathExtension().appendingPathExtension("json"))
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: wav.path)
        return chunk
    }

    func testOrphanFolderBecomesATranscribingMeeting() throws {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try writeChunk(id, track: .mic, index: 1, offset: 0, written: start.addingTimeInterval(30))
        try writeChunk(id, track: .system, index: 1, offset: 0, written: start.addingTimeInterval(31))
        try writeChunk(id, track: .mic, index: 2, offset: 30, written: start.addingTimeInterval(60))
        // A saved meeting and a folder without audio are not orphans.
        let saved = Meeting(title: "Saved", platform: .meet)
        try store.save(saved)
        try writeChunk(saved.id, track: .mic, index: 1, offset: 0, written: start)
        try FileManager.default.createDirectory(at: store.audioDirectory(for: UUID()), withIntermediateDirectories: true)

        XCTAssertEqual(store.orphanFolders(), [id])
        let recovered = store.recoverOrphans()
        XCTAssertEqual(recovered.map(\.id), [id])
        let meeting = try store.load(id)
        XCTAssertEqual(meeting.status, .transcribing)
        XCTAssertEqual(meeting.startedAt.timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(meeting.endedAt).timeIntervalSince1970, start.addingTimeInterval(60).timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(meeting.segments.isEmpty)
        XCTAssertEqual(store.orphanFolders(), [], "recovered once")
        XCTAssertEqual(Set(store.loadAll().map(\.id)), [id, saved.id])
    }

    /// Another process holding the write lock at launch: recovery gives up within the timeout and the folder is
    /// recovered on a later try.
    func testOrphanRecoveryWaitsForTheLockOnlyUntilTheTimeout() throws {
        let id = UUID()
        try writeChunk(id, track: .mic, index: 1, offset: 0, written: Date(timeIntervalSince1970: 1_800_000_030))
        let holder = open(store.root.appendingPathComponent(".write.lock").path, O_CREAT | O_RDWR, 0o600)
        defer { close(holder) }
        XCTAssertEqual(flock(holder, LOCK_EX), 0)
        let started = Date()
        let blocked = store.recoverOrphans(lockTimeout: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(blocked.recovered.count, 0)
        XCTAssertEqual(blocked.blocked, 1)
        XCTAssertEqual(store.orphanFolders(), [id])
        flock(holder, LOCK_UN)
        let retried = store.recoverOrphans(lockTimeout: 0.2)
        XCTAssertEqual(retried.recovered.map(\.id), [id])
        XCTAssertEqual(retried.blocked, 0)
    }

    /// Chunks of both tracks finishing out of order: merging each chunk's lines in order and naming only those gives
    /// the transcript that appending, sorting everything and naming the unnamed lines per chunk gave.
    func testIncrementalMergeEqualsFullSort() {
        var meeting = Meeting(title: "Call", platform: .meet, attendees: ["Anna Nowak", "Jan Kowalski"])
        meeting.speakerEvents = [SpeakerEvent(time: 0, names: ["Anna Nowak"], end: 50),
                                 SpeakerEvent(time: 50, names: ["Jan Kowalski"], end: 130)]
        var generator = SystemRandomNumberGenerator()
        // Each chunk: 30 s of one track, lines every few seconds, some starting at the same time as the other track's.
        let chunks: [[TranscriptSegment]] = (0..<8).map { n in
            let track = n % 2 == 0 ? Speaker.me : Speaker.remote(nil)
            let base = Double(n / 2) * 30
            return stride(from: base, to: base + 30, by: 5).map { start in
                TranscriptSegment(start: start + (n % 3 == 0 ? 0 : Double.random(in: 0..<2, using: &generator).rounded()),
                                  end: start + 4, speaker: track, text: "line \(n) \(start)")
            }.shuffled()
        }
        let order = [1, 0, 3, 2, 4, 6, 5, 7]

        var full = meeting
        var incremental = meeting
        for n in order {
            full.segments.append(contentsOf: chunks[n])
            full.segments.sort { $0.start < $1.start }
            SpeakerAttribution.apply(to: &full, onlyUnnamed: true)
            TranscriptionPipeline.merge(chunks[n], into: &incremental)
        }
        func key(_ s: TranscriptSegment) -> String { "\(s.start) \(s.end) \(s.speaker.label) \(s.text)" }
        XCTAssertEqual(incremental.segments.map(key), full.segments.map(key))
        XCTAssertTrue(incremental.segments.contains { $0.speaker == .remote("Jan Kowalski") })
    }
}
