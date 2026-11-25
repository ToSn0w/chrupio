import Foundation

/// The app's save path, off the main thread: each save is a snapshot written on one serial queue, under the write
/// lock with a short timeout, merged with edits another process made since the app last saw the file.
///
/// Order: saves run in the order they were asked for, and a snapshot is skipped when a newer one of the same
/// meeting is already queued, so an older snapshot never lands after a newer one.
public final class MeetingSaver: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Written; `merged` is the meeting as written when another process's edits were merged into it.
        case saved(merged: Meeting?)
        /// The lock was busy; the caller retries later.
        case deferred
        /// Not written because a newer snapshot of the meeting is queued (or the meeting was deleted).
        case superseded
        case failed(String)
    }

    public let store: MeetingStore
    public var lockTimeout: TimeInterval = 0.5

    private let queue = DispatchQueue(label: "chrupio.meeting-saves", qos: .userInitiated)
    private let lock = NSLock()
    private var _external = ExternalChanges()
    /// The newest generation asked for, per meeting.
    private var latest: [UUID: Int] = [:]
    private var generation = 0
    /// Saves asked for and not done yet, per meeting.
    private var inFlight: [UUID: Int] = [:]
    /// A merge with another process's edits, applied to every snapshot of the meeting taken before the UI saw it.
    private var merges: [UUID: (disk: Meeting, through: Int)] = [:]

    public init(store: MeetingStore) { self.store = store }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// meeting.json dates as this app last wrote or read them.
    public var external: ExternalChanges {
        get { locked { _external } }
        set { locked { _external = newValue } }
    }

    /// Changes the known dates in one step, so a save finishing meanwhile isn't lost.
    public func updateExternal<T>(_ change: (inout ExternalChanges) -> T) -> T { locked { change(&_external) } }

    /// Whether a save of the meeting is queued or being written; its file may be about to change.
    public func isSaving(_ id: UUID) -> Bool { locked { inFlight[id] != nil } }

    /// Queues a save of this snapshot; `completion` runs on the save queue.
    public func save(_ meeting: Meeting, completion: @escaping @Sendable (Outcome) -> Void) {
        let generation = submit(meeting.id)
        queue.async { completion(self.write(meeting, generation: generation)) }
    }

    /// Saves now, after the saves already queued. Blocks the caller; for edits that must report the result.
    public func saveNow(_ meeting: Meeting) -> Outcome {
        let generation = submit(meeting.id)
        return queue.sync { write(meeting, generation: generation) }
    }

    /// Deletes the meeting's folder after the saves already queued; any of its snapshots still queued are dropped.
    public func delete(_ id: UUID) throws {
        _ = locked { () -> Int in
            generation += 1
            latest[id] = generation
            return generation
        }
        try queue.sync {
            try store.delete(id)
            locked {
                _external.loaded(id, modified: nil)
                merges[id] = nil
            }
        }
    }

    /// Waits for every queued save; for quitting and tests.
    public func flush() { queue.sync {} }

    private func submit(_ id: UUID) -> Int {
        locked {
            generation += 1
            latest[id] = generation
            inFlight[id, default: 0] += 1
            return generation
        }
    }

    private func write(_ snapshot: Meeting, generation: Int) -> Outcome {
        let id = snapshot.id
        defer {
            locked {
                inFlight[id, default: 1] -= 1
                if inFlight[id] == 0 { inFlight[id] = nil }
            }
        }
        let (current, merge, external) = locked { (latest[id] == generation, merges[id], _external) }
        guard current else { return .superseded }
        var meeting = snapshot
        // Taken before the UI had the merged meeting: carries the other process's edits too.
        if let merge, generation <= merge.through { meeting = meeting.merging(disk: merge.disk) }
        var merged: Meeting?
        do {
            try store.withWriteLock(timeout: lockTimeout) {
                if external.isStale(id, onDisk: store.modificationDate(id)), let disk = try? store.load(id) {
                    let combined = meeting.merging(disk: disk)
                    if combined != meeting { merged = combined }
                    meeting = combined
                }
                try store.writeUnlocked(meeting)
                let modified = store.modificationDate(id)
                locked {
                    _external.loaded(id, modified: modified)
                    if let merged { merges[id] = (merged, latest[id] ?? generation) }
                    else if let merge, generation > merge.through { merges[id] = nil }
                }
            }
        } catch is MeetingStore.LockTimeout {
            return .deferred
        } catch {
            return .failed(error.localizedDescription)
        }
        if merged == nil, let merge, generation <= merge.through { merged = meeting }
        return .saved(merged: merged)
    }
}
