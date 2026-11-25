import Foundation

/// How a meeting's audio was transcribed: which engine did how many chunks and how long it took.
public struct TranscriptionStats: Codable, Sendable, Hashable {
    public var whisperChunks = 0
    public var parakeetChunks = 0
    public var failedChunks = 0
    /// Seconds of audio in the chunks counted.
    public var audioSeconds: TimeInterval = 0
    /// Wall-clock seconds spent on them, echo removal and decoding included. Failed chunks count too: their
    /// compute time and audio seconds are added, so a failing engine raises `realTimeFactor` like a slow one.
    public var computeSeconds: TimeInterval = 0
    /// The whisper model the meeting's transcriber used.
    public var whisperModel: String?

    public init() {}

    public mutating func record(engine: SpeechEngine, audioSeconds: TimeInterval, computeSeconds: TimeInterval, failed: Bool) {
        // Failed chunks are counted in both totals on purpose: the time was spent, so it belongs in the real-time factor.
        self.audioSeconds += audioSeconds
        self.computeSeconds += computeSeconds
        if failed { failedChunks += 1 } else if engine == .parakeet { parakeetChunks += 1 } else { whisperChunks += 1 }
    }

    /// Compute time over audio time; below 1 is faster than real time. Includes the time spent on failed chunks.
    public var realTimeFactor: Double { audioSeconds > 0 ? computeSeconds / audioSeconds : 0 }
}
