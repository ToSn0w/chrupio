import Foundation

/// Writes finished meetings as Markdown files with YAML frontmatter, one file per meeting.
public struct MeetingExporter: Sendable {
    public let folder: URL

    /// In the home folder rather than ~/Documents, which macOS guards with a privacy prompt
    /// for both this app and the terminal that runs Claude Code.
    public static var defaultFolder: URL {
        UserHome.url.appendingPathComponent("Chrupio Notes", isDirectory: true)
    }

    /// The default folder however it is spelled (trailing slash, `..`); only this folder is made 0700.
    public static func isDefaultFolder(_ folder: URL) -> Bool {
        folder.standardizedFileURL.path == defaultFolder.standardizedFileURL.path
    }

    public init(folder: URL = MeetingExporter.defaultFolder) {
        self.folder = folder
    }

    /// The exporter the app's settings describe, for processes other than the app (nil when export is off).
    public static func fromAppSettings(_ defaults: UserDefaults? = UserDefaults(suiteName: "com.chrupio.app")) -> MeetingExporter? {
        guard let defaults else { return MeetingExporter() }
        if defaults.object(forKey: "exportMarkdown") != nil, !defaults.bool(forKey: "exportMarkdown") { return nil }
        let path = defaults.string(forKey: "exportFolderPath") ?? defaultFolder.path
        return MeetingExporter(folder: URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Meetings still being captured or transcribed have no stable content yet.
    public static func isExportable(_ meeting: Meeting) -> Bool {
        meeting.status != .recording && meeting.status != .transcribing
    }

    public static func fileName(for meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let forbidden = CharacterSet(charactersIn: "/:\\\n\r\t").union(.controlCharacters)
        var title = meeting.title.components(separatedBy: forbidden).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if title.hasPrefix(".") { title = String(title.drop { $0 == "." }) }
        if title.isEmpty { title = "Meeting" }
        if title.count > 80 { title = String(title.prefix(80)).trimmingCharacters(in: .whitespaces) }
        // APFS allows 255 UTF-8 bytes per name; 80 characters of CJK or emoji can exceed what is left.
        while title.utf8.count > maxTitleBytes { title.removeLast() }
        title = title.trimmingCharacters(in: .whitespaces)
        if title.isEmpty { title = "Meeting" }
        return "\(formatter.string(from: meeting.startedAt)) \(title) [\(shortID(meeting.id))].md"
    }

    /// Leaves room for the date, short id and extension within the 255-byte name limit.
    static let maxTitleBytes = 180

    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    /// The end of every file name `fileName(for:)` builds for this meeting.
    static func fileSuffix(for id: UUID) -> String {
        " [\(shortID(id))].md"
    }

    /// Whether `name` is shaped like a note this app writes: `… [xxxxxxxx].md` with a lowercase hex short id.
    public static func isExportFileName(_ name: String) -> Bool {
        name.range(of: #" \[[0-9a-f]{8}\]\.md$"#, options: .regularExpression) != nil
    }

    public static func frontmatter(_ meeting: Meeting) -> String {
        // Local offset (e.g. +07:00) so the times match the file name and the "When" line.
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        var lines = ["---"]
        lines.append("id: \(meeting.id.uuidString)")
        lines.append("title: \(yamlString(meeting.title))")
        lines.append("platform: \(meeting.platform.rawValue)")
        lines.append("started: \(iso.string(from: meeting.startedAt))")
        if let end = meeting.endedAt { lines.append("ended: \(iso.string(from: end))") }
        lines.append("duration_minutes: \(Int((meeting.duration / 60).rounded()))")
        lines.append("status: \(meeting.status.rawValue)")
        lines.append("attendees: [\(meeting.attendees.map(yamlString).joined(separator: ", "))]")
        if let url = meeting.url { lines.append("url: \(yamlString(url))") }
        lines.append("source: chrupio")
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    public static func document(_ meeting: Meeting) -> String {
        frontmatter(meeting) + "\n\n" + TranscriptFormatter.markdown(meeting)
    }

    static func yamlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    /// Writes the meeting's file and removes older files for the same meeting (e.g. after a rename).
    @discardableResult
    public func export(_ meeting: Meeting) throws -> URL? {
        guard Self.isExportable(meeting) else { return nil }
        // A folder Chrupio creates is private; a folder the user picked keeps its mode. Notes are always 0600.
        if !FileManager.default.fileExists(atPath: folder.path) { try FilePermissions.ensurePrivateDirectory(folder) }
        let url = folder.appendingPathComponent(Self.fileName(for: meeting))
        try FilePermissions.writePrivately(Data(Self.document(meeting).utf8), to: url)
        for stale in files(for: meeting.id) where stale.lastPathComponent != url.lastPathComponent {
            try? FileManager.default.removeItem(at: stale)
        }
        return url
    }

    public func remove(_ id: UUID) {
        for file in files(for: id) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Exports every exportable meeting; returns how many were written and the first error, if any.
    @discardableResult
    public func exportAll(_ meetings: [Meeting]) -> (written: Int, error: Error?) {
        var written = 0
        var firstError: Error?
        for meeting in meetings {
            do {
                if try export(meeting) != nil { written += 1 }
            } catch {
                firstError = firstError ?? error
            }
        }
        return (written, firstError)
    }

    /// Removes this app's files from a folder the user moved away from, so two folders don't drift apart.
    public static func removeExports(in folder: URL, ids: [UUID]) {
        let exporter = MeetingExporter(folder: folder)
        ids.forEach(exporter.remove)
    }

    func files(for id: UUID) -> [URL] {
        let suffix = Self.fileSuffix(for: id)
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.lastPathComponent.hasSuffix(suffix) }
    }
}
