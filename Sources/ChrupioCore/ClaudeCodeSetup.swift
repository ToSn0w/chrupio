import Foundation

/// Connects Chrupio to Claude Code: registers the `chrupio` MCP server at user scope and installs the
/// SessionStart digest hook and the UserPromptSubmit hook that reports meetings finished mid-session. Shared by the app, `chrupio-mcp setup` and scripts/install.sh.
///
/// Claude Code keeps user-scope MCP servers in `~/.claude.json`, but in `$CLAUDE_CONFIG_DIR/.claude.json`
/// when that variable is set, so a registration made in one environment is invisible in the other.
/// Every configuration home that exists is therefore set up, plus any other `~/.claude-*` home that already
/// holds OpenKrisp's or Chrupio's server or hooks, so Connect replaces them there too and Disconnect removes them.
public struct ClaudeCodeSetup: Sendable {
    public static let serverName = "chrupio"
    /// What OpenKrisp registered; Connect replaces it and Disconnect removes it.
    public static let legacyServerName = "openkrisp"
    static let binaryNames = ["chrupio-mcp", "openkrisp-mcp"]

    /// One Claude Code configuration home.
    public struct Target: Sendable, Hashable {
        /// The CLAUDE_CONFIG_DIR value, or nil for Claude's default.
        public let configDir: URL?
        /// Where user-scope MCP servers are stored.
        public let mcpConfigFile: URL
        /// Where user hooks are stored.
        public let settingsFile: URL

        public var label: String {
            mcpConfigFile.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
    }

    public struct Status: Sendable, Equatable {
        public let target: Target
        /// The registered command, nil when `chrupio` is not registered there.
        public let registeredCommand: String?
        public let hookInstalled: Bool
        public let promptHookInstalled: Bool
        /// The command OpenKrisp registered as `openkrisp`, nil when it is gone.
        public let legacyCommand: String?
        /// An OpenKrisp hook is still in this target's settings.
        public let legacyHookInstalled: Bool
        /// A digest hook of ours is there for any path, this app's or a moved copy's or OpenKrisp's (`hookInstalled`
        /// needs the current command). Says the user had the hook, so setup and migration keep it.
        public let digestHookFound: Bool
        /// The same for the prompt hook.
        public let promptHookFound: Bool

        /// `digestHookFound` and `promptHookFound` default to the installed values.
        public init(target: Target, registeredCommand: String?, hookInstalled: Bool, promptHookInstalled: Bool,
                    legacyCommand: String? = nil, legacyHookInstalled: Bool = false,
                    digestHookFound: Bool? = nil, promptHookFound: Bool? = nil) {
            self.target = target
            self.registeredCommand = registeredCommand
            self.hookInstalled = hookInstalled
            self.promptHookInstalled = promptHookInstalled
            self.legacyCommand = legacyCommand
            self.legacyHookInstalled = legacyHookInstalled
            self.digestHookFound = digestHookFound ?? hookInstalled
            self.promptHookFound = promptHookFound ?? promptHookInstalled
        }

        public var hasLegacy: Bool { legacyCommand != nil || legacyHookInstalled }
    }

    public enum Connection: Sendable, Equatable {
        case connected
        case notConnected
        /// Set up in some targets, for another copy of the app, or with OpenKrisp leftovers that Connect replaces.
        case partial
    }

    /// What Connect installs. The app stores the user's choice; every caller passes one, so none gets both hooks by default.
    public struct Components: Sendable, Equatable, Codable {
        /// The `chrupio` MCP server (meeting tools).
        public var mcp: Bool
        /// The SessionStart hook (recent meetings at session start).
        public var digest: Bool
        /// The UserPromptSubmit hook (new meetings while you work).
        public var prompt: Bool

        public init(mcp: Bool, digest: Bool, prompt: Bool) {
            self.mcp = mcp
            self.digest = digest
            self.prompt = prompt
        }

        public static let all = Components(mcp: true, digest: true, prompt: true)
        /// A new Connect: the tools, no hooks.
        public static let defaults = Components(mcp: true, digest: false, prompt: false)
        public static let none = Components(mcp: false, digest: false, prompt: false)

        public var isEmpty: Bool { !mcp && !digest && !prompt }

        func wants(_ hook: Hook) -> Bool { hook.event == ClaudeCodeSetup.digestHook.event ? digest : prompt }

        /// Onboarding's line under Connect: what Connect adds with these switches.
        public var connectLine: String {
            if self == .defaults {
                return "Adds the meeting tools only. Turn on the session digest and meeting updates in Settings → Claude Code."
            }
            let parts = [mcp ? "the meeting tools" : nil, digest ? "the session digest" : nil, prompt ? "meeting updates" : nil]
            guard let list = Self.list(parts.compactMap { $0 }) else {
                return "Nothing is switched on. Turn on at least one switch in Settings → Claude Code."
            }
            return "Adds \(list), as set in Settings → Claude Code."
        }

