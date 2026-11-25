import Foundation

/// Speaker names given while a meeting is diarizing. Its lines aren't final yet (`MeetingEdit` refuses to name them),
/// so the names wait and are given on the diarized lines; other edits apply to the meeting at once.
public struct DiarizationEdits: Sendable {
    private var edits: [UUID: [MeetingEdit]] = [:]

    public init() {}

    public mutating func record(_ edit: MeetingEdit, for meetingID: UUID) {
        guard case .assignSpeaker = edit else { return }
        edits[meetingID, default: []].append(edit)
    }

    /// Puts the diarized lines on `meeting` (`nil`: the diarizer failed, the lines stay) and gives the names
    /// that waited. Forgets the meeting's edits.
    public mutating func finish(_ meetingID: UUID, meeting: inout Meeting, diarized: [TranscriptSegment]?) {
        if let diarized { meeting.segments = diarized }
        let pending = edits.removeValue(forKey: meetingID) ?? []
        guard !pending.isEmpty else { return }
        // The lines are final now, though the status changes only when the meeting completes.
        let status = meeting.status
        meeting.status = .done
        // A label the diarizer no longer uses names nothing; that edit is dropped.
        for edit in pending { _ = try? edit.apply(to: &meeting) }
        meeting.status = status
    }

    /// Drops a deleted meeting.
    public mutating func forget(_ meetingID: UUID) { edits[meetingID] = nil }
}

/// meeting.json dates as the app last wrote or read them; a different date means another process changed it.
/// A date is acknowledged only once that file is loaded, so a change skipped while the meeting was busy is retried.
public struct ExternalChanges: Sendable {
    public var known: [UUID: Date]

    public init(known: [UUID: Date] = [:]) { self.known = known }

    /// Meetings whose file is gone; forgotten here.
    public mutating func removed(onDisk: [UUID: Date]) -> [UUID] {
        let gone = known.keys.filter { onDisk[$0] == nil }.sorted { $0.uuidString < $1.uuidString }
        for id in gone { known[id] = nil }
        return gone
    }

    /// Meetings whose file changed since it was last loaded or written.
    public func changed(onDisk: [UUID: Date]) -> [UUID] {
        onDisk.filter { known[$0.key] != $0.value }.keys.sorted { $0.uuidString < $1.uuidString }
    }

    public mutating func loaded(_ meetingID: UUID, modified: Date?) { known[meetingID] = modified }

    /// Whether the file on disk changed since the app last loaded or wrote it; a file the app never knew counts too.
    public func isStale(_ meetingID: UUID, onDisk: Date?) -> Bool {
        guard let onDisk else { return false }
        return known[meetingID] != onDisk
    }
}

extension Meeting {
    /// This meeting with the user's edits from `disk`, a newer meeting.json another process wrote: its title, notes,
    /// names given to unnamed voices and its summary (with ticked action items) unless this one's summary is newer.
    /// Lines, status and everything else being produced stay as they are here.
    public func merging(disk: Meeting) -> Meeting {
        var merged = self
        merged.title = disk.title
        var noteIDs = Set((notes ?? []).map(\.id))
        let added = (disk.notes ?? []).filter { noteIDs.insert($0.id).inserted }
        if !added.isEmpty { merged.notes = ((notes ?? []) + added).sorted { $0.createdAt < $1.createdAt } }
        if let diskSummary = disk.summary, diskSummary.createdAt >= (summary?.createdAt ?? .distantPast) { merged.summary = diskSummary }
        let diskLabels = Dictionary(disk.segments.map { ($0.id, $0.speaker) }, uniquingKeysWith: { first, _ in first })
        merged.segments = segments.map { segment in
            var segment = segment
            let unnamed: Bool = if case .remote(let name) = segment.speaker { name.map(Meeting.isUnnamedSpeaker) ?? true } else { false }
            if unnamed, case .remote(let name?)? = diskLabels[segment.id], !Meeting.isUnnamedSpeaker(name) {
                segment.speaker = .remote(name)
            }
            return segment
        }
        merged.mergeAttendees(disk.attendees)
        return merged
    }
}

/// Jobs that run one at a time, in the order queued; a job already waiting isn't queued twice.
public struct SerialJobQueue<Job: Hashable & Sendable>: Sendable {
    public private(set) var pending: [Job] = []
    public private(set) var isRunning = false

    public init() {}

    public mutating func enqueue(_ job: Job) {
        if !pending.contains(job) { pending.append(job) }
    }

    /// The job to start now, or nil while one runs or none waits.
    public mutating func next() -> Job? {
        guard !isRunning, !pending.isEmpty else { return nil }
        isRunning = true
        return pending.removeFirst()
    }

    public mutating func finished() { isRunning = false }

    public mutating func remove(_ job: Job) { pending.removeAll { $0 == job } }
}

extension SpeakerPrints {
    /// One owner for speaker-prints.json in this process: every read-modify-write runs under it,
    /// so two meetings learning at once keep each other's voices.
    private static let fileLock = NSLock()

    /// Loads the prints at `url`, changes them and saves them, with no other update in between, in this process
    /// or in `chrupio-mcp` (a `flock` on `<file>.lock`).
    /// Throws `MeetingStore.LockTimeout` when another process holds the file longer than `timeout`; nothing changes then.
    public static func update(at url: URL, timeout: TimeInterval = 10, _ change: (inout SpeakerPrints) -> Void) throws {
        fileLock.lock()
        defer { fileLock.unlock() }
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        defer { if fd >= 0 { close(fd) } }
        if fd >= 0 { try FileLock.lock(fd, timeout: timeout) }
        defer { if fd >= 0 { flock(fd, LOCK_UN) } }
        var prints = load(from: url)
        change(&prints)
        try prints.save(to: url)
    }
}
