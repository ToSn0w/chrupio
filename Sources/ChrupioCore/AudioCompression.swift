import AVFoundation
import Foundation

/// Finished meetings keep their chunks as Opus in CAF (about 24 kbps mono, a tenth of the 16 kHz WAV).
/// Every reader goes through `WAVFile.read`, `WAVFile.writeTimeline` or `temporaryWAV`, which accept both.
public enum AudioCompression {
    public static let fileExtension = "caf"
    public static let bitRate = 24_000

    public static func isCompressed(_ url: URL) -> Bool { url.pathExtension == fileExtension }

    /// The chunk's audio file next to a sidecar: the WAV while it exists, else the compressed copy.
    public static func audioFile(forSidecar sidecar: URL) -> URL? {
        let wav = sidecar.deletingPathExtension().appendingPathExtension("wav")
        if FileManager.default.fileExists(atPath: wav.path) { return wav }
        let compressed = sidecar.deletingPathExtension().appendingPathExtension(fileExtension)
        return FileManager.default.fileExists(atPath: compressed.path) ? compressed : nil
    }

    /// Cheap (one directory listing): a meeting has audio when any chunk, WAV or compressed, is there.
    public static func hasAudio(in directory: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.contains { $0.hasSuffix(".wav") || $0.hasSuffix("." + fileExtension) }
    }

    /// WAV chunks still to compress, without the ones that failed before (see `skipped`).
    public static func uncompressed(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let skip = skipped(in: directory)
        return files.filter { $0.pathExtension == "wav" && !skip.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func hasUncompressed(in directory: URL) -> Bool { !uncompressed(in: directory).isEmpty }

    /// Chunks that failed or hung once stay WAV for good: Core Audio's Opus decoder hangs forever on some
    /// encodings, the same way on every try. Listed one name per line in `audio/.compress-skipped`.
    static let skipListName = ".compress-skipped"

    public static func skipped(in directory: URL) -> Set<String> {
        let text = (try? String(contentsOf: directory.appendingPathComponent(skipListName), encoding: .utf8)) ?? ""
        return Set(text.split(separator: "\n").map(String.init))
    }

    public static func markSkipped(_ wav: URL) {
        let directory = wav.deletingLastPathComponent()
        var names = skipped(in: directory)
        names.insert(wav.lastPathComponent)
        try? (names.sorted().joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent(skipListName), atomically: true, encoding: .utf8)
    }

    public enum Failure: Error, LocalizedError {
        case encoder, roundTrip(URL), implausible(URL)
        public var errorDescription: String? {
            switch self {
            case .encoder: "the Opus encoder is unavailable"
            case .roundTrip(let url): "\(url.lastPathComponent) did not decode back to the same length"
            case .implausible(let url): "\(url.lastPathComponent) reports more audio than a chunk can hold"
            }
        }
    }

    /// Re-encodes one WAV chunk; the WAV is removed only after the copy decodes to the same length.
    @discardableResult
    public static func compress(_ wav: URL) throws -> URL {
        try compress(wav, install: { try $0() })
    }

    /// The temporary copy `compress` encodes into; left behind only when the encoder was killed mid-write.
    public static func partialURL(for wav: URL) -> URL {
        wav.deletingLastPathComponent().appendingPathComponent(".partial-\(wav.deletingPathExtension().lastPathComponent).\(fileExtension)")
    }

    /// Encodes and checks the copy outside any lock; `install` wraps only the swap of the WAV for the copy, and the
    /// swap is skipped (returning the WAV) when the WAV changed or moved meanwhile.
    static func compress(_ wav: URL, install: (() throws -> Void) throws -> Void) throws -> URL {
        let before = try FileManager.default.attributesOfItem(atPath: wav.path)
        let samples = try WAVFile.read(wav)
        let target = wav.deletingPathExtension().appendingPathExtension(fileExtension)
        let partial = partialURL(for: wav)
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }
        try encode(samples, to: partial)
        try stripFreeChunks(partial)
        let decoded = try decode(partial)
        // Opus works in 20 ms frames: the copy may differ by a frame or two, never more.
        guard abs(decoded.count - samples.count) <= ChunkWriter.sampleRate / 10 else { throw Failure.roundTrip(wav) }
        var installed = false
        try install {
            // A split in chrupio-mcp may have cut or moved the chunk while it was encoding.
            guard let now = try? FileManager.default.attributesOfItem(atPath: wav.path),
                  now[.size] as? Int == before[.size] as? Int, now[.modificationDate] as? Date == before[.modificationDate] as? Date
            else { return }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: partial, to: target)
            try FileManager.default.removeItem(at: wav)
            installed = true
        }
        return installed ? target : wav
    }

