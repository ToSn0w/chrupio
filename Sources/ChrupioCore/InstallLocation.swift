import Foundation

/// Claude Code runs `chrupio-mcp` from the path Connect writes, so Connect only runs from /Applications or ~/Applications:
/// a copy in Downloads, a disk image, a build folder or a translocated copy moves or vanishes, and a download folder
/// is writable by whatever downloaded it.
public enum InstallLocation {
    public static let message = "Move Chrupio.app to your Applications folder, then connect again. Claude Code runs Chrupio's meeting tools from the app's location, so they stop working if the app moves."
    /// The same for `chrupio-mcp setup`, which has no Connect button.
    public static let commandLineMessage = "Move Chrupio.app to your Applications folder, then run setup again. Claude Code runs Chrupio's meeting tools from the app's location, so they stop working if the app moves."

    /// Nil when the app is inside /Applications or ~/Applications (any depth), otherwise the message. Both the path as
    /// given (what Claude Code stores) and the path with symlinks resolved (where the files are) must be inside.
    public static func refusal(bundleURL: URL, home: String = NSHomeDirectory()) -> String? {
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        let roots = Set(["/Applications", comparable(homeURL.standardizedFileURL) + "/Applications",
                         comparable(homeURL.resolvingSymlinksInPath()) + "/Applications"])
        let paths = [comparable(bundleURL.standardizedFileURL), comparable(bundleURL.resolvingSymlinksInPath())]
        let allowed = paths.allSatisfy { path in
            !path.contains("/AppTranslocation/") && roots.contains { path.hasPrefix($0 + "/") }
        }
        return allowed ? nil : message
    }

    /// The refusal judged by the app bundle the binary sits in; `commandLine` words it for `chrupio-mcp setup`.
    public static func refusal(serverBinary: URL, home: String = NSHomeDirectory(), commandLine: Bool = false) -> String? {
        refusal(bundleURL: bundle(ofServerBinary: serverBinary), home: home).map { _ in commandLine ? commandLineMessage : message }
    }

    /// `Chrupio.app` for `Chrupio.app/Contents/MacOS/chrupio-mcp`.
    public static func bundle(ofServerBinary binary: URL) -> URL {
        binary.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The path without a trailing slash, and /var, /tmp and /etc written without their /private prefix, so a resolved
    /// path and an unresolved one compare equal.
    private static func comparable(_ url: URL) -> String {
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        for alias in ["/var", "/tmp", "/etc"] where path == "/private" + alias || path.hasPrefix("/private" + alias + "/") {
            path.removeFirst("/private".count)
        }
        return path
    }
}
