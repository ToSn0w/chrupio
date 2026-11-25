import Foundation

/// Tells a finished meeting's remote voices apart, one meeting at a time: after back-to-back calls they would
/// all start at once. Each run has a deadline, so a stalled model load can't keep every later meeting waiting;
/// a failed or late run reports no lines and the caller names voices the older way.
@MainActor
public final class DiarizationScheduler {
    /// Diarization's lines applied to the meeting as it was when the run started. Voice embeddings go in `voices`,
    /// which are kept even when naming throws afterwards (saving the prints failed).
    public typealias Naming = @Sendable (Diarization, Meeting, inout [String: [Float]]?) throws -> [TranscriptSegment]

    public private(set) var queue = SerialJobQueue<UUID>()
    private var inputs: [UUID: (system: [AudioChunk], failures: Int)] = [:]
    private let diarize: @Sendable ([AudioChunk]) async throws -> Diarization

    /// The meeting as it is now; nil drops its run.
    public var meeting: (UUID) -> Meeting? = { _ in nil }
    /// How the lines get names, built on the main actor when a run starts (it captures the project context).
    public var makeNaming: () -> Naming = { { _, meeting, _ in meeting.segments } }
    /// Seconds a run may take for this much audio.
    public var deadline: @Sendable (TimeInterval) -> TimeInterval = Deadline.diarization(audioSeconds:)
    /// A run ended; nil segments mean diarization failed or ran out of time. The next run starts after.
    public var onFinished: (UUID, [TranscriptSegment]?, [String: [Float]]?, Int) -> Void = { _, _, _, _ in }
    /// A queued meeting that was gone (or had no input) when its turn came.
    public var onDropped: (UUID) -> Void = { _ in }

    public init(diarize: @escaping @Sendable ([AudioChunk]) async throws -> Diarization) {
        self.diarize = diarize
    }

    /// Queues the meeting's call audio; `failures` is carried through to `onFinished`.
    public func enqueue(_ meetingID: UUID, system: [AudioChunk], failures: Int) {
        inputs[meetingID] = (system, failures)
        queue.enqueue(meetingID)
        process()
    }

    /// Starts the next queued run, from the meeting as it is now.
    public func process() {
        guard let meetingID = queue.next() else { return }
        guard let (system, failures) = inputs.removeValue(forKey: meetingID), let meeting = meeting(meetingID) else {
            queue.finished()
            onDropped(meetingID)
            return process()
        }
        let naming = makeNaming()
        let diarize = diarize
        let deadline = deadline(system.map { $0.startOffset + $0.duration }.max() ?? 0)
        Task.detached(priority: .utility) {
            var named: [TranscriptSegment]?
            var voices: [String: [Float]]?
            do {
                CoreLog.coordinator.info("diarizing \(meetingID, privacy: .public), deadline \(Int(deadline), privacy: .public) s")
                let diarization = try await Deadline.run(seconds: deadline) { try await diarize(system) }
                named = try naming(diarization, meeting, &voices)
                CoreLog.coordinator.info("diarized \(meetingID, privacy: .public): \(Set(diarization.turns.map(\.cluster)).count, privacy: .public) voices")
            } catch {
                CoreLog.coordinator.error("diarization failed, naming voices without it: \(error.localizedDescription, privacy: .public)")
            }
            await self.finished(meetingID, segments: named, voices: voices, failures: failures)
        }
    }

    private func finished(_ meetingID: UUID, segments: [TranscriptSegment]?, voices: [String: [Float]]?, failures: Int) {
        queue.finished()
        defer { process() }
        onFinished(meetingID, segments, voices, failures)
    }
}
