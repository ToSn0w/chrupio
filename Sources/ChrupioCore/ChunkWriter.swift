import Foundation

/// A finished piece of one audio track, written to disk as 16 kHz mono WAV.
public struct AudioChunk: Sendable, Hashable, Codable {
    public enum Track: String, Sendable, Codable { case mic, system }

    public var track: Track
    public var index: Int
    public var url: URL
    /// Seconds from meeting start to the first sample of this chunk.
    public var startOffset: TimeInterval
    public var duration: TimeInterval
    public var rms: Float

    public init(track: Track, index: Int, url: URL, startOffset: TimeInterval, duration: TimeInterval, rms: Float) {
        self.track = track
        self.index = index
        self.url = url
        self.startOffset = startOffset
        self.duration = duration
        self.rms = rms
    }

    /// Chunks quieter than this are not worth transcribing (and whisper hallucinates on them).
    public var isSilent: Bool { rms < 0.002 }
}

/// Collects 16 kHz mono samples and cuts them into chunks at quiet moments.
/// Not thread-safe; callers serialize access.
public final class ChunkWriter {
    public static let sampleRate = 16_000

    public let track: AudioChunk.Track
    private let directory: URL
    private let targetSeconds: Double
    private let searchSeconds: Double
    private let trackOffset: TimeInterval
    /// Buffered audio is `samples[head...]`; consumed audio is dropped from the front only now and then,
    /// so a long backlog isn't shifted on every chunk.
    private var samples: [Float] = []
    private var head = 0
    private var writtenSamples = 0
    /// Buffered samples at the last write of the chunk in progress.
    private var savedPartial = 0
    /// How often the chunk in progress is written to disk, so a crash loses seconds instead of up to a chunk.
    public static let partialInterval = 5 * ChunkWriter.sampleRate
    private var index = 0
    /// The last disk error, cleared once a chunk is written again. Audio stays buffered meanwhile.
    public private(set) var writeError: String?
    /// While writes fail, keep at most this much audio in memory (about 77 MB) before dropping the oldest.
    private let maxBufferedSamples = 20 * 60 * ChunkWriter.sampleRate

