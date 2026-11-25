import Foundation

/// Finds whisper.cpp's `whisper-cli` and `whisper-server`. The app ships its own static build in
/// Chrupio.app/Contents/Helpers (scripts/build-whisper.sh); Homebrew's is the fallback for `swift run` and old installs.
public enum WhisperBinaries {
    public static let homebrewDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// `Contents/Helpers` of the enclosing app, for the app and for helpers in `Contents/MacOS` such as chrupio-mcp.
    static func bundledDirectory(executable: URL?) -> URL? {
        guard let macOS = executable?.resolvingSymlinksInPath().deletingLastPathComponent(), macOS.lastPathComponent == "MacOS" else { return nil }
        let contents = macOS.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents" else { return nil }
        return contents.appendingPathComponent("Helpers", isDirectory: true)
    }

    static func candidates(_ name: String, executable: URL?) -> [URL] {
        let bundled = bundledDirectory(executable: executable).map { [$0.appendingPathComponent(name)] } ?? []
        return bundled + homebrewDirectories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
    }

    public static func find(_ name: String, executable: URL? = Bundle.main.executableURL,
                            isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        candidates(name, executable: executable).first { isExecutable($0.path) }
    }

    /// True when the copy in use is the one inside the app, not Homebrew's.
    public static func isBundled(_ url: URL, executable: URL? = Bundle.main.executableURL) -> Bool {
        guard let directory = bundledDirectory(executable: executable) else { return false }
        return url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
    }
}
