import Foundation

/// What Claude Code passes a hook on stdin (only the fields Chrupio uses).
public struct HookInput: Decodable, Sendable, Equatable {
    public var sessionID: String?
    public var cwd: String?
    public var source: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd, source
    }

    public init(sessionID: String? = nil, cwd: String? = nil, source: String? = nil) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.source = source
    }

    /// Parses hook stdin; a terminal or garbage gives an empty input rather than an error.
    public static func read(from handle: FileHandle = .standardInput) -> HookInput {
        guard isatty(handle.fileDescriptor) == 0 else { return HookInput() }
        let data = handle.readDataToEndOfFile()
        return (try? JSONDecoder().decode(HookInput.self, from: data)) ?? HookInput()
    }
}

/// What one Claude Code session has already been told, so the prompt hook only reports what is new.
public struct HookSessionState: Codable, Sendable, Equatable {
    /// When the session started (or last resumed).
    public var since: Date
    /// Finished meetings already mentioned.
    public var announced: Set<UUID>
    /// Live meetings already mentioned as recording.
    public var announcedLive: Set<UUID>
    /// When the prompt hook last looked; only meetings changed after it are considered. Nil in older state files.
    public var lastChecked: Date?

    public init(since: Date, announced: Set<UUID> = [], announcedLive: Set<UUID> = [], lastChecked: Date? = nil) {
        self.since = since
        self.announced = announced
        self.announcedLive = announcedLive
        self.lastChecked = lastChecked
    }

    /// Meeting files changed at or after this are worth a look: since the last check (with a little overlap, as
    /// the state stores whole seconds), or before that, 6 h before the session started, since a meeting that ended
    /// shortly before may finish processing after it.
    public var changedSince: Date {
        lastChecked.map { $0.addingTimeInterval(-2) } ?? since.addingTimeInterval(-6 * 3600)
    }

    public static var directory: URL {
        if let custom = ProcessInfo.processInfo.environment["CHRUPIO_SESSIONS_DIR"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return AppPaths.support.appendingPathComponent("claude-sessions", isDirectory: true)
    }

    static func file(for sessionID: String, in directory: URL) -> URL? {
        let safe = sessionID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safe.isEmpty, safe.count <= 128 else { return nil }
        return directory.appendingPathComponent(safe + ".json")
    }

    public static func load(_ sessionID: String, in directory: URL = directory) -> HookSessionState? {
        guard let file = file(for: sessionID, in: directory), let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HookSessionState.self, from: data)
    }

    public func save(_ sessionID: String, in directory: URL = directory, now: Date = Date()) {
        guard let file = Self.file(for: sessionID, in: directory) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(self).write(to: file, options: .atomic)
        Self.removeStaleHourly(in: directory, now: now)
    }

    static let cleanupMarker = ".last-cleanup"

    /// Runs `removeStale` at most once an hour, tracked by a marker file's date, so a prompt doesn't list the folder.
    static func removeStaleHourly(in directory: URL, now: Date) {
        let marker = directory.appendingPathComponent(cleanupMarker)
        if let last = (try? marker.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           now.timeIntervalSince(last) < 3600, last <= now { return }
        FileManager.default.createFile(atPath: marker.path, contents: nil, attributes: [.modificationDate: now])
        removeStale(in: directory, now: now)
    }

    /// Sessions untouched for two weeks are over.
    static func removeStale(in directory: URL, now: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > 14 * 86_400 { try? FileManager.default.removeItem(at: file) }
        }
    }
}

/// The project a Claude Code session runs in, as names a meeting might mention.
public struct ProjectContext: Sendable, Equatable {
    /// Display name, e.g. the git repository's name.
    public var name: String
    /// Lowercased forms to look for in meetings ("open-acme" also as "open acme").
    public var terms: [String]

    /// Folder names too generic to identify a project.
    static let generic: Set<String> = [
        "users", "desktop", "documents", "downloads", "projects", "project", "src", "source", "code", "repos", "repo",
        "dev", "work", "workspace", "home", "github", "git", "tmp", "temp", "test", "tests", "main", "master", "app",
        "apps", "web", "api", "backend", "frontend", "server", "client", "notes", "docs",
    ]

    /// Names from the folder, its git repository root and the origin remote; nil when none is distinctive.
    public static func from(cwd: String?, fileManager: FileManager = .default) -> ProjectContext? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let folder = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        guard folder.path != fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path else { return nil }
        var names: [String] = []
        var root: URL?
        var dir = folder
        while dir.path != "/" {
            if fileManager.fileExists(atPath: dir.appendingPathComponent(".git").path) { root = dir; break }
            dir.deleteLastPathComponent()
        }
        if let root {
            if let remote = originRepositoryName(root) { names.append(remote) }
            names.append(root.lastPathComponent)
        }
        names.append(folder.lastPathComponent)
        let user = NSUserName().lowercased()
        var terms: [String] = []
        var display: String?
        for name in names {
            let lower = name.lowercased()
            guard lower.count >= 4, !generic.contains(lower), lower != user else { continue }
            display = display ?? name
            for term in [lower, lower.replacingOccurrences(of: #"[-_.]+"#, with: " ", options: .regularExpression)] where !terms.contains(term) {
                terms.append(term)
            }
        }
        guard let display else { return nil }
        return ProjectContext(name: display, terms: terms)
    }

