import XCTest
@testable import ChrupioCore

final class OrphanSplitTests: XCTestCase {
    var root: URL!
    var store: MeetingStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("orphan-split-\(UUID().uuidString)")
        store = MeetingStore(root: root)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func chunk(_ offset: TimeInterval, track: AudioChunk.Track = .mic, silent: Bool = false) -> AudioChunk {
        AudioChunk(track: track, index: 1, url: URL(fileURLWithPath: "/x"), startOffset: offset, duration: 30, rms: silent ? 0.0001 : 0.1)
    }

    func testCutsAtGapsAndLongSilences() {
        XCTAssertEqual(MeetingStore.orphanCuts([chunk(0), chunk(30), chunk(60, track: .system)]), [])
        // Nothing recorded from 60 to 600 s.
        XCTAssertEqual(MeetingStore.orphanCuts([chunk(0), chunk(30), chunk(600)]), [330])
        // Silence from 30 to 300 s on both tracks.
        let silent = (1...8).map { chunk(Double($0) * 30, silent: true) }
        XCTAssertEqual(MeetingStore.orphanCuts([chunk(0)] + silent + [chunk(300)]), [165])
        // A short pause is not a new call; the other track talking fills the gap.
        XCTAssertEqual(MeetingStore.orphanCuts([chunk(0), chunk(100)]), [])
        XCTAssertEqual(MeetingStore.orphanCuts([chunk(0), chunk(150, track: .system), chunk(300)]), [])
        XCTAssertEqual(MeetingStore.orphanCuts([chunk(0, silent: true)]), [])
    }

    func testOrphanWithTwoCallsBecomesTwoMeetings() throws {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let dir = store.audioDirectory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (index, offset) in [0.0, 30, 600, 630].enumerated() {
            let wav = dir.appendingPathComponent(String(format: "mic-%04d.wav", index + 1))
            try WAVFile.write([Float](repeating: 0.1, count: 16_000 * 30), sampleRate: ChunkWriter.sampleRate, to: wav)
            let chunk = AudioChunk(track: .mic, index: index + 1, url: wav, startOffset: offset, duration: 30, rms: 0.1)
            try JSONEncoder().encode(chunk).write(to: wav.deletingPathExtension().appendingPathExtension("json"))
            try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(offset + 30)], ofItemAtPath: wav.path)
        }

        let recovered = store.recoverOrphans()

        XCTAssertEqual(recovered.count, 2)
        let parts = recovered.sorted { $0.startedAt < $1.startedAt }
        XCTAssertEqual(parts[0].id, id)
        XCTAssertEqual(parts[0].startedAt.timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(parts[1].startedAt.timeIntervalSince(parts[0].startedAt), 330, accuracy: 1)
        XCTAssertTrue(parts.allSatisfy { $0.status == .transcribing && $0.title.hasPrefix("Recovered recording") && $0.error != nil })
        XCTAssertNotEqual(parts[0].title, parts[1].title)
        XCTAssertEqual(AudioChunkScanner.chunks(in: dir).map(\.startOffset), [0, 30])
        XCTAssertEqual(AudioChunkScanner.chunks(in: store.audioDirectory(for: parts[1].id)).map(\.startOffset), [270, 300])
        XCTAssertEqual(Set(store.loadAll().map(\.id)), Set(parts.map(\.id)))
        XCTAssertEqual(store.orphanFolders(), [])
    }
}
