import Foundation
import Observation
import ChrupioCore

/// The app's one answer to "where is claude?". Known paths are checked on every call (cheap); the login shell runs
/// in the background at most once a minute while nothing is found, and its answer is cached while the file exists.
@MainActor
@Observable
final class ClaudeCLIStore {
    static let shared = ClaudeCLIStore()

    private(set) var url: URL?
    // Not observed: views call `current()` from `body`, and these change while a lookup starts and ends.
    @ObservationIgnored private var shellCheckedAt: Date?
    @ObservationIgnored private var lookup: Task<URL?, Never>?
    static let retryInterval: TimeInterval = 60

    /// Never blocks. Debug snapshots never look for or run `claude`.
    func current() -> URL? {
        guard DebugSnapshot.directory == nil else { return nil }
        if let known = ClaudeCLI.known() {
            if url != known { url = known }
            return known
        }
        if let url, FileManager.default.isExecutableFile(atPath: url.path) { return url }
        if url != nil { url = nil }
        if lookup == nil, shellCheckedAt.map({ Date().timeIntervalSince($0) >= Self.retryInterval }) ?? true {
            _ = startLookup()
        }
        return nil
    }

    /// Waits for a running lookup; with `force`, starts one even inside the retry interval (Connect, Check again).
    func locate(force: Bool) async -> URL? {
        if let found = current() { return found }
        if let lookup { return await lookup.value }
        guard force, DebugSnapshot.directory == nil else { return nil }
        return await startLookup().value
    }

    /// Login and flag state for the found `claude`; nil until checked. Refreshed at most every 5 seconds while it clearly
    /// says logged out, so onboarding sees a fresh /login quickly, and every 5 minutes otherwise (logged in, or an
    /// answer that can't be read, which polling won't change). A different `claude` or account folder is checked again right away.
    private(set) var readiness: ClaudeReadiness?
    @ObservationIgnored private var readinessCheckedAt: Date?
    @ObservationIgnored private var readinessKey: String?
    @ObservationIgnored private var readinessCheck: Task<Void, Never>?

    func refreshReadiness(force: Bool = false) {
        guard DebugSnapshot.directory == nil, readinessCheck == nil, let executable = current() else { return }
        let configDir = AppSettings.shared.claudeConfigDir
        let key = executable.path + "\n" + configDir
        let interval: TimeInterval = readiness?.login == .notLoggedIn ? 5 : 300
        if !force, key == readinessKey, let readinessCheckedAt, Date().timeIntervalSince(readinessCheckedAt) < interval { return }
        readinessCheck = Task {
            let result = await ClaudeReadiness.live(executable: executable, configDir: configDir)
            if self.readiness != result { self.readiness = result }
            self.readinessKey = key
            self.readinessCheckedAt = Date()
            self.readinessCheck = nil
            // The account folder changed while this ran: check the new one.
            if AppSettings.shared.claudeConfigDir != configDir { self.refreshReadiness() }
        }
    }

    private func startLookup() -> Task<URL?, Never> {
        let task = Task { () -> URL? in
            let found = await ClaudeCLI.locate()
            // A known path that appeared while the shell ran is kept rather than overwritten with nil.
            self.url = found ?? ClaudeCLI.known()
            self.shellCheckedAt = self.url == nil ? Date() : nil
            self.lookup = nil
            return self.url
        }
        lookup = task
        return task
    }
}
