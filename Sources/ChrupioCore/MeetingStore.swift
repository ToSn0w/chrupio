import Foundation

/// Persists meetings as `<root>/<id>/meeting.json`, with audio chunks under `<root>/<id>/audio/`.
public struct MeetingStore: Sendable {
    public let root: URL

    public static var defaultRoot: URL {
        // Overridable so demos and snapshots never touch real meetings.
        if let custom = ProcessInfo.processInfo.environment["CHRUPIO_MEETINGS_DIR"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return AppPaths.support.appendingPathComponent("meetings", isDirectory: true)
    }

    public init(root: URL = MeetingStore.defaultRoot) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func audioDirectory(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("audio", isDirectory: true)
    }

    public func save(_ meeting: Meeting) throws {
        try withWriteLock { try write(meeting) }
    }

    /// Merges diagnostics into `<meeting>/probe.json` (what live speaker detection saw), newest per key.
    public func writeProbe(_ entries: [String: AnyJSON], for id: UUID) throws {
        let url = directory(for: id).appendingPathComponent("probe.json")
        // An unreadable or corrupt probe is replaced: it only holds diagnostics.
        var probe = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: AnyJSON].self, from: $0) } ?? [:]
        probe.merge(entries) { _, new in new }
        probe["updatedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(probe)
        try FileManager.default.createDirectory(at: directory(for: id), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// For edits that already hold the write lock.
    public func writeUnlocked(_ meeting: Meeting) throws { try write(meeting) }

    private func write(_ meeting: Meeting) throws {
        let dir = directory(for: meeting.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(meeting)
        try data.write(to: dir.appendingPathComponent("meeting.json"), options: .atomic)
        // Callers hold the write lock, so this update can't interleave with another writer's.
        var index = readIndex() ?? rebuiltIndex()
        index.entries[meeting.id] = MeetingIndex.Entry(meeting, modified: modificationDate(meeting.id) ?? Date())
        writeIndex(index)
    }

    // MARK: index.json

    /// `<root>/index.json`: one small entry per meeting, so the Claude Code hooks never decode transcripts.
    public var indexURL: URL { root.appendingPathComponent("index.json") }

    func readIndex() -> MeetingIndex? {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? Self.decoder.decode(MeetingIndex.self, from: data),
              index.version == MeetingIndex.currentVersion else { return nil }
        return index
    }

    /// index.json is a cache rebuilt from meeting.json files, so a failed write is logged, not thrown.
    func writeIndex(_ index: MeetingIndex) {
        do {
            try Self.encoder.encode(index).write(to: indexURL, options: .atomic)
        } catch {
            CoreLog.store.error("index.json write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rebuiltIndex() -> MeetingIndex {
        var index = MeetingIndex()
        for (id, modified) in modificationDates() {
            if let meeting = try? load(id) { index.entries[id] = MeetingIndex.Entry(meeting, modified: modified) }
        }
        return index
    }

    /// Every meeting's index entry, newest first. Entries whose meeting.json changed, appeared or vanished since the
    /// index was written (another process, an older app version) are refreshed from disk and the index is rewritten.
    public func index() -> [MeetingIndex.Entry] {
        let dates = modificationDates()
        let stored = readIndex()
        var index = stored ?? MeetingIndex()
        var changed = stored == nil
        for id in index.entries.keys where dates[id] == nil {
            index.entries[id] = nil
            changed = true
        }
        for (id, modified) in dates where !(index.entries[id]?.isCurrent(modified) ?? false) {
            index.entries[id] = (try? load(id)).map { MeetingIndex.Entry($0, modified: modified) }
            changed = true
        }
        // Atomic replace without the lock: a stale write here is noticed and fixed by the next read.
        if changed { writeIndex(index) }
        return index.entries.values.sorted { $0.startedAt > $1.startedAt }
    }

    public struct LockTimeout: LocalizedError {
        public var errorDescription: String? { "another Chrupio process is holding the meetings folder" }
    }

    /// How long a writer waits for another process before giving up with `LockTimeout`.
    public static let defaultLockTimeout: TimeInterval = 30

    /// Serializes writers across processes (the app and `chrupio-mcp`). Not reentrant.
    /// Throws `LockTimeout` after `timeout` (nil: `defaultLockTimeout`) so a stuck holder can't hang the caller.
    /// The app's main thread passes a short one.
    public func withWriteLock<T>(timeout: TimeInterval? = nil, _ body: () throws -> T) throws -> T {
        let fd = open(root.appendingPathComponent(".write.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return try body() }
        defer { close(fd) }
        try FileLock.lock(fd, timeout: timeout ?? Self.defaultLockTimeout)
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// Reads, changes and writes one meeting under the write lock; returns the saved meeting and a description.
    public func edit(_ id: UUID, _ edit: MeetingEdit, now: Date = Date()) throws -> (meeting: Meeting, message: String) {
        try withWriteLock {
            var meeting = try load(id)
            let message = try edit.apply(to: &meeting, now: now)
            try write(meeting)
            return (meeting, message)
        }
    }

    /// The file's modification date, used to notice changes made by another process.
    public func modificationDate(_ id: UUID) -> Date? {
        let file = directory(for: id).appendingPathComponent("meeting.json")
        return (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Every stored meeting id with its file's modification date.
    public func modificationDates() -> [UUID: Date] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var dates: [UUID: Date] = [:]
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent), let date = modificationDate(id) else { continue }
            dates[id] = date
        }
        return dates
    }

    public func load(_ id: UUID) throws -> Meeting {
        let data = try Data(contentsOf: directory(for: id).appendingPathComponent("meeting.json"))
        return try Self.decoder.decode(Meeting.self, from: data)
    }

    /// All meetings, newest first. Unreadable entries are skipped.
    public func loadAll() -> [Meeting] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { try? load($0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Meetings whose file changed since `date`, newest first. Cheap way to find recent meetings in a large library.
    public func loadModified(since date: Date) -> [Meeting] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .filter { id in
                let file = directory(for: id).appendingPathComponent("meeting.json")
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (modified ?? .distantPast) >= date
            }
            .compactMap { try? load($0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(_ id: UUID) throws {
        try withWriteLock {
            try FileManager.default.removeItem(at: directory(for: id))
            if var index = readIndex() {
                index.entries[id] = nil
                writeIndex(index)
            }
        }
    }

    public func deleteAudio(_ id: UUID) {
        // Best effort: audio may already be gone.
        try? FileManager.default.removeItem(at: audioDirectory(for: id))
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Compact: pretty printing made every file a third larger for every reader to decode. Old files still decode.
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// `flock` with a deadline, polled so a holder in another process can't block the caller forever.
public enum FileLock {
    public static func lock(_ fd: Int32, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else {
                CoreLog.lock.error("Gave up on a file lock after \(timeout, privacy: .public) s")
                throw MeetingStore.LockTimeout()
            }
            usleep(10_000)
        }
    }
}

/// What the hooks need from a meeting, without its transcript, word timings or voice vectors.
public struct MeetingIndex: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version = MeetingIndex.currentVersion
    public var entries: [UUID: Entry] = [:]

    public struct OpenItem: Codable, Sendable, Equatable {
        public var number: Int
        public var text: String
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var id: UUID
        /// meeting.json's modification date in seconds since 1970 (ISO 8601 would drop the fraction staleness checks need).
        public var modified: Double
        public var startedAt: Date
        public var endedAt: Date?
        public var title: String
        public var platform: Platform
        public var attendees: [String]
        public var status: MeetingStatus
        public var selfName: String?
        public var openActionItems: Int { openItems.count }
        /// Unticked checklist items, parsed once at save time (the regex parse is the slow part of a digest).
        public var openItems: [OpenItem]
        /// The summary Markdown; nil without a summary.
        public var summary: String?
        public var notes: [String]?
        /// Lowercased title, attendees, summary and notes: what a project match searches.
        public var terms: String

        public init(_ meeting: Meeting, modified: Date) {
            id = meeting.id
            self.modified = modified.timeIntervalSince1970
            startedAt = meeting.startedAt
            endedAt = meeting.endedAt
            title = meeting.title
            platform = meeting.platform
            attendees = meeting.attendees
            status = meeting.status
            selfName = meeting.selfName
            summary = meeting.summary?.markdown
            openItems = ActionItem.parse(summary ?? "").filter { !$0.done }.map { OpenItem(number: $0.number, text: $0.text) }
            notes = meeting.notes?.map(\.text)
            terms = MeetingIndex.terms(meeting)
        }

        public var modifiedDate: Date { Date(timeIntervalSince1970: modified) }

        func isCurrent(_ date: Date) -> Bool { abs(date.timeIntervalSince1970 - modified) < 0.000_5 }

        /// The meeting without its transcript: enough for the digest and prompt lines.
        public var meeting: Meeting {
            Meeting(id: id, title: title, platform: platform, startedAt: startedAt, endedAt: endedAt, attendees: attendees,
                    selfName: selfName, summary: summary.map { MeetingSummary(markdown: $0, model: "", createdAt: startedAt) },
                    status: status, notes: notes.map { $0.map { MeetingNote(createdAt: startedAt, author: "", text: $0) } })
        }
    }

    /// The text a project match looks in. Not the transcript: lowercasing it on every hook run was the slow part.
    public static func terms(_ meeting: Meeting) -> String {
        ([meeting.title] + meeting.attendees + [meeting.summary?.markdown ?? ""] + (meeting.notes ?? []).map(\.text))
            .joined(separator: "\n").lowercased()
    }
}

public enum AppPaths {
    public static let folderName = "Chrupio"

    /// Computes and creates the folder only. Moving an OpenKrisp folder is `LegacyMigration.migrateIfNeeded()`, which
    /// the app and `chrupio-mcp` call at start; reading this never moves anything.
    /// `CHRUPIO_SUPPORT_DIR`, honoured only in a snapshot run (`CHRUPIO_SNAPSHOT_DIR` set), so snapshots never read or
    /// write the real support folder (token, models, debug files) and a stray variable can't move a normal run's data.
    public static var customSupport: URL? { customSupport(environment: ProcessInfo.processInfo.environment) }

    static func customSupport(environment: [String: String]) -> URL? {
        guard environment["CHRUPIO_SNAPSHOT_DIR"] != nil, let custom = environment["CHRUPIO_SUPPORT_DIR"], !custom.isEmpty else { return nil }
        return URL(fileURLWithPath: custom, isDirectory: true)
    }

    /// `chrupio-mcp` is never part of a snapshot run. With `CHRUPIO_SNAPSHOT_DIR` set it would take its support folder
    /// from `CHRUPIO_SUPPORT_DIR` and skip the app-running guard on commands that rewrite meetings, so it refuses to start.
    public static func helperRefusal(environment: [String: String]) -> String? {
        guard environment["CHRUPIO_SNAPSHOT_DIR"] != nil else { return nil }
        return "chrupio-mcp does not run with CHRUPIO_SNAPSHOT_DIR set (that variable is for the app's debug snapshots). "
            + "Unset it and run the command again. Nothing was changed."
    }

    public static var support: URL {
        let url: URL
        if let custom = customSupport {
            url = custom
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            url = base.appendingPathComponent(folderName, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var models: URL {
        let url = support.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
