import Foundation

/// Turns orphan audio folders (a crash before the meeting was saved) into meetings, a recording with long gaps
/// split into one meeting per stretch: `MeetingStore` in the app, a fake in tests.
public protocol OrphanRecovering: Sendable {
    func recoverOrphans(lockTimeout: TimeInterval?) -> (recovered: [Meeting], blocked: Int)
}

extension MeetingStore: OrphanRecovering {}

/// What recovery asks the transcription pipeline to do.
@MainActor
public protocol OrphanRecoveryEnvironment: AnyObject {
    var minimumMeetingSeconds: TimeInterval { get }
    func hasAudio(_ id: UUID) -> Bool
    /// Queues the meeting's saved audio again.
    func retranscribe(_ id: UUID)
    /// The meeting's chunks are queued (`retranscribe` may refuse).
    func isQueued(_ id: UUID) -> Bool
    /// No audio left: finish the meeting from the transcript it has.
    func finishWithoutAudio(_ id: UUID)
    func summarizeInterrupted(_ id: UUID)
}

/// Finishes meetings a crash or quit left "recording", "transcribing" or "summarizing", and keeps trying orphan
/// recordings the launch couldn't save because another process held the write lock.
@MainActor
public final class OrphanRecoveryScheduler {
    /// How long one orphan recovery waits for the write lock; a holder never stalls launch.
    public nonisolated static let lockTimeout: TimeInterval = 1
    /// Seconds between retries of orphans the write lock blocked.
    public nonisolated static let retryInterval: TimeInterval = 10

    private let library: MeetingLibrary
    private let source: OrphanRecovering
    public weak var environment: OrphanRecoveryEnvironment?
    public private(set) var orphansBlocked = false
    private var retrying = false
    private var lastRetry = Date.distantPast

    public init(library: MeetingLibrary, source: OrphanRecovering) {
        self.library = library
        self.source = source
    }

    /// The library is loaded: `blocked` orphans wait for the write lock; every unfinished meeting is finished now.
    public func launchFinished(blockedOrphans blocked: Int) {
        orphansBlocked = blocked > 0
        for meeting in library.meetings where meeting.status != .done && meeting.status != .failed { recoverInterrupted(meeting) }
    }

    /// Orphan recordings the launch left because the write lock was held: tried again every 10 s until saved, then
    /// loaded and transcribed like any interrupted meeting. Returns the recovery task when one started.
    @discardableResult
    public func retryBlockedIfDue(now: Date) -> Task<Void, Never>? {
        guard orphansBlocked, !retrying, now.timeIntervalSince(lastRetry) >= Self.retryInterval else { return nil }
        lastRetry = now
        retrying = true
        let source = source
        return Task {
            let orphans = await Task.detached(priority: .utility) { source.recoverOrphans(lockTimeout: Self.lockTimeout) }.value
            retrying = false
            orphansBlocked = orphans.blocked > 0
            let present = Set(library.meetings.map(\.id))
            let added = orphans.recovered.filter { !present.contains($0.id) }
            guard !added.isEmpty else { return }
            for orphan in added { CoreLog.coordinator.info("recovered orphan recording \(orphan.id, privacy: .public)") }
            library.add(added)
            let onDisk = library.store.modificationDates()
            for orphan in added { library.saver.updateExternal { $0.loaded(orphan.id, modified: onDisk[orphan.id]) } }
            for orphan in added { recoverInterrupted(orphan) }
        }
    }

    /// Transcribes the meeting's leftover audio and finishes it; an interrupted summary is only written again.
    public func recoverInterrupted(_ meeting: Meeting) {
        guard let environment else { return }
        if meeting.status == .summarizing {
            // The transcript is complete; only the summary was interrupted.
            library.update(meeting.id) { $0.status = .done }
            environment.summarizeInterrupted(meeting.id)
            return
        }
        var ended = meeting
        let lastAudio = lastAudioDate(meeting.id)
        library.update(meeting.id) {
            // With Keep audio off the audio folder may be empty; the transcript still shows how long the call ran.
            let lastSpeech = ($0.segments.map(\.end) + $0.speakerEvents.map(\.lastSeen)).max().map { meeting.startedAt.addingTimeInterval($0) }
            $0.endedAt = $0.endedAt ?? [lastAudio, lastSpeech].compactMap { $0 }.max() ?? meeting.startedAt
            ended.endedAt = $0.endedAt
            $0.status = .transcribing
        }
        if MeetingRecovery.discardsIfShort(ended, minimum: environment.minimumMeetingSeconds) {
            library.phases.send(.recoveredShortCandidate, to: meeting.id)
        }
        if environment.hasAudio(meeting.id) {
            environment.retranscribe(meeting.id)
            // Not queued after all: a later, manual retranscribe must not discard it.
            if !environment.isQueued(meeting.id) { library.phases.send(.transcriptionSkipped, to: meeting.id) }
        } else {
            environment.finishWithoutAudio(meeting.id)
        }
    }

    private func lastAudioDate(_ meetingID: UUID) -> Date? {
        let folder = library.store.audioDirectory(for: meetingID)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }
}
