import FluidAudio
import Foundation
import ChrupioCore

/// Removes the call audio that leaked from the speakers into the mic, with FluidAudio's LocalVQE model.
/// The model is downloaded once (to ~/Library/Application Support/FluidAudio); it then runs on this Mac.
public actor EchoCanceller {
    public static let shared = EchoCanceller()

    private var manager: LocalVqeManager?

    /// Loads the model (downloading it if needed). Called on first use, so the model isn't in memory until a call
    /// needs echo removal.
    public func prepare() async throws {
        guard manager == nil else { return }
        manager = try await LocalVqeManager()
    }

    /// Fetches the model files at launch without loading them.
    public static func download() async throws {
        let config = LocalVqeConfig.default
        let models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
        let file = ModelNames.LocalVQE.modelFile(variant: config.variant, chunk: config.chunk)
        guard !FileManager.default.fileExists(atPath: models.appendingPathComponent(Repo.localVqe.folderName).appendingPathComponent(file).path) else { return }
        try await ModelHub.download(.localVqe, to: models, variant: ModelNames.LocalVQE.variantKey(variant: config.variant, chunk: config.chunk))
    }

    /// Frees the model between meetings; the next `clean` loads it again.
    public func release() { manager = nil }

    /// A cleaned copy of the mic chunk in a temporary WAV, or nil when the call audio was silent.
    /// The caller deletes the file; the saved recording is never changed.
    public func clean(_ mic: AudioChunk, system: [AudioChunk]) async throws -> URL? {
        guard let reference = EchoReference.samples(for: mic, system: system) else { return nil }
        var samples = try WAVFile.read(mic.url)
        guard !samples.isEmpty else { return nil }
        let length = min(samples.count, reference.count)
        samples.removeLast(samples.count - length)
        try await prepare()
        guard let manager else { return nil }
        let cleaned = try await manager.process(mic: samples, reference: Array(reference.prefix(length)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chrupio-clean-\(UUID().uuidString).wav")
        try WAVFile.write(cleaned, sampleRate: ChunkWriter.sampleRate, to: url)
        return url
    }
}
