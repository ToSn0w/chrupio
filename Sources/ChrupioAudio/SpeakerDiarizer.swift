import FluidAudio
import Foundation
import ChrupioCore

/// Tells remote voices apart with FluidAudio's offline diarizer (pyannote segmentation, WeSpeaker embeddings).
/// The models are downloaded once into Chrupio's models folder; after that everything runs on this Mac.
public enum SpeakerDiarizer {
    public static var modelsDirectory: URL { AppPaths.models.appendingPathComponent("diarizer", isDirectory: true) }

    /// Downloads the models if they are missing; runs at launch so the first meeting doesn't wait.
    public static func prepare() async throws {
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels(directory: modelsDirectory)
    }

    /// Diarizes the system track of a meeting from its saved chunks.
    /// `models` overrides the models folder (a read-only copy for offline runs on saved meetings).
    public static func diarize(_ chunks: [AudioChunk], models: URL? = nil) async throws -> Diarization {
        let system = chunks.filter { $0.track == .system && !$0.isSilent }
        guard !system.isEmpty else { return Diarization(turns: [], centroids: [:]) }
        // A fresh manager per meeting: it isn't Sendable, and loading the compiled models takes seconds at most.
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels(directory: models ?? modelsDirectory)
        let timeline = FileManager.default.temporaryDirectory.appendingPathComponent("chrupio-diarize-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: timeline) }
        try WAVFile.writeTimeline(system, to: timeline)
        let result = try await manager.process(timeline)
        let turns = result.segments.map {
            DiarizedTurn(start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds), cluster: $0.speakerId)
        }
        return Diarization(turns: turns, centroids: result.speakerDatabase ?? [:])
    }
}