    /// - Parameters:
    ///   - trackOffset: seconds between meeting start and this track's first sample.
    ///   - targetSeconds: preferred chunk length; the cut lands at the quietest point in the last `searchSeconds`.
    public init(track: AudioChunk.Track, directory: URL, trackOffset: TimeInterval = 0, targetSeconds: Double = 30, searchSeconds: Double = 6) {
        self.track = track
        self.directory = directory
        self.trackOffset = trackOffset
        self.targetSeconds = targetSeconds
        self.searchSeconds = searchSeconds
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Appends samples and returns any chunks that became complete.
    public func append(_ newSamples: [Float]) -> [AudioChunk] {
        samples.append(contentsOf: newSamples)
        var chunks: [AudioChunk] = []
        let target = Int(targetSeconds * Double(Self.sampleRate))
        while buffered >= target {
            let cut = pauseCut(upTo: target) ?? quietestCut(upTo: target)
            guard let chunk = emit(count: cut) else { break }
            chunks.append(chunk)
        }
        if buffered > maxBufferedSamples {
            let excess = buffered - maxBufferedSamples
            head += excess
            writtenSamples += excess
            savedPartial = 0
        }
        if head > 0, head >= samples.count / 2 {
            samples.removeFirst(head)
            head = 0
        }
        if chunks.isEmpty, writeError == nil, buffered - savedPartial >= Self.partialInterval { writePartial() }
        return chunks
    }

    private var buffered: Int { samples.count - head }

    /// Seconds from meeting start to the end of the audio received so far.
    public var endOffset: TimeInterval {
        trackOffset + Double(writtenSamples + buffered) / Double(Self.sampleRate)
    }

    /// Writes whatever is buffered as the last chunk. Nil with `writeError` set when that write failed.
    public func flush() -> AudioChunk? {
        guard buffered > Self.sampleRate / 2 else {
            samples.removeAll()
            head = 0
            // A partial write of this tail would otherwise be found and transcribed as a chunk later.
            if savedPartial > 0 { removeFiles(of: nextURL) }
            savedPartial = 0
            return nil
        }
        return emit(count: buffered)
    }

    /// Ends the chunk in the middle of the last pause of at least 300 ms in the 10 s (or last third) before `target`, so no word is cut.
    /// Nil when nobody paused that long.
    private func pauseCut(upTo target: Int) -> Int? {
        let frame = Self.sampleRate / 50 // 20 ms
        let frames = min(target / 3, 10 * Self.sampleRate) / frame
        guard frames > 15 else { return nil }
        let first = head + target - frames * frame
        let levels = (0..<frames).map { index -> Float in
            var energy: Float = 0
            for i in (first + index * frame)..<(first + (index + 1) * frame) { energy += samples[i] * samples[i] }
            return (energy / Float(frame)).squareRoot()
        }
        // Quiet relative to this stretch's own floor, so background hiss still counts as a pause.
        let threshold = max(0.006, 1.5 * (levels.min() ?? 0))
        // Steady sound (music, a held tone) has no pause to find.
        guard threshold < 0.5 * (levels.max() ?? 0) else { return nil }
        var runEnd: Int?
        var index = frames - 1
        while index >= 0 {
            if levels[index] < threshold {
                if runEnd == nil { runEnd = index }
                if let end = runEnd, end - index + 1 >= 15, index == 0 || levels[index - 1] >= threshold {
                    return target - frames * frame + (index + end + 1) * frame / 2
                }
            } else if let end = runEnd {
                if end - index >= 15 { return target - frames * frame + (index + 1 + end + 1) * frame / 2 }
                runEnd = nil
            }
            index -= 1
        }
        return nil
    }

    private func quietestCut(upTo target: Int) -> Int {
        let window = Self.sampleRate / 10 // 100 ms
        let searchStart = max(window, target - Int(searchSeconds * Double(Self.sampleRate)))
        var bestEnd = target
        var bestEnergy = Float.greatestFiniteMagnitude
        var end = target
        while end - window >= searchStart {
            var energy: Float = 0
            for i in (head + end - window)..<(head + end) { energy += samples[i] * samples[i] }
            if energy < bestEnergy {
                bestEnergy = energy
                bestEnd = end - window / 2
            }
            end -= window
        }
        return bestEnd
    }

    private var nextURL: URL { directory.appendingPathComponent(String(format: "%@-%04d.wav", track.rawValue, index + 1)) }

    private func removeFiles(of url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("json"))
    }

    /// Saves the chunk in progress under its final name. If the app dies, recovery transcribes it like any chunk;
    /// otherwise `emit` overwrites it with the finished chunk.
    private func writePartial() {
        let piece = Array(samples[head...])
        let chunk = AudioChunk(track: track, index: index + 1, url: nextURL,
                               startOffset: trackOffset + Double(writtenSamples) / Double(Self.sampleRate),
                               duration: Double(piece.count) / Double(Self.sampleRate), rms: WAVFile.rms(piece))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try WAVFile.write(piece, sampleRate: Self.sampleRate, to: nextURL)
            try JSONEncoder().encode(chunk).write(to: nextURL.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
            savedPartial = piece.count
        } catch {
            // Not fatal: the chunk is written in full when it ends.
        }
    }

    /// Writes the first `count` samples. On a disk error nothing is consumed, so the audio is retried later.
    private func emit(count: Int) -> AudioChunk? {
        let piece = Array(samples[head..<(head + count)])
        let start = trackOffset + Double(writtenSamples) / Double(Self.sampleRate)
        let url = nextURL
        let chunk = AudioChunk(track: track, index: index + 1, url: url, startOffset: start,
                               duration: Double(count) / Double(Self.sampleRate), rms: WAVFile.rms(piece))
        let sidecar = url.deletingPathExtension().appendingPathExtension("json")
        // A sidecar already here belongs to the partial write of this chunk, whose audio is still on disk.
        let sidecarExisted = FileManager.default.fileExists(atPath: sidecar.path)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Sidecar metadata lets saved audio be retranscribed later with correct timing; without it the WAV can't be found.
            // Written after the WAV, so a kill between the two never leaves a sidecar claiming more audio than the WAV holds.
            try WAVFile.write(piece, sampleRate: Self.sampleRate, to: url)
            try JSONEncoder().encode(chunk).write(to: sidecar, options: .atomic)
        } catch {
            writeError = error.localizedDescription
            if !sidecarExisted { try? FileManager.default.removeItem(at: sidecar) }
            return nil
        }
        writeError = nil
        head += count
        writtenSamples += count
        index += 1
        savedPartial = 0
        return chunk
    }
}

