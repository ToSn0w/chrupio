import FluidAudio
import Foundation
import ChrupioCore
import os

private let log = Logger(subsystem: "Chrupio", category: "parakeet")

public enum ParakeetError: LocalizedError {
    case modelsMissing

    public var errorDescription: String? {
        switch self {
        case .modelsMissing: "The Parakeet speech model isn't downloaded yet; it is downloading now."
        }
    }
}

/// Transcribes Polish calls with Parakeet Ultra, a post-trained Parakeet TDT v3 (FluidAudio, CoreML). The models (about 0.6 GB) are downloaded
/// once, the first time a Polish chunk needs them, to ~/Library/Application Support/FluidAudio (whisper takes those chunks
/// meanwhile); they then run on this Mac.
public actor ParakeetTranscriber {
    public static let shared = ParakeetTranscriber()

    private var manager: AsrManager?
    /// Fetches the models the first time a Polish chunk needs them; a failed download is tried again on the next chunk.
    private let download = OnDemandDownload(isPresent: { ParakeetTranscriber.isDownloaded },
                                            download: { try await ParakeetTranscriber.downloadModels() },
                                            onFinish: { error in
                                                if let error {
                                                    log.error("Parakeet model download failed: \(error.localizedDescription, privacy: .public)")
                                                } else {
                                                    log.info("Parakeet models downloaded")
                                                }
                                            })
    /// The CTC keyword-spotting model (Parakeet CTC 110M, about 100 MB) behind vocabulary boosting.
    private var ctcModels: CtcModels?
    private var ctcDownload: Task<Void, Never>?
    /// The boosting session for the last vocabulary; rebuilt when the vocabulary changes.
    private var boosting: (terms: [String], aliases: [String: [String]], session: VocabularyBoostingSession)?

    public init() {}

    /// The Parakeet checkpoint: Ultra (about 614 MB), a post-trained Parakeet TDT v3 that shares v3's tokenizer and decoder,
    /// so CTC vocabulary boosting works with it.
    private static let modelVersion: AsrModelVersion = .ultra

    public static var modelsDirectory: URL { AsrModels.defaultCacheDirectory(for: modelVersion) }
    public static var isDownloaded: Bool { AsrModels.modelsExist(at: modelsDirectory, version: modelVersion) }

    /// Downloads the transcription model if it is missing; does nothing when it is there. The CTC vocabulary model is
    /// left to `startCtcDownload`, its only fetcher inside the app, so the two never download it at the same time.
    public static func downloadModels() async throws {
        try await AsrModels.download(version: modelVersion)
    }

    /// Downloads the CTC vocabulary model. For `--download-parakeet` only, which runs without the app.
    public static func downloadVocabularyModel() async throws {
        _ = try await CtcModels.download(variant: .ctc110m)
    }

    public static var ctcModelsDownloaded: Bool { CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory(for: .ctc110m)) }

    /// Loads the models. When they are missing, starts downloading them in the background and throws,
    /// so the chunk goes to whisper instead of waiting.
    public func prepare() async throws {
        guard manager == nil else { return }
        guard await download.ensure() else {
            log.info("Parakeet models missing; downloading them while whisper transcribes")
            throw ParakeetError.modelsMissing
        }
        let models = try await AsrModels.load(from: Self.modelsDirectory, version: Self.modelVersion)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }


    /// Frees the models between meetings; the next `transcribe` loads them again.
    public func release() {
        ctcModels = nil
        boosting = nil
        guard let manager else { return }
        self.manager = nil
        Task { await manager.cleanup() }
    }

    /// Transcribes a WAV file; chunks are already 16 kHz mono, anything else is converted first. Parakeet doesn't detect the language, so `language` is only a hint
    /// that keeps out tokens in the wrong script, and the result reports no language.
    /// - Parameters:
    ///   - vocabulary: names and terms to boost; defaults to what the coordinator last set on the `Transcriber`.
    ///   - aliases: misheard forms per term (from the project's corrections), matched as that term.
    public func transcribe(wav: URL, language: String?, vocabulary: [String] = SpeechVocabulary.current,
                           aliases: [String: [String]] = [:]) async throws -> Transcription {
        try await prepare()
        guard let manager else { throw ParakeetError.modelsMissing }
        let samples = try AudioConverter().resampleAudioFile(wav)
        // Shorter than the model accepts (0.3 s or so): nothing worth transcribing.
        guard samples.count >= ASRConstants.minimumRequiredSamples(forSampleRate: ChunkWriter.sampleRate) else {
            return Transcription(speech: [], language: nil)
        }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state, language: language.flatMap(Language.init(rawValue:)))
        let timings = result.tokenTimings ?? []
        let tokens = timings.map { (text: $0.token, start: $0.startTime, end: $0.endTime) }
        var speech = ParakeetOutput.speech(tokens: tokens)
        if let session = await boostingSession(for: SpeechVocabulary.boostTerms(vocabulary + Array(aliases.keys)), aliases: aliases),
           let output = await session.rescore(text: result.text, tokenTimings: timings, audioSamples: samples) {
            let aliasIndex = BoostingGuard.aliasIndex(aliases)
            var rejected = 0
            let replacements = output.replacements.compactMap { item -> (original: String, replacement: String)? in
                guard item.shouldReplace, let term = item.replacementWord else { return nil }
                guard BoostingGuard.accepts(original: item.originalWord, replacement: term, aliases: aliasIndex[BoostingGuard.key(term)] ?? []) else {
                    rejected += 1
                    return nil
                }
                return (original: item.originalWord, replacement: term)
            }
            if rejected > 0 { log.info("vocabulary boosting: \(rejected, privacy: .public) replacement(s) rejected by the guard") }
            if !replacements.isEmpty {
                log.info("vocabulary boosting replaced \(replacements.count, privacy: .public) word(s)")
                speech = ParakeetOutput.applying(replacements: replacements, to: speech)
            }
        }
        return Transcription(speech: speech, language: nil)
    }

    /// Batch vocabulary boosting (CTC keyword spotting plus rescoring). Nil without terms, while the CTC model is
    /// still downloading, or when it fails to load: the chunk is then transcribed without boosting.
    private func boostingSession(for terms: [String], aliases: [String: [String]]) async -> VocabularyBoostingSession? {
        guard !terms.isEmpty else { return nil }
        if let boosting, boosting.terms == terms, boosting.aliases == aliases { return boosting.session }
        do {
            if ctcModels == nil {
                guard Self.ctcModelsDownloaded else {
                    startCtcDownload()
                    return nil
                }
                ctcModels = try await CtcModels.load(from: CtcModels.defaultCacheDirectory(for: .ctc110m), variant: .ctc110m)
            }
            guard let ctcModels else { return nil }
            let vocabulary = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0, aliases: aliases[$0]) })
            let session = try await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: ctcModels)
            boosting = (terms, aliases, session)
            return session
        } catch {
            log.error("vocabulary boosting unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func startCtcDownload() {
        guard ctcDownload == nil else { return }
        ctcDownload = Task.detached(priority: .utility) {
            do {
                _ = try await CtcModels.download(variant: .ctc110m)
                log.info("CTC vocabulary model downloaded")
            } catch {
                log.error("CTC vocabulary model download failed: \(error.localizedDescription, privacy: .public)")
            }
            await ParakeetTranscriber.shared.ctcDownloadEnded()
        }
    }

    private func ctcDownloadEnded() { ctcDownload = nil }
}
