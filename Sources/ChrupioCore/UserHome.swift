import Foundation

/// The home folder Chrupio reads other apps' files from: Chrome profiles, the old Desktop extension copy, the default
/// notes folder. A debug snapshot run (`CHRUPIO_SNAPSHOT_DIR` set) gets a new empty folder instead, so a screenshot
/// never shows the user's own Chrome profiles or files; the snapshot fills it with demo data.
public enum UserHome {
    public static let url: URL = resolve(environment: ProcessInfo.processInfo.environment)

    /// The real home, or for a snapshot run a fresh empty temporary folder (never the real home).
    static func resolve(environment: [String: String], real: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        guard environment["CHRUPIO_SNAPSHOT_DIR"] != nil else { return real }
        let fake = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrupio-snapshot-home-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        return fake
    }

    /// `path` with `home` written as `~`.
    public static func display(_ path: String, home: URL = url) -> String {
        let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
        if path == home.path { return "~" }
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }
}
