import Foundation

/// Finds the Claude Code CLI the same way for summaries, follow-ups, onboarding, Settings and `chrupio-mcp setup`:
/// the usual install paths first, then the user's login shell (npm, nvm, volta, bun and other installs on PATH).
public enum ClaudeCLI {
    public static func knownPaths(home: String) -> [String] {
        ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
    }

    /// The first usual install path that is executable; never starts a process.
    public static func known(home: String = NSHomeDirectory(),
                             isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> URL? {
        knownPaths(home: home).first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    /// The last line of `command -v claude` output, when it is an absolute path to an executable.
    static func path(fromShell output: String, isExecutable: (String) -> Bool) -> URL? {
        guard let line = output.split(separator: "\n").last.map({ String($0).trimmingCharacters(in: .whitespaces) }),
              line.hasPrefix("/"), isExecutable(line) else { return nil }
        return URL(fileURLWithPath: line)
    }

    /// Known paths, then `shell()` (the login shell's `command -v claude` output, or nil).
    public static func locate(home: String = NSHomeDirectory(),
                              isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                              shell: @Sendable () async -> String? = loginShellOutput) async -> URL? {
        if let found = known(home: home, isExecutable: isExecutable) { return found }
        guard let output = await shell() else { return nil }
        return path(fromShell: output, isExecutable: isExecutable)
    }

    /// `command -v claude` in an interactive login zsh, so PATH set in .zshrc/.zprofile counts. 10 s at most.
    @Sendable public static func loginShellOutput() async -> String? {
        guard let result = try? await ProcessRunner.run(URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lic", "command -v claude"], timeout: 10),
              result.status == 0, !result.timedOut else { return nil }
        return result.stdout
    }
}
