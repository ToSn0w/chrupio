import Foundation
import Observation

/// Where the library's saves go: `MeetingSaver` in the app, a fake in tests.
public protocol MeetingSaving: AnyObject, Sendable {
    var store: MeetingStore { get }
    var external: ExternalChanges { get set }
    func updateExternal<T>(_ change: (inout ExternalChanges) -> T) -> T
    func isSaving(_ id: UUID) -> Bool
    func save(_ meeting: Meeting, completion: @escaping @Sendable (MeetingSaver.Outcome) -> Void)
    func saveNow(_ meeting: Meeting) -> MeetingSaver.Outcome
    func delete(_ id: UUID) throws
    func flush()
}

extension MeetingSaver: MeetingSaving {}

/// User notifications. `important` ones are posted even when the user turned notifications off.
@MainActor
public protocol MeetingNotifying: AnyObject {
    func post(title: String, body: String, important: Bool, identifier: String?)
    func remove(identifier: String)
}

public extension MeetingNotifying {
    func post(title: String, body: String, important: Bool = false) { post(title: title, body: body, important: important, identifier: nil) }
}

/// What the library tells the rest of the app about saved, loaded and deleted meetings.
@MainActor
public protocol MeetingLibraryHooks: AnyObject {
    /// Keep audio is on: mic chunks are never deleted after their text is saved.
    var keepAudio: Bool { get }
    /// Written to disk (export to Markdown, semantic index).
    func saved(_ meeting: Meeting)
    /// Loaded from another process's change (semantic index).
    func loadedExternally(_ meeting: Meeting)
    /// Deleted by the user or a discard.
    func removed(_ id: UUID)
    /// Recording, transcribing, diarizing or summarizing: an external change is not loaded over it.
    func isBusy(_ id: UUID) -> Bool
}

/// The meetings in memory, their pipeline phases, and every save: snapshots go off the main thread, a save that
/// finds the write lock busy is retried with backoff, mic audio whose text is in a snapshot is deleted once that
/// snapshot is on disk, and save and delete failures reach the user through `lastError`.
@MainActor
@Observable
public final class MeetingLibrary {
    public var meetings: [Meeting] = []
    /// Each meeting's place in the pipeline (stopping, transcribing, diarizing, summarizing, summary failed).
    public var phases = MeetingPhases()
    public var lastError: String?

    @ObservationIgnored public let saver: MeetingSaving
    @ObservationIgnored public weak var hooks: MeetingLibraryHooks?
    @ObservationIgnored public weak var notifier: MeetingNotifying?
    @ObservationIgnored public private(set) var pendingSaves = DeferredSaves()
    /// Mic chunks whose text is in memory but not yet on disk; deleted after the meeting's next successful save.
    @ObservationIgnored public private(set) var unsavedRemovals: [UUID: [AudioChunk]] = [:]
    /// Set after a failed save so the user is told once, not on every chunk.
    @ObservationIgnored private var warnedSaveFailure = false
    @ObservationIgnored private var lastExternalScan = Date.distantPast

    public var store: MeetingStore { saver.store }

    public init(saver: MeetingSaving) {
        self.saver = saver
    }