    /// "chrupio" from `url = git@github.com:me/chrupio.git` in .git/config.
    static func originRepositoryName(_ root: URL) -> String? {
        guard let config = try? String(contentsOf: root.appendingPathComponent(".git/config"), encoding: .utf8) else { return nil }
        var inOrigin = false
        for raw in config.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inOrigin = line == #"[remote "origin"]"#; continue }
            guard inOrigin, line.hasPrefix("url") else { continue }
            let url = line.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            var name = url.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
            if name.hasSuffix(".git") { name.removeLast(4) }
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// Whether the meeting's title, attendees, summary or notes mention the project (not the transcript:
    /// a summary names what the call was about, and scanning transcripts made every hook run slow).
    public func matches(_ meeting: Meeting) -> Bool { matches(terms: MeetingIndex.terms(meeting)) }

    public func matches(_ entry: MeetingIndex.Entry) -> Bool { matches(terms: entry.terms) }

    /// `text` is already lowercased, as in `MeetingIndex.Entry.terms`.
    public func matches(terms text: String) -> Bool { terms.contains { Self.contains(text, $0) } }

    /// Whole-word match, so "acme" doesn't match "acmeville".
    static func contains(_ text: String, _ term: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: term, range: searchRange) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !(before?.isLetter ?? false || before?.isNumber ?? false), !(after?.isLetter ?? false || after?.isNumber ?? false) {
                return true
            }
            searchRange = range.upperBound..<text.endIndex
        }
        return false
    }
}

/// The UserPromptSubmit hook: one short line per meeting that finished (or started recording)
/// since the session last heard from Chrupio; nothing otherwise.
public enum PromptUpdates {
    /// From the index: only meetings whose file changed since the last check; the returned state records this check.
    public static func lines(_ entries: [MeetingIndex.Entry], state: HookSessionState, project: ProjectContext?, now: Date = Date())
        -> (lines: [String], state: HookSessionState) {
        let since = state.changedSince
        var update = lines(entries.filter { $0.modifiedDate >= since }.map(\.meeting), state: state, project: project, now: now)
        update.state.lastChecked = now
        return update
    }

    /// Lines to print and the state to store.
    public static func lines(_ meetings: [Meeting], state: HookSessionState, project: ProjectContext?, now: Date = Date())
        -> (lines: [String], state: HookSessionState) {
        var state = state
        var lines: [String] = []
        // A meeting that ended shortly before the session started may finish processing after it.
        let window = state.since.addingTimeInterval(-6 * 3600)
        let finished = meetings
            .filter { ($0.status == .done || $0.status == .failed) && ($0.endedAt ?? $0.startedAt) >= window && !state.announced.contains($0.id) }
            .sorted { $0.startedAt < $1.startedAt }
        for meeting in finished.suffix(3) {
            var line = "Chrupio: meeting finished: \(MCPServer.day(meeting.startedAt, time: true)) \(UntrustedText.quoted(meeting.title)) "
                + "(\(meeting.platform.displayName), \(TranscriptFormatter.durationText(meeting.duration))), id \(MeetingExporter.shortID(meeting.id))"
            let open = ActionItem.parse(meeting.summary?.markdown ?? "").filter { !$0.done }.count
            if meeting.summary == nil {
                line += ", no summary"
            } else if open > 0 {
                line += ", \(open) open action item(s)"
            }
            if let project, project.matches(meeting) { line += ", mentions \(project.name)" }
            lines.append(line + ".")
        }
        if finished.count > 3 { lines.append("Chrupio: \(finished.count - 3) more meeting(s) finished; see list_meetings.") }
        state.announced.formUnion(finished.map(\.id))

        for meeting in meetings where meeting.status == .recording && !state.announcedLive.contains(meeting.id) {
            lines.append("Chrupio: recording now: \(UntrustedText.quoted(meeting.title)) (\(meeting.platform.displayName), started "
                + "\(MCPServer.day(meeting.startedAt, time: true))), id \(MeetingExporter.shortID(meeting.id)); its transcript is written once the call ends.")
            state.announcedLive.insert(meeting.id)
        }
        // The notice goes first, so it is read before the meeting text it describes.
        if !lines.isEmpty { lines = [UntrustedText.notice] + lines + ["Use the chrupio MCP tools for details."] }
        return (lines, state)
    }
}
