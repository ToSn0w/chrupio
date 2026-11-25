import XCTest
@testable import ChrupioCore

/// Item #10: finished meetings keep Opus audio instead of WAV, and audio older than 30 days goes.
final class AudioRetentionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("retention-\(UUID().uuidString)/audio")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    /// Two seconds of a 440 Hz tone with a quiet second half, so level differences show.
    private func tone() -> [Float] {
        (0..<(ChunkWriter.sampleRate * 2)).map { i in
            Float(sin(2 * Double.pi * 440 * Double(i) / Double(ChunkWriter.sampleRate))) * (i < ChunkWriter.sampleRate ? 0.5 : 0.1)
        }
    }

    private func writeChunk(_ name: String, samples: [Float]) throws -> URL {
        let wav = dir.appendingPathComponent("\(name).wav")
        try WAVFile.write(samples, sampleRate: ChunkWriter.sampleRate, to: wav)
        let chunk = AudioChunk(track: .system, index: 1, url: wav, startOffset: 0,
                               duration: Double(samples.count) / Double(ChunkWriter.sampleRate), rms: WAVFile.rms(samples))
        try JSONEncoder().encode(chunk).write(to: wav.deletingPathExtension().appendingPathExtension("json"))
        return wav
    }

    func testCompressedChunkDecodesBackToTheSameAudio() throws {
        let samples = tone()
        let wav = try writeChunk("system-0001", samples: samples)
        let originalSize = try XCTUnwrap(wav.resourceValues(forKeys: [.fileSizeKey]).fileSize)

        let compressed = try AudioCompression.compress(wav)
        XCTAssertEqual(compressed.pathExtension, AudioCompression.fileExtension)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path), "the WAV is removed once the copy decodes")
        let size = try XCTUnwrap(compressed.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThan(size, originalSize / 5)

        let decoded = try WAVFile.read(compressed)
        XCTAssertEqual(Double(decoded.count), Double(samples.count), accuracy: Double(ChunkWriter.sampleRate) * 0.05)
        XCTAssertEqual(WAVFile.rms(Array(decoded.prefix(ChunkWriter.sampleRate))), WAVFile.rms(Array(samples.prefix(ChunkWriter.sampleRate))), accuracy: 0.05)
        XCTAssertEqual(WAVFile.rms(Array(decoded.suffix(ChunkWriter.sampleRate / 2))), WAVFile.rms(Array(samples.suffix(ChunkWriter.sampleRate / 2))), accuracy: 0.03)
    }

    func testReadersFindCompressedChunks() throws {
        let samples = tone()
        _ = try AudioCompression.compress(try writeChunk("system-0001", samples: samples))

        let chunks = AudioChunkScanner.chunks(in: dir)
        XCTAssertEqual(chunks.count, 1, "the sidecar still finds its chunk")
        XCTAssertEqual(chunks.first?.url.pathExtension, AudioCompression.fileExtension)
        XCTAssertTrue(AudioCompression.hasAudio(in: dir))

        let timeline = dir.appendingPathComponent("timeline.out")
        let length = try WAVFile.writeTimeline(chunks, to: timeline)
        XCTAssertEqual(length, 2, accuracy: 0.01)
        XCTAssertEqual(WAVFile.rms(try WAVFile.read(timeline)), WAVFile.rms(samples), accuracy: 0.05)

        let (wav, cleanup) = try AudioCompression.temporaryWAV(for: chunks[0].url)
        defer { cleanup() }
        XCTAssertEqual(wav.pathExtension, "wav")
        XCTAssertEqual(WAVFile.duration(of: wav), 2, accuracy: 0.1)
    }

    /// A damaged Opus file whose packet table claims a year of audio is rejected before anything big is allocated.
    func testDecodeRejectsAFileReportingAnAbsurdLength() throws {
        let caf = try AudioCompression.compress(try writeChunk("mic-0001", samples: tone()))
        var data = try Data(contentsOf: caf)
        let pakt = try XCTUnwrap(data.range(of: Data("pakt".utf8)))
        // pakt body: Int64 packet count, then Int64 valid frames (big-endian).
        let validFrames = pakt.upperBound + 8 + 8
        let absurd = Int64(365 * 86_400 * 48_000).bigEndian
        withUnsafeBytes(of: absurd) { data.replaceSubrange(validFrames..<validFrames + 8, with: $0) }
        try data.write(to: caf)
        XCTAssertThrowsError(try WAVFile.read(caf)) { error in
            guard case AudioCompression.Failure.implausible = error else { return XCTFail("\(error)") }
        }
    }

    func testDecodeOfATruncatedFileReturnsWhatIsThereOrThrows() throws {
        let caf = try AudioCompression.compress(try writeChunk("mic-0001", samples: tone()))
        let data = try Data(contentsOf: caf)
        try data.prefix(data.count / 2).write(to: caf)
        if let samples = try? WAVFile.read(caf) {
            XCTAssertLessThanOrEqual(samples.count, ChunkWriter.sampleRate * 3)
        }
    }

    func testCompressMeetingSkipsWhatIsAlreadyDone() throws {
        _ = try writeChunk("system-0001", samples: tone())
        _ = try writeChunk("mic-0001", samples: tone())
        XCTAssertEqual(try AudioCompression.compressMeeting(audio: dir), 2)
        XCTAssertEqual(try AudioCompression.compressMeeting(audio: dir), 0)
        XCTAssertFalse(AudioCompression.hasUncompressed(in: dir))
    }

    func testHungOrFailingCompressionKeepsTheWAVAndIsNeverRetried() throws {
        let root = dir.deletingLastPathComponent().deletingLastPathComponent()
        let store = MeetingStore(root: root)
        let id = UUID(uuidString: dir.deletingLastPathComponent().lastPathComponent) ?? UUID()
        let audio = store.audioDirectory(for: id)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let hung = audio.appendingPathComponent("mic-0001.wav"), failed = audio.appendingPathComponent("mic-0002.wav")
        try WAVFile.write(tone(), sampleRate: ChunkWriter.sampleRate, to: hung)
        try WAVFile.write(tone(), sampleRate: ChunkWriter.sampleRate, to: failed)
        // Stands in for the Opus decoder that never returns on some chunks: sleeps on the first, fails on the second.
        let script = "case \"$1\" in *0001*) sleep 30;; *) exit 1;; esac"
        let started = Date()
        let result = store.compressAudioIsolated(id, executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, "sh"], timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(result.done, 0)
        XCTAssertEqual(result.skipped, ["mic-0001.wav", "mic-0002.wav"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: hung.path))
        XCTAssertFalse(AudioCompression.hasUncompressed(in: audio))
        XCTAssertEqual(try store.compressAudio(id), 0)
        try? FileManager.default.removeItem(at: store.directory(for: id))
    }

    func testSaveGivesUpWhenTheWriteLockIsHeld() throws {
        let store = MeetingStore(root: dir.deletingLastPathComponent())
        let holder = open(store.root.appendingPathComponent(".write.lock").path, O_CREAT | O_RDWR, 0o600)
        defer { close(holder) }
        XCTAssertEqual(flock(holder, LOCK_EX), 0)
        let started = Date()
        XCTAssertThrowsError(try store.withWriteLock(timeout: 0.2) {}) { XCTAssertTrue($0 is MeetingStore.LockTimeout) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        flock(holder, LOCK_UN)
        XCTAssertNoThrow(try store.withWriteLock(timeout: 0.2) {})
    }

    func testCompressionHoldsTheLockOnlyForTheSwap() throws {
        let root = dir.deletingLastPathComponent()
        let store = MeetingStore(root: root)
        let wav = try writeChunk("mic-0001", samples: tone())
        var lockedDuringEncode = false
        _ = try AudioCompression.compress(wav, install: { swap in
            lockedDuringEncode = FileManager.default.fileExists(atPath: AudioCompression.partialURL(for: wav).path)
            try store.withWriteLock(timeout: 0.2, swap)
        })
        XCTAssertTrue(lockedDuringEncode, "the copy is encoded before the lock is taken")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
    }

    func testCompressionLeavesAChunkThatChangedWhileEncoding() throws {
        let wav = try writeChunk("mic-0001", samples: tone())
        let result = try AudioCompression.compress(wav, install: { swap in
            try WAVFile.write(Array(tone().prefix(8_000)), sampleRate: ChunkWriter.sampleRate, to: wav)
            try swap()
        })
        XCTAssertEqual(result, wav)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.deletingPathExtension().appendingPathExtension("caf").path))
    }

    private func meeting(daysAgo: Double, status: MeetingStatus = .done, summary: Bool = true, transcript: Bool = true) -> Meeting {
        var meeting = Meeting(title: "Weekly", platform: .meet, startedAt: Date(timeIntervalSince1970: 1_000_000_000 - daysAgo * 86_400))
        meeting.status = status
        if summary { meeting.summary = MeetingSummary(markdown: "ok", model: "test") }
        if transcript { meeting.segments = [TranscriptSegment(start: 0, end: 2, speaker: .me, text: "Hello")] }
        return meeting
    }

    func testPlanCompressesTranscribedMeetingsAndDeletesOldAudio() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let fresh = meeting(daysAgo: 1), old = meeting(daysAgo: 31), busy = meeting(daysAgo: 2),
            unsummarized = meeting(daysAgo: 3, summary: false), failed = meeting(daysAgo: 4, status: .failed, summary: false),
            untranscribed = meeting(daysAgo: 5, status: .failed, summary: false, transcript: false),
            oldStuck = meeting(daysAgo: 100, status: .transcribing, summary: false, transcript: false)
        let all = [fresh, old, busy, unsummarized, failed, untranscribed, oldStuck]
        let plan = AudioRetention.plan(all, now: now, hasAudio: { _ in true }, hasUncompressed: { _ in true },
                                       isBusy: { $0 == busy.id })
        XCTAssertEqual(plan, [.delete(oldStuck.id), .delete(old.id), .compress(failed.id), .compress(unsummarized.id), .compress(fresh.id)])
        XCTAssertEqual(AudioRetention.plan(all, now: now, hasAudio: { _ in false }, hasUncompressed: { _ in false }, isBusy: { _ in false }), [])
    }

    func testAudioIsDeletedAfterThirtyDaysNotBefore() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let recent = meeting(daysAgo: 29), old = meeting(daysAgo: 31)
        let plan = AudioRetention.plan([recent, old], now: now, hasAudio: { _ in true }, hasUncompressed: { _ in false }, isBusy: { _ in false })
        XCTAssertEqual(plan, [.delete(old.id)])
    }

    func testRunsAtMostOncePerDay() {
        let now = Date()
        XCTAssertTrue(AudioRetention.isDue(lastRun: nil, now: now))
        XCTAssertFalse(AudioRetention.isDue(lastRun: now.addingTimeInterval(-3_600), now: now))
        XCTAssertTrue(AudioRetention.isDue(lastRun: now.addingTimeInterval(-86_401), now: now))
    }
}

