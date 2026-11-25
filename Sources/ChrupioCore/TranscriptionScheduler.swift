import Foundation
import Observation

/// The recognizers and audio cleanup a chunk goes through; the app passes whisper, Parakeet and the echo canceller,
/// tests pass fakes.
public protocol SpeechEngines: Sendable {
    func whisper(_ wav: URL, transcriber: Transcriber) async throws -> Transcription
    /// One chunk on Parakeet, reported in `language`. Throws when the models are missing or CoreML fails.
    func parakeet(_ wav: URL, language: String?, chunk: AudioChunk, vocabulary: [String],
                  aliases: [String: [String]]) async throws -> Transcription
    /// The mic chunk without the call audio it picked up; nil means transcribe the original.
    func removeEcho(_ chunk: AudioChunk) async -> URL?
}

/// What one chunk's transcription needs, fixed on the main actor just before it starts.
public struct TranscriptionJob: Sendable {
    public var transcriber: Transcriber
    public var routing: EngineRouting
    /// Passed explicitly so a chunk never boosts another meeting's names through the global list.
    public var boostTerms: [String] = []
    public var boostAliases: [String: [String]] = [:]
    public var cancelEcho = false
    public var correct: (@Sendable (String) -> String)?

    public init(transcriber: Transcriber, routing: EngineRouting) {
        self.transcriber = transcriber
        self.routing = routing
    }
}

/// Transcribes queued chunks one at a time, off the main actor, choosing whisper or Parakeet per chunk.
/// Each meeting keeps the transcriber and routing it had when its audio was queued, so changing the model
/// mid-meeting can't break it.
@MainActor
@Observable
public final class TranscriptionScheduler {
    public private(set) var queue = ChunkQueue()
    public private(set) var isTranscribing = false
    @ObservationIgnored private var transcribers: [UUID: Transcriber] = [:]
    @ObservationIgnored private var routings: [UUID: EngineRouting] = [:]
    @ObservationIgnored private let engines: SpeechEngines

    /// Whether a chunk may start now; nothing transcribes during a call.
    @ObservationIgnored public var mayStart: () -> Bool = { true }
    /// The transcriber for a chunk whose meeting has none fixed.
    @ObservationIgnored public var makeTranscriber: () -> Transcriber
    /// Fills in the meeting's names, language and boosting for the job about to run; the meeting may be unknown.
    @ObservationIgnored public var prepareJob: (inout TranscriptionJob, AudioChunk, UUID?) -> Void = { _, _, _ in }
    /// A chunk is done, transcribed or not, after the given wall-clock seconds; the meeting is nil when it was no longer queued. The next chunk starts after.
    @ObservationIgnored public var onFinished: (AudioChunk, UUID?, Result<TranscriptionPipeline.ChunkResult, Error>, SpeechEngine, TimeInterval) -> Void = { _, _, _, _, _ in }

    public init(engines: SpeechEngines, makeTranscriber: @escaping () -> Transcriber) {
        self.engines = engines
        self.makeTranscriber = makeTranscriber
    }

    /// Fixes the transcriber and routing a meeting's chunks use until it finishes.
    public func fix(_ meetingID: UUID, transcriber: Transcriber, routing: EngineRouting) {
        transcribers[meetingID] = transcriber
        routings[meetingID] = routing
    }

    /// - Parameter first: goes ahead of the queue.
    public func enqueue(_ chunk: AudioChunk, for meetingID: UUID, first: Bool = false) {
        queue.enqueue(chunk, for: meetingID, first: first)
    }

    public func startFinishing(_ meetingID: UUID) { queue.startFinishing(meetingID) }

    /// Ends the meeting's turn and forgets its transcriber; returns how many of its chunks failed.
    public func finish(_ meetingID: UUID) -> Int {
        transcribers[meetingID] = nil
        routings[meetingID] = nil
        return queue.finish(meetingID)
    }

