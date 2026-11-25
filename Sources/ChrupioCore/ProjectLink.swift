import Foundation

/// Links the Markdown notes folder into a project as `meetings/`, so Claude Code can read the notes as files.
public enum ProjectLink {
    public static let linkName = "meetings"
    public static let appDefaultsDomain = "com.chrupio.app"

    /// The notes folder chosen in the app's settings, falling back to the default.
    public static func notesFolder() -> URL {
        let path = UserDefaults(suiteName: appDefaultsDomain)?.string(forKey: "exportFolderPath")
        return path.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? MeetingExporter.defaultFolder
    }

    public enum LinkError: LocalizedError {
        case notADirectory(String)
        case occupied(String)

        public var errorDescription: String? {
            switch self {
            case .notADirectory(let path): "\(path) is not a folder."
            case .occupied(let path): "\(path) already exists and is not a Chrupio link; leaving it alone."
            }
        }
    }

    /// Creates or updates `<project>/meetings` → `notes` and ignores it in git. Returns a description of what changed.
    @discardableResult
    public static func link(project: URL, notes: URL = notesFolder()) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LinkError.notADirectory(project.path)
        }
        let link = project.appendingPathComponent(linkName)
        if let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            guard existing == notes.path || isNotesFolder(URL(fileURLWithPath: existing)) else {
                throw LinkError.occupied(link.path)
            }
            if existing != notes.path {
                try FileManager.default.removeItem(at: link)
            }
        } else if FileManager.default.fileExists(atPath: link.path) || (try? link.checkResourceIsReachable()) == true {
            throw LinkError.occupied(link.path)
        }
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: notes)
        }
        var message = "Linked \(link.path) -> \(notes.path)"
        if try ignoreInGit(project: project) { message += "; added /\(linkName) to .gitignore" }
        return message
    }

    /// An earlier notes folder: the default one, or one holding only Chrupio exports.
    static func isNotesFolder(_ folder: URL) -> Bool {
        if MeetingExporter.isDefaultFolder(folder) { return true }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        let visible = entries.filter { !$0.hasPrefix(".") }
        return !visible.isEmpty && visible.allSatisfy(MeetingExporter.isExportFileName)
    }

    /// Removes the link if it is a symlink; never touches a real folder.
    @discardableResult
    public static func unlink(project: URL) throws -> String {
        let link = project.appendingPathComponent(linkName)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil else {
            return "No Chrupio link in \(project.path)."
        }
        try FileManager.default.removeItem(at: link)
        return "Removed \(link.path). The /\(linkName) line in .gitignore was left in place."
    }

    /// Adds `/meetings` (no trailing slash: git sees a symlink as a file) to .gitignore in git repositories.
    static func ignoreInGit(project: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: project.appendingPathComponent(".git").path) else { return false }
        let gitignore = project.appendingPathComponent(".gitignore")
        let existing = (try? String(contentsOf: gitignore, encoding: .utf8)) ?? ""
        let entry = "/\(linkName)"
        // "meetings/" would not match: git sees a symlink as a file.
        let present = existing.split(whereSeparator: \.isNewline).contains {
            [entry, linkName].contains($0.trimmingCharacters(in: .whitespaces))
        }
        guard !present else { return false }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try (existing + separator + "# Chrupio meeting notes (symlink)\n" + entry + "\n").write(to: gitignore, atomically: true, encoding: .utf8)
        return true
    }
}