    public func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }
    public func index(of id: UUID) -> Int? { meetings.firstIndex { $0.id == id } }

    /// Adds meetings not in memory yet, newest first.
    public func add(_ added: [Meeting]) {
        let present = Set(meetings.map(\.id))
        let new = added.filter { !present.contains($0.id) }
        guard !new.isEmpty else { return }
        meetings = (meetings + new).sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: Saving

    public func update(_ meetingID: UUID, _ change: (inout Meeting) -> Void) {
        guard let index = index(of: meetingID) else { return }
        change(&meetings[index])
        persist(meetings[index])
    }

    /// Mic audio whose text is now in memory; deleted after the meeting's next successful save.
    public func removeAfterSave(_ chunk: AudioChunk, of meetingID: UUID) {
        unsavedRemovals[meetingID, default: []].append(chunk)
    }

    /// Saves a snapshot of the meeting off the main thread; `done` runs on main with whether it was written.
    public func persist(_ meeting: Meeting, retry: Bool = false, then done: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        // A deferred save is retried with backoff from `retryDeferredSaves`, with the meeting as it is then; trying
        // the busy lock again on every change would cost a wait of up to 0.5 s each time.
        if !retry, pendingSaves.contains(meeting.id) {
            done?(false)
            return
        }
        let removals = unsavedRemovals.removeValue(forKey: meeting.id) ?? []
        saver.save(meeting) { [weak self] outcome in
            Task { @MainActor in
                let saved = self?.saveFinished(meeting, outcome, removals: removals) ?? false
                done?(saved)
            }
        }
    }

    /// Saves now and waits; for edits from the MCP server and the local API, which report whether it worked.
    public func persistNow(_ meeting: Meeting) -> Bool {
        let removals = unsavedRemovals.removeValue(forKey: meeting.id) ?? []
        return saveFinished(meeting, saver.saveNow(meeting), removals: removals)
    }

    /// Saves again the meetings whose save was deferred and is due.
    public func retryDeferredSaves(now: Date) {
        for id in pendingSaves.due(now: now) {
            if let meeting = meeting(id) { persist(meeting, retry: true) } else { pendingSaves.saved(id) }
        }
    }

    /// Waits for every queued save; for quitting.
    public func flush() async {
        let saver = saver
        await Task.detached(priority: .userInitiated) { saver.flush() }.value
    }

    private func saveFinished(_ meeting: Meeting, _ outcome: MeetingSaver.Outcome, removals: [AudioChunk]) -> Bool {
        let id = meeting.id
        switch outcome {
        case .superseded:
            // A newer snapshot is being written; it takes the audio removals along.
            if !removals.isEmpty, meetings.contains(where: { $0.id == id }) { unsavedRemovals[id, default: []] += removals }
            return false
        case .deferred:
            CoreLog.coordinator.error("save of \(id, privacy: .public) deferred: the write lock is busy")
            pendingSaves.deferred(id)
            if !removals.isEmpty { unsavedRemovals[id, default: []] += removals }
            return false
        case .failed(let message):
            CoreLog.coordinator.error("save failed: \(message, privacy: .public)")
            if !removals.isEmpty { unsavedRemovals[id, default: []] += removals }
            if !warnedSaveFailure {
                warnedSaveFailure = true
                lastError = "Couldn't save meeting notes: \(message)"
                notifier?.post(title: "Couldn't save meeting notes", body: "\(message) Audio is kept so nothing is lost. Free up disk space.", important: true)
            }
            return false
        case .saved(let merged):
            if warnedSaveFailure, lastError?.hasPrefix("Couldn't save meeting notes") == true { lastError = nil }
            warnedSaveFailure = false
            pendingSaves.saved(id)
            // Another process (chrupio-mcp) changed the file since the app last saw it: its edits are kept.
            if let merged, let index = index(of: id) {
                let combined = meetings[index].merging(disk: merged)
                if combined != meetings[index] { meetings[index] = combined }
            }
            if hooks?.keepAudio == false { removals.forEach(Self.removeChunkFiles) }
            hooks?.saved(merged ?? meeting)
            return true
        }
    }

    public nonisolated static func removeChunkFiles(_ chunk: AudioChunk) {
        try? FileManager.default.removeItem(at: chunk.url)
        try? FileManager.default.removeItem(at: chunk.url.deletingPathExtension().appendingPathExtension("json"))
    }

    // MARK: Deleting

    /// Removes the meeting from memory now and its folder off the main thread, after the saves already queued, so
    /// none of them writes the folder again (the save queue and the write lock can both wait on another process).
    /// If the folder can't be deleted the meeting is shown again and `lastError` says why.
    public func delete(_ meeting: Meeting) {
        phases.send(.deleted, to: meeting.id)
        unsavedRemovals[meeting.id] = nil
        let saver = saver
        let id = meeting.id
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try saver.delete(id)
                CoreLog.coordinator.info("deleted \(id, privacy: .public)")
            } catch {
                CoreLog.coordinator.error("delete of \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                await self?.deleteFailed(meeting, error.localizedDescription)
            }
        }
        pendingSaves.saved(meeting.id)
        meetings.removeAll { $0.id == meeting.id }
        hooks?.removed(meeting.id)
    }

    /// The folder is still on disk: show the meeting again rather than have it reappear at the next launch.
    private func deleteFailed(_ meeting: Meeting, _ message: String) {
        lastError = "Couldn't delete \"\(meeting.title)\": \(message)"
        guard !meetings.contains(where: { $0.id == meeting.id }) else { return }
        meetings.append(meeting)
        meetings.sort { $0.startedAt > $1.startedAt }
    }

    // MARK: External changes

    /// Scans for external changes when the last scan is a minute old; `FolderWatch` triggers the rest.
    public func reloadExternalChangesIfDue(now: Date) {
        guard now.timeIntervalSince(lastExternalScan) >= 60 else { return }
        reloadExternalChanges(now: now)
    }

    /// Picks up meeting files another process changed (chrupio-mcp writing while the app was starting,
    /// or a restore from backup). Meetings this app is working on are left alone; it is their only writer.
    public func reloadExternalChanges(now: Date = Date()) {
        lastExternalScan = now
        let onDisk = store.modificationDates()
        let isBusy: (UUID) -> Bool = { [hooks] in hooks?.isBusy($0) ?? false }
        // A meeting being saved right now looks changed on disk; the app wrote it, so it isn't loaded back.
        for id in saver.updateExternal({ $0.removed(onDisk: onDisk) }) where !isBusy(id) && !saver.isSaving(id) {
            meetings.removeAll { $0.id == id }
        }
        // A busy meeting's change stays unacknowledged, so it is loaded on a later scan.
        for id in saver.external.changed(onDisk: onDisk) {
            guard !isBusy(id), !saver.isSaving(id), let meeting = try? store.load(id) else { continue }
            saver.updateExternal { $0.loaded(id, modified: onDisk[id]) }
            hooks?.loadedExternally(meeting)
            if let index = index(of: id) {
                if meetings[index] != meeting { meetings[index] = meeting }
            } else {
                meetings.append(meeting)
                meetings.sort { $0.startedAt > $1.startedAt }
            }
        }
    }
}
