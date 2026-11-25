import Foundation
import os

/// Carries an OpenKrisp install over to Chrupio: the data folder and the preferences, each once.
/// Nothing here runs on its own: the app and `chrupio-mcp` call `migrateIfNeeded()` at start, and nothing is ever deleted.
public enum LegacyMigration {
    public static let legacyFolderName = "OpenKrisp"
    public static let legacyDefaultsDomain = "dev.openkrisp.app"
    /// Environment variables that mark a test, demo or dev run, which must never move the real library.
    static let skipEnvironment = ["CHRUPIO_SKIP_MIGRATION", "CHRUPIO_MEETINGS_DIR", "CHRUPIO_SNAPSHOT_DIR", "CHRUPIO_SUPPORT_DIR",
                                  "CHRUPIO_SELFTEST_SECONDS"]
    private static let log = Logger(subsystem: "com.chrupio.app", category: "migration")

    public enum Outcome: Equatable {
        case moved
        /// The early Chrupio folder was renamed to `asideName` before the move.
        case movedSettingAside(asideName: String)
        case noLegacyFolder
        case skippedNewHoldsMeetings
        case skippedUnderTests
        case skippedByEnvironment(String)
        case failed(String)
    }

    /// The only entry point that touches the real Application Support folder. Call it at process start, before
    /// anything reads `AppPaths`.
    @discardableResult
    public static func migrateIfNeeded() -> Outcome {
        if NSClassFromString("XCTestCase") != nil { return .skippedUnderTests }
        let environment = ProcessInfo.processInfo.environment
        if let name = skipEnvironment.first(where: { environment[$0] != nil }) { return .skippedByEnvironment(name) }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            log.error("Folder migration failed: no Application Support directory")
            return .failed("no Application Support directory")
        }
        let outcome = moveSupportFolder(base: base)
        switch outcome {
        case .moved:
            log.notice("Moved \(legacyFolderName, privacy: .public) to \(AppPaths.folderName, privacy: .public)")
        case .movedSettingAside(let aside):
            log.notice("Set the early \(AppPaths.folderName, privacy: .public) folder aside as \(aside, privacy: .public) and moved \(legacyFolderName, privacy: .public) in its place")
        case .noLegacyFolder:
            log.info("Folder migration skipped: no \(legacyFolderName, privacy: .public) folder")
        case .skippedNewHoldsMeetings:
            log.notice("Folder migration skipped: \(AppPaths.folderName, privacy: .public) already holds meetings")
        case .skippedUnderTests, .skippedByEnvironment:
            break
        case .failed(let error):
            log.error("Folder migration failed: \(error, privacy: .public)")
        }
        return outcome
    }

    /// Moves `<base>/OpenKrisp` to `<base>/Chrupio`.
    /// - Old missing: nothing happens.
    /// - New missing: old is moved to new.
    /// - New holds no meetings (no subdirectory of `new/meetings`): new is renamed to
    ///   `Chrupio.pre-migration-<yyyyMMdd-HHmmss>`, then old is moved to new. If that move fails, the aside is renamed back.
    /// - New holds meetings: nothing happens.
    /// Nothing is ever removed.
    public static func moveSupportFolder(base: URL, fileManager: FileManager = .default, now: Date = Date()) -> Outcome {
        let old = base.appendingPathComponent(legacyFolderName, isDirectory: true)
        let new = base.appendingPathComponent(AppPaths.folderName, isDirectory: true)
        guard fileManager.fileExists(atPath: old.path) else { return .noLegacyFolder }
        guard fileManager.fileExists(atPath: new.path) else {
            do {
                try fileManager.moveItem(at: old, to: new)
                return .moved
            } catch {
                return .failed("move \(legacyFolderName) to \(AppPaths.folderName): \(error.localizedDescription)")
            }
        }
        if holdsMeetings(new, fileManager: fileManager) { return .skippedNewHoldsMeetings }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let asideName = "\(AppPaths.folderName).pre-migration-\(formatter.string(from: now))"
        let aside = base.appendingPathComponent(asideName, isDirectory: true)
        guard !fileManager.fileExists(atPath: aside.path) else { return .failed("\(asideName) already exists") }
        do {
            try fileManager.moveItem(at: new, to: aside)
        } catch {
            return .failed("set \(AppPaths.folderName) aside as \(asideName): \(error.localizedDescription)")
        }
        do {
            try fileManager.moveItem(at: old, to: new)
            return .movedSettingAside(asideName: asideName)
        } catch {
            let moveError = error.localizedDescription
            if (try? fileManager.moveItem(at: aside, to: new)) == nil {
                return .failed("move \(legacyFolderName) to \(AppPaths.folderName): \(moveError); the early folder stays at \(asideName)")
            }
            return .failed("move \(legacyFolderName) to \(AppPaths.folderName): \(moveError)")
        }
    }

    /// A meeting is a directory inside `meetings`; files there, such as `index.json`, are not.
    static func holdsMeetings(_ folder: URL, fileManager: FileManager) -> Bool {
        let meetings = folder.appendingPathComponent("meetings", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(at: meetings, includingPropertiesForKeys: [.isDirectoryKey]) else {
            // Unreadable but present: treat as holding meetings, so nothing moves.
            return fileManager.fileExists(atPath: meetings.path)
        }
        return entries.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    /// Copies every key of `old` into `new` when `new` has none. Returns how many keys were copied.
    @discardableResult
    public static func copyPreferences(from old: String = legacyDefaultsDomain, to new: String) -> Int {
        let defaults = UserDefaults.standard
        guard (defaults.persistentDomain(forName: new) ?? [:]).isEmpty,
              let values = defaults.persistentDomain(forName: old), !values.isEmpty else { return 0 }
        defaults.setPersistentDomain(values, forName: new)
        return values.count
    }
}
