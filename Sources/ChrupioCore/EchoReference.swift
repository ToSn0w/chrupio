import Foundation

/// What the speakers played while a mic chunk was recorded, for removing that sound from the mic.
public enum EchoReference {
    /// Below this level the call audio is too quiet to leak into the mic.
    public static let silenceLevel: Float = 0.003

    /// The system track's samples for the mic chunk's time span, zero where nothing was recorded (yet).
    /// Nil when the call audio is silent over the whole span, so the mic is left as it is.
    public static func samples(for mic: AudioChunk, system: [AudioChunk], sampleRate: Int = ChunkWriter.sampleRate) -> [Float]? {
        let count = Int((mic.duration * Double(sampleRate)).rounded())
        guard count > 0 else { return nil }
        var reference = [Float](repeating: 0, count: count)
        var energy: Float = 0
        for chunk in system where chunk.track == .system && !chunk.isSilent
            && chunk.startOffset < mic.startOffset + mic.duration && chunk.startOffset + chunk.duration > mic.startOffset {
            guard let samples = try? WAVFile.read(chunk.url) else { continue }
            // Where this system chunk starts, in samples relative to the mic chunk (negative: before it).
            let shift = Int(((chunk.startOffset - mic.startOffset) * Double(sampleRate)).rounded())
            // A WAV shorter than its sidecar claims (cut off by a crash) may not reach the mic chunk at all.
            let first = max(0, -shift), end = min(samples.count, count - shift)
            guard first < end else { continue }
            for i in first..<end {
                reference[i + shift] = samples[i]
                energy += samples[i] * samples[i]
            }
        }
        let rms = (energy / Float(count)).squareRoot()
        return rms >= silenceLevel ? reference : nil
    }
}
