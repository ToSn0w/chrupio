import Foundation

/// Where a meeting is in the app's pipeline, apart from its saved `MeetingStatus`. A meeting with no phase is idle:
/// finished, or never touched this launch. Chunk counts stay in `ChunkQueue`; the phase says what the app does next.
public enum MeetingPhase: Sendable, Equatable {
    case recording
    /// The recorder is flushing its last chunks.
    case stopping
    /// Its chunks are queued or transcribing. Only a meeting just stopped, or a first recording recovered after a
    /// crash, may be discarded as too short; retranscribing a finished meeting never deletes it.
    case transcribing(discardIfShort: Bool)
    /// Remote voices are being told apart after the call; the transcript isn't final yet.
    case diarizing
    /// - Parameters:
    ///   - rerun: speakers were named meanwhile; the summary is written again when this one lands.
    ///   - previousError: the error the last failed summary left, cleared on success only if it is still shown.
    case summarizing(rerun: Bool, previousError: String?)
    /// The last summary failed with `reason`; kept so the next success clears only that error.
    case summaryFailed(reason: String)

    public enum Event: Sendable, Equatable {
        case recordingStarted
        case stopRequested
        /// The recorder handed over its last chunks.
        case lastChunksQueued
        /// A crash-recovered first recording that may be discarded as too short.
        case recoveredShortCandidate
        /// Saved audio was queued again (retranscribe).
        case transcriptionQueued
        /// A recovery's retranscribe queued nothing.
        case transcriptionSkipped
        /// Every chunk is in; the meeting leaves the queue.
        case transcribed
        case diarizationStarted
        case diarizationFinished
        case summaryStarted
        /// Speakers were named while the summary was written.
        case rerunRequested
        case summarySucceeded
        case summaryFailed(reason: String)
        /// "Write summaries with Claude" was turned off mid-summary: back to how it was before it started.
        case summaryStopped
        case deleted
    }

    /// The phase after `event`; nil is idle. Events that don't apply to the current phase leave it as it is.
    public static func transition(from phase: MeetingPhase?, event: Event) -> MeetingPhase? {
        switch (phase, event) {
        case (_, .recordingStarted): return .recording
        case (.recording, .stopRequested), (nil, .stopRequested): return .stopping
        case (.stopping, .lastChunksQueued): return .transcribing(discardIfShort: true)
        case (_, .recoveredShortCandidate): return .transcribing(discardIfShort: true)
        // A recovery marked it discardable first; queuing its audio keeps that.
        case (.transcribing(let discard), .transcriptionQueued): return .transcribing(discardIfShort: discard)
        case (nil, .transcriptionQueued), (.summaryFailed, .transcriptionQueued): return .transcribing(discardIfShort: false)
        case (.transcribing, .transcriptionSkipped): return nil
        case (.transcribing, .transcribed), (.stopping, .transcribed): return nil
        case (_, .diarizationStarted): return .diarizing
        case (.diarizing, .diarizationFinished): return nil
        case (nil, .summaryStarted): return .summarizing(rerun: false, previousError: nil)
        case (.summaryFailed(let reason), .summaryStarted): return .summarizing(rerun: false, previousError: reason)
        case (.summarizing(_, let previous), .rerunRequested): return .summarizing(rerun: true, previousError: previous)
        case (.summarizing, .summarySucceeded): return nil
        case (.summarizing, .summaryFailed(let reason)): return .summaryFailed(reason: reason)
        case (.summarizing(_, let previous), .summaryStopped): return previous.map { .summaryFailed(reason: $0) }
        case (_, .deleted): return nil
        default: return phase
        }
    }

    public var isDiarizing: Bool { self == .diarizing }
    public var isSummarizing: Bool { if case .summarizing = self { true } else { false } }
}

/// Every meeting's phase, changed only through `MeetingPhase.transition`.
public struct MeetingPhases: Sendable, Equatable {
    public private(set) var phases: [UUID: MeetingPhase] = [:]

    public init() {}

    public subscript(_ id: UUID) -> MeetingPhase? { phases[id] }

    /// Applies `event` to the meeting and returns the phase it left.
    @discardableResult
    public mutating func send(_ event: MeetingPhase.Event, to id: UUID) -> MeetingPhase? {
        let old = phases[id]
        phases[id] = MeetingPhase.transition(from: old, event: event)
        return old
    }

    public func contains(_ id: UUID, where test: (MeetingPhase) -> Bool) -> Bool { phases[id].map(test) ?? false }

    public var diarizing: Set<UUID> { Set(phases.filter { $0.value.isDiarizing }.keys) }
    public var summarizing: Set<UUID> { Set(phases.filter { $0.value.isSummarizing }.keys) }
}
