import Foundation
import os

private let pipelineLog = Logger(subsystem: "Chrupio", category: "recorder")

/// Hands 16 kHz samples from the recorder's queue to the tracks' `ChunkWriter`s on a dedicated serial writer queue,
/// so a slow disk never stalls audio processing. A chunk reaches `onChunk` (on the writer queue) only after its WAV
/// and sidecar are on disk. What waits for the writer stays in memory, at most a 2 hour meeting's worth.
/// `open`, `endOffset`, `append` and `finish` are called on one queue (the recorder's).
final class ChunkPipeline: @unchecked Sendable {
    typealias ChunkHandler = @Sendable (AudioChunk) -> Void

    /// A backlog longer than this many seconds of audio is logged.
    static let backlogWarningSeconds = 60

    private let directory: URL
    private let onChunk: ChunkHandler
    private let writerQueue = DispatchQueue(label: "chrupio.audio-writer", qos: .userInitiated)
    /// Writer queue only.
    private var writers: [AudioChunk.Track: ChunkWriter] = [:]
    /// Caller's queue: each track's start and samples handed over, so its end is known without asking the writer.
    private var feeds: [AudioChunk.Track: (offset: TimeInterval, samples: Int)] = [:]
    private var finished = false
    /// Samples handed over and not yet written, and whether that backlog was logged.
    private let backlog = OSAllocatedUnfairLock(initialState: (samples: 0, warned: false))
    private let errors = OSAllocatedUnfairLock(initialState: (current: [AudioChunk.Track: String](), final: String?.none))

    init(directory: URL, onChunk: @escaping ChunkHandler) {
        self.directory = directory
        self.onChunk = onChunk
    }

    /// Set while audio can't be written to disk (it stays buffered until writes succeed); after `finish`, set when
    /// the final chunks couldn't be written.
    var writeError: String? {
        errors.withLock { $0.current[.mic] ?? $0.current[.system] ?? $0.final }
    }

    /// Samples waiting for the writer queue.
    var pendingSamples: Int { backlog.withLock { $0.samples } }

    /// Starts a track at `offset` seconds from meeting start. A track already open keeps its writer, so a rebuilt
    /// device continues the numbering instead of overwriting chunks.
    func open(_ track: AudioChunk.Track, offset: TimeInterval) {
        guard !finished, feeds[track] == nil else { return }
        feeds[track] = (offset, 0)
        let directory = directory
        writerQueue.async { [self] in
            writers[track] = ChunkWriter(track: track, directory: directory, trackOffset: offset)
        }
    }

    /// Seconds from meeting start to the end of the audio handed over for `track`; nil before `open`.
    func endOffset(_ track: AudioChunk.Track) -> TimeInterval? {
        feeds[track].map { $0.offset + Double($0.samples) / Double(ChunkWriter.sampleRate) }
    }

    func append(_ samples: [Float], to track: AudioChunk.Track) {
        guard !finished, !samples.isEmpty, feeds[track] != nil else { return }
        feeds[track]?.samples += samples.count
        let warn = backlog.withLock { state -> Int? in
            state.samples += samples.count
            guard !state.warned, state.samples > Self.backlogWarningSeconds * ChunkWriter.sampleRate else { return nil }
            state.warned = true
            return state.samples
        }
        if let warn {
            pipelineLog.error("disk writes are \(warn / ChunkWriter.sampleRate, privacy: .public) s behind; audio waits in memory")
        }
        writerQueue.async { [self] in
            guard let writer = writers[track] else { return }
            let chunks = writer.append(samples)
            noteWritten(samples.count, error: writer.writeError, track: track)
            for chunk in chunks { onChunk(chunk) }
        }
    }

    /// Waits for every write handed over, writes what each track still buffers as its last chunk, and returns those
    /// chunks without passing them to `onChunk`. Later calls do nothing.
    func finish() -> [AudioChunk] {
        guard !finished else { return [] }
        finished = true
        return writerQueue.sync {
            var chunks: [AudioChunk] = []
            for track in [AudioChunk.Track.mic, .system] {
                guard let writer = writers[track] else { continue }
                if let last = writer.flush() { chunks.append(last) }
                // There is no later write to retry with, so the buffered audio is gone.
                if let error = writer.writeError { errors.withLock { $0.final = error } }
            }
            errors.withLock { $0.current = [:] }
            writers = [:]
            return chunks
        }
    }

    /// Writer queue.
    private func noteWritten(_ count: Int, error: String?, track: AudioChunk.Track) {
        errors.withLock { $0.current[track] = error }
        backlog.withLock { state in
            state.samples -= count
            if state.samples <= Self.backlogWarningSeconds * ChunkWriter.sampleRate / 2 { state.warned = false }
        }
    }
}
