import Foundation
import Observation
import ChrupioCore

/// Connects the bundled `chrupio-mcp` to Claude Code in every Claude config home (see ClaudeCodeSetup).
@MainActor
@Observable
final class ClaudeCodeIntegration {
    enum State: Equatable {
        case checking
        case cliMissing
        case notConnected
        /// Registered in some configs, for a different copy of the app, or with OpenKrisp leftovers.
        case partial
        case connected
    }

    private(set) var state: State = .checking
    private(set) var details: [ClaudeCodeSetup.Status] = []
    /// What an earlier Connect left in the files; nil when nothing. Drives Disconnect when Claude Code is missing.
    private(set) var installed: ClaudeCodeSetup.Components?
    private(set) var isWorking = false
    private(set) var message: String?
    private var cli: URL?
    private var refreshedAt: Date?
    private static let refreshInterval: TimeInterval = 2

    /// The MCP binary that ships next to the app's executable.
    static var serverBinary: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent().appendingPathComponent("chrupio-mcp")
    }

    /// Debug snapshots only: fake Claude config homes in a temporary folder, so a snapshot never reads ~/.claude*
    /// and never looks for or runs the `claude` CLI. Nil in the app.
    static let snapshotHome: URL? = DebugSnapshot.directory == nil ? nil : DebugSnapshot.makeClaudeHomes(serverBinary: serverBinary)

    /// Debug snapshots only: what one screen shows. Snapshots never connect, disconnect or store anything.
    struct Snapshot {
        var home: URL
        var cliInstalled = true
        /// The switches; nil shows what the fake homes hold.
        var components: ClaudeCodeSetup.Components?
        var outsideApplications = false
    }

    private let snapshot: Snapshot?

    /// Debug snapshots only: whether the faked Claude Code is installed, so onboarding's step 6 matches step 7. Nil in the app.
    var snapshotCLIInstalled: Bool? { snapshot?.cliInstalled }

    init(snapshot: Snapshot? = ClaudeCodeIntegration.snapshotHome.map { Snapshot(home: $0) }) {
        self.snapshot = snapshot
    }

    private var setup: ClaudeCodeSetup {
        if let snapshot { return ClaudeCodeSetup(serverBinary: Self.serverBinary, home: snapshot.home, environment: [:]) }
        let settings = AppSettings.shared
        return ClaudeCodeSetup(serverBinary: Self.serverBinary, extraConfigDir: settings.claudeConfigDir,
                               knownConfigDirs: settings.claudeCodeHomes)
    }

    /// The switches in Settings: the stored choice, or the defaults for a first Connect.
    var components: ClaudeCodeSetup.Components {
        if let snapshot { return snapshot.components ?? installed ?? .defaults }
        return AppSettings.shared.claudeCodeComponents ?? .defaults
    }

    /// Connect is refused: the app isn't in /Applications or ~/Applications. Judged by the binary Claude Code would run,
    /// as `connect()` is.
    var locationRefusal: String? {
        if let snapshot { return snapshot.outsideApplications ? InstallLocation.message : nil }
        return InstallLocation.refusal(serverBinary: Self.serverBinary)
    }

    /// The config file as Settings shows it, with the home folder as `~`.
    func label(for target: ClaudeCodeSetup.Target) -> String {
        let path = target.mcpConfigFile.path, home = setup.home.path + "/"
        return path.hasPrefix(home) ? "~/" + path.dropFirst(home.count) : path
    }

    /// Re-reads the status; calls within `refreshInterval` of the last one are skipped (popover opens, window focus)
    /// unless `force` (onboarding just saw Claude Code appear).
    func refresh(force: Bool = false) {
        let now = Date()
        if !force, let refreshedAt, now.timeIntervalSince(refreshedAt) < Self.refreshInterval { return }
        refreshedAt = now
        Task {
            await lookUpCLI(force: false)
            update()
        }
    }

    /// Snapshots fake the CLI; otherwise the shared lookup (known paths, then the login shell at most once a minute
    /// unless `force`).
    private func lookUpCLI(force: Bool) async {
        if let snapshot {
            // Never run: snapshots don't connect or disconnect. It only marks Claude Code as installed.
            cli = snapshot.cliInstalled ? URL(fileURLWithPath: "/nonexistent/claude") : nil
            return
        }
        cli = await ClaudeCLIStore.shared.locate(force: force)
    }

    private func update() {
        let setup = setup
        details = setup.status()
        installed = setup.installedComponents()
        // First launch of this version: keep what an earlier Connect installed (never remove hooks silently).
        let settings = AppSettings.shared
        if snapshot == nil, settings.claudeCodeComponents == nil,
           let migrated = ClaudeCodeSetup.migrated(stored: nil, installed: installed) {
            settings.claudeCodeComponents = migrated
        }
        // OpenKrisp leftovers count as partial, so the user is asked to Connect, which replaces them. A connection
        // from outside Applications breaks when the app moves, so it isn't "Connected" either.
        state = switch ClaudeCodeSetup.connection(details, binary: Self.serverBinary.path, components: components) {
        case .connected where locationRefusal == nil: .connected
        case _ where cli == nil: .cliMissing
        case .notConnected: .notConnected
        case .connected, .partial: .partial
        }
    }

    func connect() {
        guard !isWorking, snapshot == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: Self.serverBinary.path) else {
            message = "This copy of Chrupio has no chrupio-mcp binary. Reinstall with scripts/install.sh."
            update()
            return
        }
        // Claude Code stores this binary's path.
        if let refusal = locationRefusal {
            message = refusal
            update()
            return
        }
        let components = components
        guard !components.isEmpty else { return disconnect() }
        run(recordOnSuccess: components, done: "Done. Start a new Claude Code session (or run /mcp) to use it.") { setup, cli in
            await setup.connect(cli: cli, components: components)
        }
    }

    /// Removes everything Chrupio set up. The switches stay stored, so a later Connect restores them.
    func disconnect() {
        guard !isWorking, snapshot == nil else { return }
        run(done: "Disconnected.") { setup, cli in await setup.disconnect(cli: cli) }
    }

    /// A switch changed. Connected or partly connected: applied now (all off disconnects). Otherwise stored, and a hook
    /// switched off is still removed: that needs neither Claude Code nor the install location. Turning on waits for Connect.
    func set(_ components: ClaudeCodeSetup.Components) {
        guard snapshot == nil else { return }
        AppSettings.shared.claudeCodeComponents = components
        guard !isWorking else { return update() }
        if state == .connected || state == .partial, locationRefusal == nil {
            return components.isEmpty ? disconnect() : connect()
        }
        if let installed, (installed.digest && !components.digest) || (installed.prompt && !components.prompt) {
            let outcome = setup.removeHooksSwitchedOff(components)
            if let line = outcome.line { message = line }
        }
        update()
    }

    /// The `.cliMissing` state's button: looks for `claude` again right away, and rechecks its login and flags.
    func checkAgain() {
        guard snapshot == nil else { return }
        Task {
            await lookUpCLI(force: true)
            ClaudeCLIStore.shared.refreshReadiness(force: true)
            update()
        }
    }

    /// On success: `done`, then any warnings and the restart line (an edit Claude Code didn't make). `recordOnSuccess`
    /// stores the switches Connect applied and the config dirs it wrote to.
    private func run(recordOnSuccess: ClaudeCodeSetup.Components? = nil, done: String,
                     _ action: @escaping @Sendable (ClaudeCodeSetup, URL?) async -> (lines: [String], ok: Bool)) {
        isWorking = true
        message = nil
        let setup = setup
        Task {
            await lookUpCLI(force: true)
            let outcome = await action(setup, cli)
            if outcome.ok, let recorded = recordOnSuccess {
                let settings = AppSettings.shared
                settings.claudeCodeComponents = recorded
                let dirs = setup.targets().compactMap { $0.configDir?.path }
                settings.claudeCodeHomes = Array(Set(settings.claudeCodeHomes + dirs)).sorted()
            }
            let notes = outcome.lines.filter { $0.hasPrefix("Warning:") || $0 == ClaudeCodeSetup.restartLine }
            message = outcome.ok ? ([done] + notes).joined(separator: "\n") : outcome.lines.joined(separator: "\n")
            isWorking = false
            update()
        }
    }

    /// Links the notes folder into a project folder as `meetings/`.
    func link(project: URL, notes: URL) {
        do {
            message = try ProjectLink.link(project: project, notes: notes)
        } catch {
            message = error.localizedDescription
        }
    }
}

extension ClaudeCodeIntegration.State {
    /// The words Settings shows for each state; nil while checking (callers show a spinner).
    var label: String? {
        switch self {
        case .checking: nil
        case .cliMissing: "Claude Code not found"
        case .notConnected: "Not connected"
        case .partial: "Partly connected"
        case .connected: "Connected"
        }
    }
}