        /// "a", "a and b", "a, b and c"; nil when empty.
        static func list(_ items: [String]) -> String? {
            guard let last = items.last else { return nil }
            return items.count == 1 ? last : items.dropLast().joined(separator: ", ") + " and " + last
        }
    }

    /// The stored choice, or else what an earlier Connect installed (an upgrade keeps it), or nil: never connected.
    public static func migrated(stored: Components?, installed: Components?) -> Components? {
        stored ?? installed
    }

    /// What `chrupio-mcp setup` (and so scripts/install.sh) installs: the server, plus the hooks an earlier setup
    /// left, so running it again never removes a hook the user had; a first setup gets `.defaults`.
    public static func commandLineSetup(installed: Components?) -> Components {
        var components = installed ?? .defaults
        components.mcp = true
        return components
    }

    /// Connected when every target has exactly `components` for this binary and nothing of OpenKrisp is left. A hook
    /// that is off must be gone for any path: a moved copy's hook still runs.
    public static func connection(_ statuses: [Status], binary: String, components: Components) -> Connection {
        if statuses.contains(where: \.hasLegacy) { return .partial }
        if !components.isEmpty, statuses.allSatisfy({
            $0.registeredCommand == (components.mcp ? binary : nil)
                && (components.digest ? $0.hookInstalled : !$0.digestHookFound)
                && (components.prompt ? $0.promptHookInstalled : !$0.promptHookFound)
        }) { return .connected }
        if statuses.allSatisfy({ $0.registeredCommand == nil && !$0.digestHookFound && !$0.promptHookFound }) { return .notConnected }
        return .partial
    }

    public let home: URL
    public let serverBinary: URL
    private let configDirOverride: String?
    private let extraConfigDir: String?
    private let knownConfigDirs: [String]

    /// `extraConfigDir` is the config dir set in the app's Settings; empty means none. `knownConfigDirs` are config dirs
    /// an earlier Connect wrote to (the app records them), so Disconnect still finds them.
    public init(
        serverBinary: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        extraConfigDir: String? = nil,
        knownConfigDirs: [String] = []
    ) {
        self.serverBinary = serverBinary
        self.home = home
        configDirOverride = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        self.extraConfigDir = extraConfigDir.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        self.knownConfigDirs = knownConfigDirs
    }