public enum WAVFile {
    /// Writes 16-bit PCM mono WAV.
    public static func write(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        try data.write(to: url, options: .atomic)
    }

    /// Samples of a 16-bit mono WAV written by `write`.
    /// Compressed chunks (see `AudioCompression`) are decoded.
    public static func read(_ url: URL) throws -> [Float] {
        if AudioCompression.isCompressed(url) { return try AudioCompression.decode(url) }
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { return [] }
        return data.dropFirst(44).withUnsafeBytes { bytes in
            (0..<(bytes.count / 2)).map { Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / Float(Int16.max) }
        }
    }

    /// Writes one track's chunks as a single WAV on the meeting timeline: each chunk at its offset, silence in the gaps.
    /// Streams the samples, so an hour of audio never sits in memory. Returns the length in seconds.
    @discardableResult
    public static func writeTimeline(_ chunks: [AudioChunk], sampleRate: Int = ChunkWriter.sampleRate, to url: URL) throws -> TimeInterval {
        let sorted = chunks.sorted { $0.startOffset < $1.startOffset }
        let total = sorted.map { Int((($0.startOffset + $0.duration) * Double(sampleRate)).rounded()) }.max() ?? 0
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        let byteCount = UInt32(total * 2)
        header.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + byteCount)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        header.append(contentsOf: Array("data".utf8)); append(byteCount)
        FileManager.default.createFile(atPath: url.path, contents: header)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var written = 0
        func silence(_ count: Int) throws {
            var remaining = count
            while remaining > 0 {
                let piece = min(remaining, sampleRate * 10)
                try handle.write(contentsOf: Data(count: piece * 2))
                remaining -= piece
            }
        }
        for chunk in sorted {
            let start = Int((chunk.startOffset * Double(sampleRate)).rounded())
            guard let pcm16 = try? pcm(of: chunk.url), !pcm16.isEmpty else { continue }
            var pcm = pcm16
            if start > written { try silence(start - written) }
            // Chunks of one track don't overlap; if rounding makes them, the later one loses its first samples.
            let skip = max(0, written - start)
            pcm = pcm.dropFirst(skip * 2)
            let usable = min(pcm.count / 2, total - max(written, start))
            guard usable > 0 else { continue }
            try handle.write(contentsOf: pcm.prefix(usable * 2))
            written = max(written, start) + usable
        }
        if total > written { try silence(total - written) }
        return Double(total) / Double(sampleRate)
    }

    /// The 16-bit samples of a chunk, WAV or compressed.
    static func pcm(of url: URL) throws -> Data {
        guard AudioCompression.isCompressed(url) else { return try Data(contentsOf: url).dropFirst(44) }
        var data = Data()
        for sample in try AudioCompression.decode(url) {
            withUnsafeBytes(of: Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Length of a 16-bit mono WAV written by `write`, from its file size.
    public static func duration(of url: URL, sampleRate: Int = ChunkWriter.sampleRate) -> TimeInterval {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Double(max(0, size - 44)) / Double(sampleRate * 2)
    }

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}

public enum AudioChunkScanner {
    /// Saved chunks of a meeting, read from their sidecar files, in recording order.
    public static func chunks(in directory: URL) -> [AudioChunk] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> AudioChunk? in
                guard let data = try? Data(contentsOf: url), var chunk = try? JSONDecoder().decode(AudioChunk.self, from: data) else { return nil }
                // The folder may have moved since recording; trust the sidecar's neighbour, not the stored path.
                guard let audio = AudioCompression.audioFile(forSidecar: url) else { return nil }
                chunk.url = audio
                return chunk
            }
            .sorted { ($0.startOffset, $0.track.rawValue) < ($1.startOffset, $1.track.rawValue) }
    }
}
