import Foundation

/// What can be told about the installed Claude Code without spending quota: whether it is logged in, and whether it
/// knows the flags the isolated summary call uses. Only `claude --help` and `claude auth status` run; neither calls a model.
/// `auth status` output holds the account's email and organization: it is read for the `loggedIn` key and dropped,
/// never logged, stored or shown.
public struct ClaudeReadiness: Sendable, Equatable {
    public enum Login: Sendable, Equatable { case loggedIn, notLoggedIn, unknown }

    public var login: Login
    /// Flags the summary call passes that this CLI's help doesn't list. Advisory: help can hide flags, so the
    /// summary call's own "unknown option" error (`ClaudeSummarizerError.outdated`) is what counts.
    public var missingFlags: [String]

    public init(login: Login, missingFlags: [String] = []) {
        self.login = login
        self.missingFlags = missingFlags
    }

    /// The newer flags of `ClaudeSummarizer.arguments`, looked for in `claude --help`. The call's other flags are in
    /// `excludedFlags` and not checked, because each is older than every flag here, so a CLI that lists these has them:
    /// -p and --output-format (print mode, which every summary needs), --model, --system-prompt, --settings,
    /// --mcp-config and --max-turns. A test keeps the two lists equal to the flags the summary call passes.
    public static let requiredFlags = ["--safe-mode", "--setting-sources", "--strict-mcp-config", "--tools",
                                       "--disable-slash-commands", "--no-session-persistence", "--json-schema"]

    /// The summary call's flags `requiredFlags` leaves out, and why.
    static let excludedFlags: [String: String] = [
        "-p": "print mode itself; older than every required flag",
        "--output-format": "part of print mode; older than every required flag",
        "--model": "older than every required flag",
        "--system-prompt": "older than every required flag",
        "--settings": "older than every required flag",
        "--mcp-config": "older than every required flag; --strict-mcp-config, which is checked, needs it",
        "--max-turns": "older than every required flag",
    ]

    /// Required flags that don't appear in `help` as a whole word ("--tools" in "--allowed-tools" doesn't count).
    public static func missingFlags(inHelp help: String) -> [String] {
        requiredFlags.filter { flag in
            help.range(of: #"(?<![\w-])"# + NSRegularExpression.escapedPattern(for: flag) + #"(?![\w-])"#, options: .regularExpression) == nil
        }
    }

    /// The help lists an `auth` subcommand under `Commands:`.
    static func hasAuthCommand(inHelp help: String) -> Bool {
        guard let commands = help.range(of: #"(?m)^\s*Commands:"#, options: .regularExpression) else { return false }
        return help[commands.upperBound...].range(of: #"(?m)^[ \t]+auth(?![\w-])"#, options: .regularExpression) != nil
    }

    /// `claude auth status` prints JSON with a `loggedIn` key (exit 0 when true, 1 when false). Logged in only when
    /// both agree; not logged in when it says so; nil when the answer can't be read. A banner line before the JSON is skipped.
    static func interpret(authStatus result: ProcessResult) -> Login? {
        guard !result.timedOut else { return nil }
        if let json = firstJSONObject(in: result.stdout), let loggedIn = json["loggedIn"] as? Bool {
            if !loggedIn { return .notLoggedIn }
            return result.status == 0 ? .loggedIn : nil
        }
        if result.status != 0, (result.stdout + "\n" + result.stderr).localizedCaseInsensitiveContains("not logged in") { return .notLoggedIn }
        return nil
    }

    /// The first top-level `{…}` in `text` that parses as a JSON object; braces inside JSON strings don't count.
    static func firstJSONObject(in text: String) -> [String: Any]? {
        let bytes = Array(text.utf8)
        var start = bytes.startIndex
        while let open = bytes[start...].firstIndex(of: UInt8(ascii: "{")) {
            var depth = 0, inString = false, escaped = false
            var index = open
            while index < bytes.endIndex {
                let byte = bytes[index]
                if inString {
                    if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                } else if byte == UInt8(ascii: "\"") {
                    inString = true
                } else if byte == UInt8(ascii: "{") {
                    depth += 1
                } else if byte == UInt8(ascii: "}") {
                    depth -= 1
                    if depth == 0 { break }
                }
                index += 1
            }
            if index < bytes.endIndex,
               let json = try? JSONSerialization.jsonObject(with: Data(bytes[open...index])) as? [String: Any] { return json }
            start = open + 1
        }
        return nil
    }

    /// A Claude.ai login leaves `oauthAccount` in `.claude.json`. Without it the answer is unknown, not "logged out":
    /// API-key and cloud-provider setups have none.
    static func loginFromConfig(_ file: URL) -> Login {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unknown }
        return json["oauthAccount"] != nil ? .loggedIn : .unknown
    }

    /// `run` starts `claude` with the given arguments and returns its result, or nil when it can't be started.
    public static func check(configFile: URL, run: @Sendable ([String]) async -> ProcessResult?) async -> ClaudeReadiness {
        guard let help = await run(["--help"]), help.status == 0, !help.timedOut else {
            return ClaudeReadiness(login: loginFromConfig(configFile))
        }
        let missing = missingFlags(inHelp: help.stdout)
        if hasAuthCommand(inHelp: help.stdout), let status = await run(["auth", "status"]), let login = interpret(authStatus: status) {
            return ClaudeReadiness(login: login, missingFlags: missing)
        }
        return ClaudeReadiness(login: loginFromConfig(configFile), missingFlags: missing)
    }

    /// The real check: the same environment as the summary call (HOME, PATH, CLAUDE_CONFIG_DIR), 10 s per command.
    public static func live(executable: URL, configDir: String?, home: String = NSHomeDirectory()) async -> ClaudeReadiness {
        let summarizer = ClaudeSummarizer(executable: executable, configDir: configDir, home: home)
        let environment = summarizer.environment
        let configFile = summarizer.configDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).appendingPathComponent(".claude.json") }
            ?? URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
        return await check(configFile: configFile) { arguments in
            try? await ProcessRunner.run(executable, arguments: arguments, environment: environment, inheritEnvironment: false, timeout: 10)
        }
    }
}