    /// The default home, `~/.claude` when it holds its own config, `$CLAUDE_CONFIG_DIR`, the Settings config dir and
    /// the known config dirs when they hold a `.claude.json`, and every discovered home (see `discoveredHomes`). Each config file is listed once,
    /// compared after resolving symlinks.
    public func targets() -> [Target] {
        let defaultSettings = home.appendingPathComponent(".claude/settings.json")
        var targets = [Target(configDir: nil, mcpConfigFile: home.appendingPathComponent(".claude.json"), settingsFile: defaultSettings)]
        var dirs: [URL] = []
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        if FileManager.default.fileExists(atPath: claudeDir.appendingPathComponent(".claude.json").path) { dirs.append(claudeDir) }
        if let configDirOverride { dirs.append(URL(fileURLWithPath: (configDirOverride as NSString).expandingTildeInPath, isDirectory: true)) }
        if let extraConfigDir {
            let dir = URL(fileURLWithPath: (extraConfigDir as NSString).expandingTildeInPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".claude.json").path) { dirs.append(dir) }
        }
        for known in knownConfigDirs {
            let dir = URL(fileURLWithPath: (known as NSString).expandingTildeInPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".claude.json").path) { dirs.append(dir) }
        }
        dirs += discoveredHomes()
        func key(_ file: URL) -> URL { file.resolvingSymlinksInPath().standardizedFileURL }
        for dir in dirs {
            let target = Target(configDir: dir, mcpConfigFile: dir.appendingPathComponent(".claude.json"),
                                settingsFile: dir.appendingPathComponent("settings.json"))
            if !targets.contains(where: { key($0.mcpConfigFile) == key(target.mcpConfigFile) }) {
                targets.append(target)
            }
        }
        return targets
    }

    /// Other Claude homes in `home` (`.claude-alt` and the like) whose `.claude.json` registers `openkrisp` or `chrupio`,
    /// or whose settings.json runs an `openkrisp-mcp`/`chrupio-mcp` hook. `~/.claude` itself is covered by `targets()`.
    func discoveredHomes() -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: home.path) else { return [] }
        return names.filter { $0.hasPrefix(".claude-") }.sorted().map { home.appendingPathComponent($0, isDirectory: true) }.filter { dir in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
            let config = dir.appendingPathComponent(".claude.json")
            if Self.registeredCommand(in: config, name: Self.legacyServerName) != nil || Self.registeredCommand(in: config) != nil { return true }
            guard let settings = try? Self.readSettings(dir.appendingPathComponent("settings.json")) else { return false }
            return Self.hooks.contains { Self.hasOurHook(settings, $0) }
        }
    }

    /// Settings hold a hook of ours for `hook`, for any path (see `isOurHook`).
    static func hasOurHook(_ settings: [String: Any], _ hook: Hook) -> Bool {
        entries(settings, hook.event).contains { isOurHook($0, hook) }
    }

    public func status() -> [Status] {
        targets().map {
            let settings = (try? Self.readSettings($0.settingsFile)) ?? [:]
            return Status(target: $0, registeredCommand: Self.registeredCommand(in: $0.mcpConfigFile),
                          hookInstalled: hookInstalled(in: settings, Self.digestHook),
                          promptHookInstalled: hookInstalled(in: settings, Self.promptHook),
                          legacyCommand: Self.registeredCommand(in: $0.mcpConfigFile, name: Self.legacyServerName),
                          legacyHookInstalled: Self.hooks.contains { hook in Self.entries(settings, hook.event).contains { Self.isLegacyHook($0, hook) } },
                          digestHookFound: Self.hasOurHook(settings, Self.digestHook),
                          promptHookFound: Self.hasOurHook(settings, Self.promptHook))
        }
    }

    public func isConnected(_ components: Components) -> Bool {
        Self.connection(status(), binary: serverBinary.path, components: components) == .connected
    }

    /// What an earlier Connect left, read from the files: a part counts when any target has it, for any path (a moved
    /// app, OpenKrisp), as Connect replaces those. Nil when nothing is there.
    public func installedComponents() -> Components? {
        Self.installedComponents(status())
    }

    static func installedComponents(_ statuses: [Status]) -> Components? {
        let found = Components(mcp: statuses.contains { $0.registeredCommand != nil || $0.legacyCommand != nil },
                               digest: statuses.contains(where: \.digestHookFound),
                               prompt: statuses.contains(where: \.promptHookFound))
        return found.isEmpty ? nil : found
    }

    /// `chrupio-mcp status`, one line per target. The command line has no stored choice, so a hook counts as switched
    /// off when `setup` wouldn't install it (no target has it) and reads "off" rather than "missing". A hook of ours
    /// for another path reads "points to another copy".
    public func statusLines() -> [String] {
        let statuses = status()
        let chosen = Self.commandLineSetup(installed: Self.installedComponents(statuses))
        return statuses.map { status in
            let server = status.registeredCommand.map { $0 == serverBinary.path ? "registered" : "registered to \($0)" } ?? "not registered"
            let digest = status.hookInstalled ? "digest hook installed"
                : status.digestHookFound ? "digest hook points to another copy" : chosen.digest ? "digest hook missing" : "digest off"
            let prompt = status.promptHookInstalled ? "prompt hook installed"
                : status.promptHookFound ? "prompt hook points to another copy" : chosen.prompt ? "prompt hook missing" : "prompt updates off"
            return "\(status.target.label): MCP \(server); \(digest); \(prompt)"
                + (status.hasLegacy ? "; OpenKrisp leftovers (run setup to replace them)" : "")
        }
    }

    // MARK: MCP registration

    /// Read through NSDictionary, never `[String: Any]`: `.claude.json` keys `projects` by folder path, and a Swift
    /// dictionary would merge two paths that differ only in Unicode normalization.
    static func registeredCommand(in file: URL, name: String = serverName) -> String? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? NSDictionary,
              let server = (json["mcpServers"] as? NSDictionary)?[name] as? NSDictionary else { return nil }
        return server["command"] as? String ?? ""
    }

    /// The `claude` command: usual install paths, then the login shell (see `ClaudeCLI`).
    public static func findCLI(home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> URL? {
        await ClaudeCLI.locate(home: home.path)
    }

    private func claude(_ cli: URL, _ arguments: [String], target: Target) async throws -> ProcessResult {
        try await ProcessRunner.run(cli, arguments: arguments, environment: ["CLAUDE_CONFIG_DIR": target.configDir?.path], timeout: 30)
    }

    /// Registers the server in one config. An existing registration is only replaced when it differs,
    /// and is restored if the new one can't be added.
    func register(_ target: Target, cli: URL) async throws {
        let current = Self.registeredCommand(in: target.mcpConfigFile)
        if current == serverBinary.path { return }
        if current != nil {
            _ = try await claude(cli, ["mcp", "remove", "--scope", "user", Self.serverName], target: target)
        }
        let added = try await claude(cli, ["mcp", "add", "--scope", "user", Self.serverName, "--", serverBinary.path], target: target)
        if added.status != 0 || Self.registeredCommand(in: target.mcpConfigFile) != serverBinary.path {
            if let current, !current.isEmpty {
                _ = try? await claude(cli, ["mcp", "add", "--scope", "user", Self.serverName, "--", current], target: target)
            }
            throw SetupError.failed(Self.firstLine(added.stderr.isEmpty ? added.stdout : added.stderr) ?? "claude mcp add failed")
        }
    }

    func unregister(_ target: Target, cli: URL) async throws {
        guard Self.registeredCommand(in: target.mcpConfigFile) != nil else { return }
        let removed = try await claude(cli, ["mcp", "remove", "--scope", "user", Self.serverName], target: target)
        if removed.status != 0 {
            throw SetupError.failed(Self.firstLine(removed.stderr) ?? "claude mcp remove failed")
        }
    }

    /// Removes OpenKrisp's registration from one config; nothing when there is none.
    func unregisterLegacy(_ target: Target, cli: URL) async throws {
        guard Self.registeredCommand(in: target.mcpConfigFile, name: Self.legacyServerName) != nil else { return }
        let removed = try await claude(cli, ["mcp", "remove", "--scope", "user", Self.legacyServerName], target: target)
        if removed.status != 0 {
            throw SetupError.failed(Self.firstLine(removed.stderr) ?? "claude mcp remove \(Self.legacyServerName) failed")
        }
    }

    /// How often Chrupio tries to edit `.claude.json`, which every open Claude Code session saves often.
    static let configFileAttempts = 5

    /// Deletes `chrupio` and `openkrisp` from `.claude.json` directly, for when the CLI is gone. True when it removed
    /// something. Edited as `JSONValue`, never as a Swift dictionary (see `registeredCommand`), so everything else is
    /// written back as it was. Backed up like settings.json, with private backups: the file holds MCP server secrets.
    @discardableResult
    func removeServerEntries(_ target: Target, names: [String] = [serverName, legacyServerName], retryDelay: TimeInterval = 0.05,
                             beforeWrite: () throws -> Void = {}) throws -> Bool {
        guard FileManager.default.fileExists(atPath: target.mcpConfigFile.path) else { return false }
        let names = names.map { Array($0.unicodeScalars) }
        var removed = false
        try Self.updateJSON(target.mcpConfigFile, attempts: Self.configFileAttempts, retryDelay: retryDelay, beforeWrite: beforeWrite) { config in
            removed = false
            guard case .object(var members)? = config,
                  let index = members.firstIndex(where: { Array($0.key.unicodeScalars) == Array("mcpServers".unicodeScalars) }),
                  case .object(let servers) = members[index].value else { return nil }
            let kept = servers.filter { !names.contains(Array($0.key.unicodeScalars)) }
            guard kept.count != servers.count else { return nil }
            members[index].value = .object(kept)
            removed = true
            return .object(members)
        }
        return removed
    }

    /// Removes our server from one target, with the CLI when there is one. True when `.claude.json` was edited directly,
    /// which open Claude Code sessions don't notice (and may write back) until they restart.
    func removeMCP(_ target: Target, cli: URL?) async throws -> Bool {
        if let cli {
            try await unregister(target, cli: cli)
            try await unregisterLegacy(target, cli: cli)
            return false
        }
        return try removeServerEntries(target)
    }

    public static let restartLine = "Restart open Claude Code sessions."

    // MARK: Hooks

    /// One hook Chrupio installs: a Claude Code event and the `chrupio-mcp` subcommand it runs.
    public struct Hook: Sendable {
        public let event: String
        public let subcommand: String
        public let timeout: Int
    }

    public static let digestHook = Hook(event: "SessionStart", subcommand: "digest", timeout: 10)
    public static let promptHook = Hook(event: "UserPromptSubmit", subcommand: "prompt-hook", timeout: 5)
    public static let hooks = [digestHook, promptHook]

    public func command(for hook: Hook) -> String {
        "'\(serverBinary.path.replacingOccurrences(of: "'", with: "'\\''"))' \(hook.subcommand)"
    }

    public var hookCommand: String { command(for: Self.digestHook) }

    /// Our hook is recognised by its command, so a moved app is replaced rather than duplicated. The command must be
    /// exactly what `command(for:)` writes, for any path: the binary (quoted or not) and the subcommand, nothing else.
    static func isOurHook(_ entry: [String: Any], _ hook: Hook = digestHook) -> Bool {
        hookBinaryName(entry, hook).map(binaryNames.contains) ?? false
    }

    /// A hook OpenKrisp installed.
    static func isLegacyHook(_ entry: [String: Any], _ hook: Hook = digestHook) -> Bool {
        hookBinaryName(entry, hook) == "openkrisp-mcp"
    }

    /// The file name of the program a two-word `<program> <subcommand>` hook command runs, nil for any other command.
    static func hookBinaryName(_ entry: [String: Any], _ hook: Hook) -> String? {
        guard let command = entry["command"] as? String, let words = shellWords(command),
              words.count == 2, words[1] == hook.subcommand else { return nil }
        return (words[0] as NSString).lastPathComponent
    }

    /// Splits a command line the way the shell would for plain words: whitespace separates, single quotes are literal,
    /// double quotes and backslashes escape. Nil when the command uses anything else the shell would interpret
    /// (operators, redirections, expansions) or leaves a quote open.
    static func shellWords(_ command: String) -> [String]? {
        var words: [String] = []
        var word = ""
        var inWord = false
        var characters = command.makeIterator()
        while let character = characters.next() {
            switch character {
            case " ", "\t":
                if inWord { words.append(word); word = ""; inWord = false }
            case "'":
                inWord = true
                while true {
                    guard let next = characters.next() else { return nil }
                    if next == "'" { break }
                    word.append(next)
                }
            case "\"":
                inWord = true
                while true {
                    guard let next = characters.next() else { return nil }
                    if next == "\"" { break }
                    if next == "$" || next == "`" { return nil }
                    if next == "\\" {
                        guard let escaped = characters.next() else { return nil }
                        if !"\"\\$`".contains(escaped) { word.append(next) }
                        word.append(escaped)
                    } else {
                        word.append(next)
                    }
                }
            case "\\":
                guard let escaped = characters.next() else { return nil }
                inWord = true
                word.append(escaped)
            default:
                if ";&|<>()$`*?[]{}!#\n\r".contains(character) { return nil }
                inWord = true
                word.append(character)
            }
        }
        if inWord { words.append(word) }
        return words
    }

    func hookInstalled(in file: URL, _ hook: Hook = digestHook) -> Bool {
        guard let settings = try? Self.readSettings(file) else { return false }
        return hookInstalled(in: settings, hook)
    }

    /// Installed once, with the current command; a stale copy elsewhere counts as not installed.
    func hookInstalled(in settings: [String: Any], _ hook: Hook) -> Bool {
        let ours = Self.entries(settings, hook.event).filter { Self.isOurHook($0, hook) }
        return ours.count == 1 && (ours[0]["command"] as? String) == command(for: hook)
    }

    static func entries(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
        let groups = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    }

    static func sessionStartHooks(_ settings: [String: Any]) -> [[String: Any]] {
        entries(settings, digestHook.event)
    }

    /// Settings with our hook removed; other hooks and keys are kept.
    static func removingHook(from settings: [String: Any], _ hook: Hook = digestHook) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any], let groups = hooks[hook.event] as? [[String: Any]] else { return settings }
        let kept: [[String: Any]] = groups.compactMap { group in
            guard let entries = group["hooks"] as? [[String: Any]] else { return group }
            let remaining = entries.filter { !isOurHook($0, hook) }
            if remaining.isEmpty, !entries.isEmpty { return nil }
            var group = group
            group["hooks"] = remaining
            return group
        }
        if kept.isEmpty { hooks.removeValue(forKey: hook.event) } else { hooks[hook.event] = kept }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        return settings
    }

    /// Settings with our hook running `command`. A hook of ours already there (a moved copy's, OpenKrisp's) is rewritten
    /// where the first one sits, so its group keeps its matcher and place; any other copies are removed. Without one,
    /// the hook goes in a new group at the end.
    static func addingHook(to settings: [String: Any], command: String, _ hook: Hook = digestHook) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var groups = hooks[hook.event] as? [[String: Any]] ?? []
        var placed = false
        groups = groups.compactMap { group in
            guard let entries = group["hooks"] as? [[String: Any]] else { return group }
            var kept: [[String: Any]] = []
            for entry in entries {
                guard isOurHook(entry, hook) else { kept.append(entry); continue }
                if placed { continue }
                placed = true
                var rewritten = entry
                rewritten["type"] = "command"
                rewritten["command"] = command
                rewritten["timeout"] = hook.timeout
                kept.append(rewritten)
            }
            if kept.isEmpty, !entries.isEmpty { return nil }
            var group = group
            group["hooks"] = kept
            return group
        }
        if !placed { groups.append(["hooks": [["type": "command", "command": command, "timeout": hook.timeout]]]) }
        hooks[hook.event] = groups
        settings["hooks"] = hooks
        return settings
    }

    static func readSettings(_ file: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try settings(from: Data(contentsOf: file), file: file)
    }

    private static func settings(from data: Data, file: URL) throws -> [String: Any] {
        if isBlank(data) { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SetupError.failed("\(file.path) is not a JSON object; not changing it")
        }
        return json
    }

    private static func isBlank<Bytes: Sequence<UInt8>>(_ bytes: Bytes) -> Bool {
        bytes.allSatisfy { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
    }

    private static let byteOrderMark = Data([0xEF, 0xBB, 0xBF])

    private static func unreadable(_ file: URL) -> SetupError {
        .failed("Chrupio didn't change \(file.path): it couldn't read the file exactly as written. Fix it or add the setting by hand.")
    }

    /// A Claude Code JSON file as Chrupio read it before changing it.
    private struct Snapshot {
        /// The file whose bytes are rewritten: `file` itself, or what its link points to.
        let real: URL
        /// The exact bytes read, nil when there was no file. Backups are written from these, not copied from disk.
        let data: Data?
        /// The parsed file (after any byte order mark); nil when there was no file or only whitespace.
        let value: JSONValue?
    }

    /// Reads the file once and parses it strictly (see `OrderedJSON.parse`). A file Chrupio can't read exactly as
    /// written (not UTF-8, a trailing comma, a repeated key), or that isn't a JSON object, is refused.
    private static func snapshot(_ file: URL) throws -> Snapshot {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else {
            // fileExists follows links: a link to nothing would be replaced by a regular file, so leave it to the user.
            if let destination = try? manager.destinationOfSymbolicLink(atPath: file.path) {
                throw SetupError.failed("Chrupio didn't change \(file.path): it links to \(destination), which doesn't exist. "
                    + "Fix the link or add the setting by hand.")
            }
            return Snapshot(real: file, data: nil, value: nil)
        }
        let real = file.resolvingSymlinksInPath()
        let data = try Data(contentsOf: real)
        let body = data.starts(with: byteOrderMark) ? data.dropFirst(byteOrderMark.count) : data[...]
        if isBlank(body) { return Snapshot(real: real, data: data, value: nil) }
        guard let value = try? OrderedJSON.parse(Data(body)) else { throw unreadable(file) }
        guard case .object = value else { throw SetupError.failed("\(file.path) is not a JSON object; not changing it") }
        return Snapshot(real: real, data: data, value: value)
    }

    /// Reads a Claude Code JSON file, applies `change` to the parsed file, and writes the result with the user's key
    /// order, number spelling and string keys kept exactly (see `OrderedJSON`). `change` returns nil, or the same value,
    /// to write nothing. A leading UTF-8 byte order mark and a missing newline at the end are kept, so only what Chrupio
    /// changes differs. If the file changes between the read and the write (Claude Code saving it), it is read and
    /// changed again, up to `attempts` times in all, waiting a little longer each time, then refused. `beforeWrite`
    /// lets tests change the file at that moment.
    ///
    /// The first time Chrupio changes a file, a dated copy is made and never touched again; `.chrupio-backup` always
    /// holds the version before the latest change. Both are 0600 (the files can hold secrets) and written from the bytes
    /// Chrupio read. A file that exists keeps its mode, and a symlinked one (dotfiles) stays a link: its target is
    /// rewritten. A link to a missing file is refused. A file Chrupio creates is 0600.
    static func updateJSON(_ file: URL, attempts: Int = 2, retryDelay: TimeInterval = 0, now: Date = Date(),
                           beforeWrite: () throws -> Void = {}, _ change: (JSONValue?) throws -> JSONValue?) throws {
        for attempt in 1...max(attempts, 1) {
            if attempt > 1, retryDelay > 0 { Thread.sleep(forTimeInterval: retryDelay * Double(attempt - 1)) }
            let read = try snapshot(file)
            guard let updated = try change(read.value), updated != read.value else { return }
            try beforeWrite()
            if try write(updated, over: read, file: file, now: now) { return }
        }
        throw SetupError.failed("Chrupio didn't change \(file.path): it changed while Chrupio was editing it. Try again.")
    }

    /// `updateJSON` for settings.json, whose hook code edits a `[String: Any]`. Nothing is written when `change`
    /// changes nothing.
    static func updateSettings(_ file: URL, now: Date = Date(), beforeWrite: () throws -> Void = {},
                               _ change: ([String: Any]) throws -> [String: Any]) throws {
        try updateJSON(file, now: now, beforeWrite: beforeWrite) { original in
            let settings = try editableSettings(original, file: file)
            let updated = try change(settings)
            if NSDictionary(dictionary: settings).isEqual(to: updated) { return nil }
            return OrderedJSON.merge(updated, into: original)
        }
    }

    /// The top level as a Swift dictionary for the hook code; every value below it stays a Foundation object, whose
    /// dictionaries keep keys that differ only in Unicode normalization apart. Refused when the top level or `hooks`
    /// has two such keys: the hook code reads those parts as Swift dictionaries, which would silently keep only one.
    private static func editableSettings(_ value: JSONValue?, file: URL) throws -> [String: Any] {
        guard case .object(let members)? = value else { return [:] }
        if OrderedJSON.hasLookalikeKeys(.object(members.map { .init(key: $0.key, value: .null) }))
            || members.contains(where: { $0.key == "hooks" && OrderedJSON.hasLookalikeKeys($0.value) }) {
            throw unreadable(file)
        }
        var settings: [String: Any] = [:]
        for member in members { settings[member.key] = OrderedJSON.foundationObject(member.value) }
        return settings
    }

    /// Writes `value` over what `read` saw. False, with the file untouched, when it no longer holds those bytes.
    private static func write(_ value: JSONValue, over read: Snapshot, file: URL, now: Date) throws -> Bool {
        let manager = FileManager.default
        var prefix = Data()
        var text = OrderedJSON.serialize(value)
        if let data = read.data {
            if data.starts(with: byteOrderMark) { prefix = byteOrderMark }
            // Claude Code writes its files without a newline at the end; keep whichever the file had.
            if !isBlank(data.dropFirst(prefix.count)), data.last != UInt8(ascii: "\n"), text.hasSuffix("\n") { text.removeLast() }
        }
        try manager.createDirectory(at: read.real.deletingLastPathComponent(), withIntermediateDirectories: true)
        var mode: mode_t = 0o600
        if read.data != nil, let existing = (try? manager.attributesOfItem(atPath: read.real.path))?[.posixPermissions] as? NSNumber {
            mode = mode_t(existing.uint16Value & 0o7777)
        }
        // The new file is written and synced first, so the gap between this last check and the rename is as short as it gets.
        // The backups are written only once the file still holds what was read, so a refused attempt leaves them alone.
        return try FilePermissions.writePrivately(prefix + Data(text.utf8), to: read.real, mode: mode) {
            guard (manager.fileExists(atPath: read.real.path) ? try Data(contentsOf: read.real) : nil) == read.data else { return false }
            if let data = read.data { try backUp(data, as: file, now: now) }
            return true
        }
    }

    /// Saves `data` (the file as Chrupio read it) next to `file` (the path Chrupio was given, which may be a link):
    /// once as `<name>.chrupio-backup-<yyyyMMdd-HHmmss>`, kept forever, and every time as `<name>.chrupio-backup`. Both 0600.
    static func backUp(_ data: Data, as file: URL, now: Date) throws {
        let folder = file.deletingLastPathComponent()
        let prefix = file.lastPathComponent + ".chrupio-backup-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if !names.contains(where: { $0.hasPrefix(prefix) }) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            try FilePermissions.writePrivately(data, to: folder.appendingPathComponent(prefix + formatter.string(from: now)))
        }
        try FilePermissions.writePrivately(data, to: file.appendingPathExtension("chrupio-backup"))
    }

    /// Adds the hooks `components` wants and removes the others; other hooks are kept. No change, no write
    /// (so with every hook off and no settings file, none is created). With every hook off, a file without one of
    /// ours (read leniently, as `status()` does) is not opened for writing, so one Chrupio can't rewrite doesn't fail.
    func installHook(_ target: Target, _ components: Components) throws {
        if !components.digest, !components.prompt {
            guard let settings = try? Self.readSettings(target.settingsFile), Self.hooks.contains(where: { Self.hasOurHook(settings, $0) })
            else { return }
        }
        try Self.updateSettings(target.settingsFile) { settings in
            // Leave an up-to-date hook where it is, so its position among the user's hooks doesn't churn.
            Self.hooks.reduce(settings) { settings, hook in
                if !components.wants(hook) { return Self.removingHook(from: settings, hook) }
                return hookInstalled(in: settings, hook) ? settings : Self.addingHook(to: settings, command: command(for: hook), hook)
            }
        }
    }

    /// Removes both hooks. A settings file without one of ours (read leniently, as in `installHook`) is not opened for
    /// writing, so one Chrupio can't rewrite doesn't make Disconnect fail.
    func removeHook(_ target: Target) throws {
        guard FileManager.default.fileExists(atPath: target.settingsFile.path) else { return }
        guard let settings = try? Self.readSettings(target.settingsFile), Self.hooks.contains(where: { Self.hasOurHook(settings, $0) })
        else { return }
        try Self.updateSettings(target.settingsFile) { settings in Self.hooks.reduce(settings) { Self.removingHook(from: $0, $1) } }
    }

    /// Removes the hooks `components` has off from every settings file that holds them. Adds nothing and leaves the
    /// server alone, so it needs neither the CLI nor the install location: a switch turned off takes effect even when
    /// Connect can't run. One line: what was removed, or what couldn't be; nil when nothing was there.
    public func removeHooksSwitchedOff(_ components: Components) -> (line: String?, ok: Bool) {
        let off = Self.hooks.filter { !components.wants($0) }
        var removed = Set<String>()
        var failures: [String] = []
        var done = Set<URL>()
        for target in targets() where done.insert(target.settingsFile.standardizedFileURL).inserted {
            guard let settings = try? Self.readSettings(target.settingsFile) else { continue }
            let ours = off.filter { Self.hasOurHook(settings, $0) }
            guard !ours.isEmpty else { continue }
            do {
                try Self.updateSettings(target.settingsFile) { settings in ours.reduce(settings) { Self.removingHook(from: $0, $1) } }
                removed.formUnion(ours.map(\.event))
            } catch {
                failures.append("Hook NOT removed from \(target.settingsFile.path): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { return (failures.joined(separator: " "), false) }
        let names = [removed.contains(Self.digestHook.event) ? "the session digest" : nil,
                     removed.contains(Self.promptHook.event) ? "meeting updates" : nil]
        return (Components.list(names.compactMap { $0 }).map { "Removed \($0) from Claude Code." }, true)
    }

    // MARK: Whole setup

    /// Sets up `components` everywhere and removes the parts that are off. Returns one line per action.
    public func connect(cli: URL?, components: Components) async -> (lines: [String], ok: Bool) {
        var lines: [String] = []
        var ok = true
        var editedDirectly = false
        let targets = targets()
        if components.mcp, cli == nil {
            ok = false
            lines.append("Claude Code CLI not found. Register by hand: claude mcp add --scope user \(Self.serverName) -- \(serverBinary.path)")
        }
        for target in targets {
            if cli != nil || components.mcp {
                // A stuck OpenKrisp server must not keep Chrupio out: warn and go on. Without the CLI it is deleted from
                // `.claude.json` directly (with the server off, the branch below removes it with ours).
                do {
                    if let cli {
                        try await unregisterLegacy(target, cli: cli)
                    } else if Self.registeredCommand(in: target.mcpConfigFile, name: Self.legacyServerName) != nil,
                              try removeServerEntries(target, names: [Self.legacyServerName]) {
                        editedDirectly = true
                    }
                } catch {
                    lines.append("Warning: OpenKrisp server NOT removed from \(target.label): \(error.localizedDescription). "
                        + "Remove it by hand: claude mcp remove --scope user \(Self.legacyServerName)")
                }
            }
            if components.mcp {
                guard let cli else { continue }
                do {
                    try await register(target, cli: cli)
                    lines.append("MCP server registered in \(target.label)")
                } catch {
                    ok = false
                    lines.append("MCP server NOT registered in \(target.label): \(error.localizedDescription)")
                }
            } else if Self.registeredCommand(in: target.mcpConfigFile) != nil
                        || Self.registeredCommand(in: target.mcpConfigFile, name: Self.legacyServerName) != nil {
                do {
                    if try await removeMCP(target, cli: cli) { editedDirectly = true }
                    lines.append("MCP server removed from \(target.label)")
                } catch {
                    ok = false
                    lines.append("Could not fully remove from \(target.label): \(error.localizedDescription)")
                }
            }
        }
        // Several targets can share one settings file (the default home and ~/.claude both use ~/.claude/settings.json).
        var done = Set<URL>()
        for target in targets where done.insert(target.settingsFile.standardizedFileURL).inserted {
            do {
                try installHook(target, components)
                let path = target.settingsFile.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                lines.append("Hooks in \(path): session digest \(components.digest ? "on" : "off"), prompt updates \(components.prompt ? "on" : "off")")
            } catch {
                ok = false
                let verb = components.digest || components.prompt ? "NOT installed in" : "NOT removed from"
                lines.append("Hook \(verb) \(target.settingsFile.path): \(error.localizedDescription)")
            }
        }
        if editedDirectly { lines.append(Self.restartLine) }
        return (lines, ok)
    }

    /// Removes the server and both hooks everywhere. Without the CLI, `.claude.json` is edited directly.
    public func disconnect(cli: URL?) async -> (lines: [String], ok: Bool) {
        var lines: [String] = []
        var ok = true
        var editedDirectly = false
        for target in targets() {
            // The hooks come out even when the server can't, and the other way round; every failure is reported.
            var failures: [String] = []
            do {
                if try await removeMCP(target, cli: cli) { editedDirectly = true }
            } catch {
                failures.append(error.localizedDescription)
            }
            do {
                try removeHook(target)
            } catch {
                failures.append(error.localizedDescription)
            }
            if failures.isEmpty {
                lines.append("Removed from \(target.label)")
            } else {
                ok = false
                lines.append("Could not fully remove from \(target.label): \(failures.joined(separator: " "))")
            }
        }
        if editedDirectly { lines.append(Self.restartLine) }
        return (lines, ok)
    }

    static func firstLine(_ text: String) -> String? {
        text.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    public enum SetupError: LocalizedError {
        case failed(String)
        public var errorDescription: String? {
            switch self { case .failed(let message): message }
        }
    }
}