    /// Compresses every WAV chunk in a meeting's audio folder; returns how many were done.
    @discardableResult
    public static func compressMeeting(audio directory: URL) throws -> Int {
        var done = 0
        for wav in uncompressed(in: directory) {
            try compress(wav)
            done += 1
        }
        return done
    }

    static func encode(_ samples: [Float], to url: URL) throws {
        let rate = Double(ChunkWriter.sampleRate)
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else {
            throw Failure.encoder
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatOpus, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: bitRate,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let step = ChunkWriter.sampleRate * 10
        var start = 0
        while start < samples.count {
            let count = min(step, samples.count - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(count)) else { throw Failure.encoder }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress! + start, count: count)
            }
            try file.write(from: buffer)
            start += count
        }
        file.close()
    }

    /// Core Audio reserves ~240 KB of `free` padding in a CAF for the packet table, ten times the audio of a
    /// 30 s chunk. Chunks are never appended to, so the padding is dropped (CAF readers skip `free` anyway).
    static func stripFreeChunks(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= 8, data.prefix(4) == Data("caff".utf8) else { return }
        var output = data.prefix(8)
        var offset = 8
        var stripped = false
        while offset + 12 <= data.count {
            let type = data.subdata(in: offset..<offset + 4)
            let declared = data.subdata(in: offset + 4..<offset + 12).reduce(Int64(0)) { $0 << 8 | Int64($1) }
            // A size of -1 (only allowed for the last, `data`, chunk) runs to the end of the file.
            let end = declared < 0 ? data.count : min(data.count, offset + 12 + Int(declared))
            if type == Data("free".utf8) { stripped = true } else { output.append(data.subdata(in: offset..<end)) }
            offset = end
        }
        if stripped { try output.write(to: url, options: .atomic) }
    }

    /// Longest audio a compressed chunk may hold. Chunks are about 30 s; a write backlog never exceeds 20 minutes.
    public static let maxDecodedSeconds: Double = 20 * 60

    /// 16 kHz mono samples of a compressed chunk, read 10 s at a time. A damaged file can report an absurd length
    /// (one such file once made the process allocate 82 GB), so the length is checked before anything is allocated and the read stops
    /// at `maxDecodedSeconds` whatever the header says.
    static func decode(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let limit = AVAudioFramePosition(maxDecodedSeconds * format.sampleRate)
        guard format.sampleRate > 0, file.length >= 0, file.length <= limit else { throw Failure.implausible(url) }
        let block = AVAudioFrameCount(max(1, format.sampleRate * 10))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) else { throw Failure.encoder }
        var channel: [Float] = []
        channel.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: block)
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            guard channel.count + count <= Int(limit) else { throw Failure.implausible(url) }
            channel.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count))
        }
        guard format.sampleRate != Double(ChunkWriter.sampleRate) else { return channel }
        // Not written by `encode`: resample by nearest sample, enough for speech models.
        let ratio = format.sampleRate / Double(ChunkWriter.sampleRate)
        return (0..<Int(Double(channel.count) / ratio)).map { channel[min(channel.count - 1, Int(Double($0) * ratio))] }
    }

    /// A WAV for readers that need one (whisper upload, Parakeet, echo removal). The cleanup removes a decoded copy;
    /// for a WAV chunk it does nothing.
    public static func temporaryWAV(for url: URL) throws -> (url: URL, cleanup: @Sendable () -> Void) {
        guard isCompressed(url) else { return (url, {}) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("chrupio-decoded-\(UUID().uuidString).wav")
        try WAVFile.write(try decode(url), sampleRate: ChunkWriter.sampleRate, to: temp)
        return (temp, { try? FileManager.default.removeItem(at: temp) })
    }
}

