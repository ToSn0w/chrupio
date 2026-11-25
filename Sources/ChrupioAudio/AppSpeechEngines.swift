import Foundation
import ChrupioCore
import os

private let log = Logger(subsystem: "Chrupio", category: "coordinator")

/// whisper.cpp, Parakeet and the echo canceller for the transcription scheduler.
public struct AppSpeechEngines: SpeechEngines {
    public init() {}

    public func whisper(_ wav: URL, transcriber: Transcriber) async throws -> Transcription {
        try await transcriber.transcribeDetectingLanguage(wav: wav)
    }

    /// Missing models (downloading now) or a CoreML error throw, and whisper's lines are kept: nothing is lost.
    public func parakeet(_ wav: URL, language: String?, chunk: AudioChunk, vocabulary: [String], aliases: [String: [String]]) async throws -> Transcription {
        do {
            var transcription = try await ParakeetTranscriber.shared.transcribe(wav: wav, language: language,
                                                                                vocabulary: vocabulary, aliases: aliases)
            transcription.language = language
            return transcription
        } catch {
            log.error("Parakeet failed on \(chunk.url.lastPathComponent, privacy: .public), using whisper: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Reads the system chunks on disk, so the last few seconds of a live call may have no reference yet;
    /// the text-based echo removal at the end still covers those.
    public func removeEcho(_ chunk: AudioChunk) async -> URL? {
        let system = AudioChunkScanner.chunks(in: chunk.url.deletingLastPathComponent()).filter { $0.track == .system }
        do {
            return try await EchoCanceller.shared.clean(chunk, system: system)
        } catch {
            log.error("echo removal failed, using the original audio: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