final class CompressedSplitTests: XCTestCase {
    func testSplitWorksOnCompressedAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("split-caf-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = Meeting(title: "Call", platform: .other, startedAt: start, endedAt: start + 40,
                              summary: MeetingSummary(markdown: "s", model: "m"), status: .done)
        try store.save(meeting)
        let audio = store.audioDirectory(for: meeting.id)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        for (index, offset) in [0.0, 20].enumerated() {
            let url = audio.appendingPathComponent(String(format: "mic-%04d.wav", index + 1))
            let samples = (0..<(16_000 * 20)).map { Float(sin(Double($0) * 0.2)) * 0.3 }
            try WAVFile.write(samples, sampleRate: 16_000, to: url)
            let chunk = AudioChunk(track: .mic, index: index + 1, url: url, startOffset: offset, duration: 20, rms: 0.2)
            try JSONEncoder().encode(chunk).write(to: url.deletingPathExtension().appendingPathExtension("json"))
        }
        XCTAssertEqual(try store.compressAudio(meeting.id), 2)

        let (_, second) = try store.split(meeting.id, at: 10, retranscribe: true)

        let kept = AudioChunkScanner.chunks(in: audio)
        XCTAssertEqual(kept.map { $0.url.lastPathComponent }, ["mic-0001.wav"])
        XCTAssertEqual(WAVFile.duration(of: kept[0].url), 10, accuracy: 0.05)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.appendingPathComponent("mic-0001.caf").path))
        let moved = AudioChunkScanner.chunks(in: store.audioDirectory(for: second.id))
        XCTAssertEqual(moved.map { $0.url.lastPathComponent }, ["mic-0001.wav", "mic-0002.caf"])
        XCTAssertEqual(try WAVFile.read(moved[1].url).count, 16_000 * 20, accuracy: 1_600)
    }
}
