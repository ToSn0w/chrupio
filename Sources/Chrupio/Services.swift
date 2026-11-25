import AppKit
@preconcurrency import AVFoundation
import Foundation
import Observation
import ChrupioCore
import ServiceManagement
import os
import UserNotifications

private let notifierLog = Logger(subsystem: "Chrupio", category: "notifications")

enum Notifier {
    /// Asks only while undecided: once the user (or macOS) has answered, asking again fails with
    /// "Notifications are not allowed" on every launch and never shows the prompt.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else {
                notifierLog.info("notification authorization: \(settings.authorizationStatus.rawValue, privacy: .public), alerts: \(settings.alertSetting.rawValue, privacy: .public)")
                return
            }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error { notifierLog.error("notification authorization failed: \(error.localizedDescription, privacy: .public)") }
                else { notifierLog.info("notification authorization granted: \(granted, privacy: .public)") }
            }
        }
    }

    /// True when the user turned Chrupio's notifications off in System Settings.
    static func isDenied() async -> Bool {
        // UNUserNotificationCenter throws in a bare binary (debug snapshots), which has no bundle.
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.chrupio.app"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// - Parameter identifier: lets a later `remove` take the notification back; a fresh one by default.
    static func post(title: String, body: String, enabled: Bool, identifier: String = UUID().uuidString) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { notifierLog.error("couldn't post \"\(title)\": \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Takes back a notification that no longer applies.
    static func remove(identifier: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}

/// `Notifier` for the Core schedulers: ordinary notifications follow the Notifications setting.
@MainActor
final class AppNotifier: MeetingNotifying {
    func post(title: String, body: String, important: Bool, identifier: String?) {
        Notifier.post(title: title, body: body, enabled: important || AppSettings.shared.notify, identifier: identifier ?? UUID().uuidString)
    }

    func remove(identifier: String) { Notifier.remove(identifier: identifier) }
}

enum Permissions {
    /// A snapshot shows every permission granted rather than this Mac's state.
    static var microphoneStatus: AVAuthorizationStatus {
        DebugSnapshot.directory != nil ? .authorized : AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var accessibilityTrusted: Bool { DebugSnapshot.directory != nil || ZoomMonitor.isAccessibilityTrusted }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    static var launchesAtLogin: Bool {
        DebugSnapshot.directory != nil || [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    }

    /// Returns a message when the user still has to act in System Settings.
    @discardableResult
    static func setLaunchAtLogin(_ enabled: Bool) throws -> String? {
        guard enabled else {
            try SMAppService.mainApp.unregister()
            return nil
        }
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/") else {
            throw LoginItemError.notInApplications
        }
        try SMAppService.mainApp.register()
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return "Turn on Chrupio in System Settings > General > Login Items."
        }
        return nil
    }

    enum LoginItemError: LocalizedError {
        case notInApplications
        var errorDescription: String? { "Move Chrupio to the Applications folder first." }
    }
}

/// Keeps an unpacked copy of the bundled Chrome extension in Application Support for chrome://extensions > Load unpacked.
enum ChromeExtensionInstaller {
    static var installedURL: URL { ExtensionPackage.installedFolder(support: AppPaths.support) }

    static var bundledURL: URL? { Bundle.main.url(forResource: "ChromeExtension", withExtension: nil) }

    static var bundledVersion: String? { bundledURL.flatMap(ExtensionPackage.version(in:)) }

    /// An old copy on the Desktop exists: the user should load `installedURL` in Chrome instead. It is never deleted.
    static var hasLegacyDesktopCopy: Bool { ExtensionPackage.hasLegacyDesktopCopy() }

    /// The folder as Settings and onboarding show it. A snapshot's support folder is temporary, so it shows where the
    /// app keeps it.
    static var displayPath: String {
        DebugSnapshot.directory != nil ? "~/Library/Application Support/\(AppPaths.folderName)/\(ExtensionPackage.folderName)"
            : installedURL.path
    }

    @discardableResult
    static func install() throws -> URL {
        guard let source = bundledURL else { throw CocoaError(.fileNoSuchFile) }
        return try ExtensionPackage.install(from: source, support: AppPaths.support)
    }

    /// At launch, writes the folder for a fresh user and brings it up to date after an app update; Chrome loads it on its
    /// next reload. Runs off the main thread.
    static func installAtLaunch() {
        guard let source = bundledURL else { return }
        let support = AppPaths.support
        Task.detached(priority: .utility) { _ = try? ExtensionPackage.installIfNeeded(from: source, support: support) }
    }

    /// True when a Chrome profile still loads the old Desktop copy, or that copy exists.
    static var movedFolderNotice: String? {
        ExtensionLoadGuide.movedFolderNotice(profileLoadsLegacy: ExtensionPackage.anyProfileLoadsLegacyCopy(),
                                             legacyExists: hasLegacyDesktopCopy)
    }

    /// Makes sure the folder exists, then puts its path on the pasteboard for Cmd+Shift+G in Chrome's picker.
    static func copyFolderPath() throws {
        let url = try install()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    static func showInFinder() throws {
        NSWorkspace.shared.activateFileViewerSelecting([try install()])
    }

    /// Opens chrome://extensions in Chrome. Copies the folder first so it is ready to load.
    static func openExtensionsPage() throws {
        try install()
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
           let extensions = URL(string: "chrome://extensions") {
            NSWorkspace.shared.open([extensions], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Downloads whisper models into Application Support with progress.
@MainActor
@Observable
final class ModelDownloader: NSObject {
    static let shared = ModelDownloader()

    private(set) var progress: [String: Double] = [:]
    private(set) var errors: [String: String] = [:]
    /// Bytes received and expected, per model name; total is -1 when the server sends no length.
    private(set) var bytes: [String: (completed: Int64, total: Int64)] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var observations: [String: NSKeyValueObservation] = [:]

    func isDownloading(_ model: WhisperModel) -> Bool { tasks[model.name] != nil }

    func download(_ model: WhisperModel) {
        guard tasks[model.name] == nil else { return }
        errors[model.name] = nil
        progress[model.name] = 0
        bytes[model.name] = nil
        let name = model.name
        let destination = model.localURL
        let pin = model.pin
        let task = URLSession.shared.downloadTask(with: model.downloadURL) { location, response, error in
            var failure: String?
            if let error = error as? URLError, error.code == .cancelled {
                failure = nil
            } else if let error {
                failure = error.localizedDescription
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                failure = "HTTP \(http.statusCode)"
            } else if let location {
                do {
                    // Still inside the completion handler: the temporary file is valid until it returns.
                    // A wrong size or checksum deletes it and leaves any model already in place alone.
                    try ModelVerifier.install(location, to: destination, pin: pin)
                } catch {
                    failure = error.localizedDescription
                }
            }
            Task { @MainActor in ModelDownloader.shared.finish(name, error: failure) }
        }
        observations[name] = task.progress.observe(\.fractionCompleted) { progress, _ in
            let value = progress.fractionCompleted
            let received = (completed: progress.completedUnitCount, total: progress.totalUnitCount)
            Task { @MainActor in
                ModelDownloader.shared.progress[name] = value
                ModelDownloader.shared.bytes[name] = received
            }
        }
        tasks[name] = task
        task.resume()
    }

    func cancel(_ model: WhisperModel) {
        tasks[model.name]?.cancel()
    }

    private func finish(_ name: String, error: String?) {
        tasks[name] = nil
        observations[name] = nil
        progress[name] = nil
        bytes[name] = nil
        errors[name] = error
    }
}