/// When transcribed meetings get compressed, and when old audio goes. Transcripts are always kept.
public enum AudioRetention {
    public static let deleteAfter: TimeInterval = 30 * 86_400
    public static let interval: TimeInterval = 86_400

    public enum Action: Equatable, Sendable {
        case delete(UUID), compress(UUID)
        public var meetingID: UUID { switch self { case .delete(let id), .compress(let id): id } }
    }

    public static func isDue(lastRun: Date?, now: Date) -> Bool {
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= interval
    }

    /// Whether the action may run now. Nothing working on the meeting is enough: a failed or stuck meeting would
    /// otherwise keep ~230 MB/h of WAV forever. Compression also needs a transcript, so audio that was never
    /// transcribed stays lossless for a retry; compressed chunks still retranscribe.
    public static func allows(_ action: Action, _ meeting: Meeting, busy: Bool) -> Bool {
        guard !busy else { return false }
        switch action {
        case .delete: return true
        case .compress: return !meeting.segments.isEmpty
        }
    }

    /// Deletions first (they free the most), then compressions, oldest meetings first.
    public static func plan(_ meetings: [Meeting], now: Date, hasAudio: (UUID) -> Bool, hasUncompressed: (UUID) -> Bool,
                            isBusy: (UUID) -> Bool) -> [Action] {
        var deletions: [Action] = [], compressions: [Action] = []
        for meeting in meetings.sorted(by: { $0.startedAt < $1.startedAt }) where !isBusy(meeting.id) {
            if now.timeIntervalSince(meeting.startedAt) > deleteAfter {
                if hasAudio(meeting.id) { deletions.append(.delete(meeting.id)) }
            } else if allows(.compress(meeting.id), meeting, busy: false), hasUncompressed(meeting.id) {
                compressions.append(.compress(meeting.id))
            }
        }
        return deletions + compressions
    }
}

extension MeetingStore {
    /// Compresses a meeting's WAV chunks one at a time in this process. Returns how many were compressed.
    @discardableResult
    public func compressAudio(_ id: UUID) throws -> Int {
        var done = 0
        for wav in AudioCompression.uncompressed(in: audioDirectory(for: id)) where try compressChunk(wav) {
            done += 1
        }
        return done
    }

    /// One chunk; the write lock is held only for the file swap, so a hung encoder never blocks a save.
    /// False when the chunk changed meanwhile and was left as it is.
    public func compressChunk(_ wav: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: wav.path) else { return false }
        return try AudioCompression.compress(wav, install: { swap in try withWriteLock(swap) }) != wav
    }

    /// Compresses each chunk in a child process (`executable arguments… <wav>`) killed after `timeout`, so a decoder
    /// that never returns costs one chunk, not the app. A chunk that fails or times out is never tried again.
    @discardableResult
    public func compressAudioIsolated(_ id: UUID, executable: URL, arguments: [String], timeout: TimeInterval) -> (done: Int, skipped: [String]) {
        var done = 0, skipped: [String] = []
        for wav in AudioCompression.uncompressed(in: audioDirectory(for: id)) {
            switch ChildProcess.run(executable, arguments: arguments + [wav.path], timeout: timeout) {
            case .exited(0):
                if !FileManager.default.fileExists(atPath: wav.path) { done += 1 }
            case .exited, .timedOut, .couldNotStart:
                // Killed mid-encode: the copy is half written.
                try? FileManager.default.removeItem(at: AudioCompression.partialURL(for: wav))
                AudioCompression.markSkipped(wav)
                skipped.append(wav.lastPathComponent)
            }
        }
        return (done, skipped)
    }
}

/// Runs a helper and kills it when it outlives its deadline.
public enum ChildProcess {
    public enum Outcome: Equatable, Sendable { case exited(Int32), timedOut, couldNotStart }

    public static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return .couldNotStart }
        if finished.wait(timeout: .now() + timeout) == .success { return .exited(process.terminationStatus) }
        // SIGKILL: a thread stuck inside Core Audio may not act on SIGTERM. The kernel drops its flock with it.
        kill(process.processIdentifier, SIGKILL)
        finished.wait()
        return .timedOut
    }
}
