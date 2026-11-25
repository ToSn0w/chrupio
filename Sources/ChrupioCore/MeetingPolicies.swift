import Foundation

/// Decides when a meeting's language is pinned, and which language most of it was in.
/// Votes count moments of the call, not chunks: the mic and system chunks of one moment hear the same exchange,
/// so one English greeting used to count twice and pin English on a Polish call.
public struct LanguageVote: Sendable, Equatable {
    /// Chunks starting closer together than this are one moment.
    public static let moment: TimeInterval = 10
    /// Agreeing moments in a row needed to pin a language.
    public static let needed = 3

    private var streak: String?
    private var streakCount = 0
    private var lastMoment: TimeInterval?
    private var tally: [String: Int] = [:]
    /// The user's usual language. With one set nothing is pinned: each chunk is detected on its own and a wrong
    /// guess is redone in it, the meeting's language or English (see `Transcriber.fallbackLanguage`), so a call that
    /// mixes it with English keeps both.
    public var preferred: String?
    /// The first language heard in `needed` agreeing moments in a row, whether or not it was pinned.
    /// Picks the speech engine (`EngineRouting`) when a preferred language keeps the meeting from pinning.
    public private(set) var confirmed: String?

    public init(preferred: String? = nil) {
        self.preferred = preferred
    }

    /// Records one chunk's detection; returns the language to pin, if this chunk confirms it.
    public mutating func record(_ language: String?, speechCount: Int, at offset: TimeInterval) -> String? {
        guard let language, speechCount >= 2 else { return nil }
        if let lastMoment, abs(offset - lastMoment) < Self.moment { return nil }
        lastMoment = offset
        tally[language, default: 0] += 1
        if streak == language { streakCount += 1 } else { streak = language; streakCount = 1 }
        guard streakCount >= Self.needed else { return nil }
        if confirmed == nil { confirmed = language }
        return preferred == nil ? language : nil
    }

    /// The language of more than 60% of at least two counted moments, for the summary.
    public var majority: String? {
        let total = tally.values.reduce(0, +)
        guard total >= 2, let (language, count) = tally.max(by: { $0.value < $1.value }), Double(count) > 0.6 * Double(total) else { return nil }
        return language
    }
}

public enum MeetingRecovery {
    /// Whether a meeting interrupted by a crash or quit is a short recording to discard, as a normal stop would.
    /// Only first passes count: a meeting with a summary was finished before (an interrupted retranscribe) and is kept.
    /// Call once its end time is known.
    public static func discardsIfShort(_ meeting: Meeting, minimum: TimeInterval) -> Bool {
        guard meeting.summary == nil, meeting.status == .recording || meeting.status == .transcribing else { return false }
        return meeting.duration < minimum
    }
}

/// When a recording that nobody stopped should end on its own.
public struct RecordingLimits: Sendable, Equatable {
    /// Both tracks quiet this long ends a detected recording (the call ended but the tab or app stayed open).
    public var silence: TimeInterval
    /// No recording runs longer than this.
    public var maximum: TimeInterval
    /// Meter level (0...1) that counts as sound; quieter than a silent chunk's 0.002 RMS times the meter's 8x gain is below it.
    public static let audibleLevel: Float = 0.02

    public init(silence: TimeInterval = 15 * 60, maximum: TimeInterval = 4 * 3600) {
        self.silence = silence
        self.maximum = maximum
    }

    /// The reason to stop now, or nil to keep recording.
    public func stopReason(startedAt: Date, lastAudible: Date, detected: Bool, now: Date) -> String? {
        if now.timeIntervalSince(startedAt) >= maximum {
            return "Stopped after \(Int(maximum / 3600)) hours, the longest Chrupio records."
        }
        if detected, now.timeIntervalSince(lastAudible) >= silence {
            return "Stopped after \(Int(silence / 60)) minutes of silence."
        }
        return nil
    }
}

/// Post-call work (transcription, echo removal, diarization, summaries, Parakeet redos) waits while a call is
/// recorded: whisper and the diarizer running next to a live call spun the fans and risked audio glitches.
/// Back-to-back calls are common, so the previous call's work resumes when the current one stops.
public struct PostCallHold: Sendable, Equatable {
    /// Summaries asked for during a call, in the order asked.
    public private(set) var summaries: [UUID] = []

    public init() {}

    /// Whether a queued chunk may be transcribed now.
    public static func mayTranscribe(recording: Bool) -> Bool { !recording }

    /// Keeps a summary for later while a call is recorded; returns whether it was held.
    public mutating func holdSummary(_ id: UUID, recording: Bool) -> Bool {
        guard recording else { return false }
        if !summaries.contains(id) { summaries.append(id) }
        return true
    }

    public func isHolding(_ id: UUID) -> Bool { summaries.contains(id) }

    /// Drops a deleted meeting.
    public mutating func forget(_ id: UUID) { summaries.removeAll { $0 == id } }

    /// The held summaries, once the call ended; forgets them.
    public mutating func release() -> [UUID] {
        defer { summaries = [] }
        return summaries
    }
}