    /// Starts the next chunk unless one is running or `mayStart` says wait.
    public func processJobs() {
        guard !isTranscribing, mayStart(), let chunk = queue.next() else { return }
        isTranscribing = true
        let owner = queue.meeting(of: chunk)
        var job = TranscriptionJob(transcriber: owner.flatMap { transcribers[$0] } ?? makeTranscriber(),
                                   routing: owner.flatMap { routings[$0] } ?? EngineRouting(parakeetEnabled: false))
        prepareJob(&job, chunk, owner)
        let engines = engines
        // Off the main actor: decoding a compressed chunk, reading samples for voice features and building the
        // lines are CPU and disk work that must never stall the UI or the recorder's deliveries.
        Task.detached(priority: .userInitiated) {
            let started = ContinuousClock.now
            let (result, engine) = await Self.run(chunk, job: job, engines: engines)
            let elapsed = ContinuousClock.now - started
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            await self.finished(chunk, result: result, engine: engine, seconds: seconds)
        }
    }

    private func finished(_ chunk: AudioChunk, result: Result<TranscriptionPipeline.ChunkResult, Error>, engine: SpeechEngine, seconds: TimeInterval) {
        isTranscribing = false
        defer { processJobs() }
        let failed = if case .failure = result { true } else { false }
        onFinished(chunk, queue.completed(chunk, failed: failed), result, engine, seconds)
    }

    /// Echo removal or decoding, then the engines, then the chunk's lines.
    nonisolated static func run(_ chunk: AudioChunk, job: TranscriptionJob,
                                engines: SpeechEngines) async -> (Result<TranscriptionPipeline.ChunkResult, Error>, SpeechEngine) {
        let cleaned = job.cancelEcho ? await engines.removeEcho(chunk) : nil
        defer { if let cleaned { try? FileManager.default.removeItem(at: cleaned) } }
        // A compressed chunk (a retranscribe after the retention pass) is decoded for whisper and Parakeet.
        var decoded: (url: URL, cleanup: @Sendable () -> Void)?
        if cleaned == nil {
            do { decoded = try AudioCompression.temporaryWAV(for: chunk.url) } catch {
                CoreLog.coordinator.error("decoding \(chunk.url.lastPathComponent, privacy: .public) failed, transcribing the file as is: \(error.localizedDescription, privacy: .public)")
            }
        }
        defer { decoded?.cleanup() }
        let wav = cleaned ?? decoded?.url ?? chunk.url
        let (transcription, engine) = await transcribe(wav, chunk: chunk, job: job, engines: engines)
        return (transcription.map { TranscriptionPipeline.prepare(chunk, transcription: $0, correct: job.correct) }, engine)
    }

    /// Parakeet first when Settings say every chunk is Polish, else whisper; a Parakeet failure falls back to whisper,
    /// and a chunk whisper heard as Polish is redone on Parakeet, keeping whisper's text if that fails.
    public nonisolated static func transcribe(_ wav: URL, chunk: AudioChunk, job: TranscriptionJob,
                                              engines: SpeechEngines) async -> (Result<Transcription, Error>, SpeechEngine) {
        let routing = job.routing
        var engine = routing.engine
        var parakeetFailed = false
        do {
            var transcription: Transcription?
            if engine == .parakeet {
                do {
                    transcription = try await engines.parakeet(wav, language: routing.language, chunk: chunk,
                                                               vocabulary: job.boostTerms, aliases: job.boostAliases)
                } catch {
                    parakeetFailed = true
                    CoreLog.coordinator.notice("chunk \(chunk.index, privacy: .public): Parakeet fallback to whisper")
                }
            }
            if transcription == nil {
                engine = .whisper
                let whisper = try await engines.whisper(wav, transcriber: job.transcriber)
                transcription = whisper
                // The next chunk is detected again. A chunk whose Parakeet pass just failed is not retried.
                if !parakeetFailed, let language = routing.parakeetLanguage(after: whisper) {
                    do {
                        transcription = try await engines.parakeet(wav, language: language, chunk: chunk,
                                                                   vocabulary: job.boostTerms, aliases: job.boostAliases)
                        engine = .parakeet
                    } catch {
                        CoreLog.coordinator.notice("chunk \(chunk.index, privacy: .public): keeping whisper's \(language, privacy: .public) text, Parakeet redo failed")
                    }
                }
            }
            guard let transcription else { throw CancellationError() }
            return (.success(transcription), engine)
        } catch {
            return (.failure(error), engine)
        }
    }
}
