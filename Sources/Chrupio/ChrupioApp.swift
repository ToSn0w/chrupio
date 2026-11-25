import AppKit
import ChrupioAudio
import ChrupioCore
import SwiftUI

@main
struct ChrupioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Runs before `MeetingCoordinator.shared` is created, because its property initializers read `AppSettings`.
    /// An OpenKrisp install keeps its data folder and its Settings.
    private static let preferencesMigrated: Void = {
        DebugSnapshot.refuseUnsafeRun()
        // Test, demo and snapshot runs never read or copy another app's preferences.
        if case .skippedByEnvironment = LegacyMigration.migrateIfNeeded() { return }
        LegacyMigration.copyPreferences(to: Bundle.main.bundleIdentifier ?? "com.chrupio.app")
    }()
    @State private var coordinator: MeetingCoordinator = { _ = ChrupioApp.preferencesMigrated; return MeetingCoordinator.shared }()

    init() {
        if CommandLine.arguments.contains(ParakeetDownloadCommand.flag) { ParakeetDownloadCommand.run() }
        if CommandLine.arguments.contains(CompressChunkCommand.flag) { CompressChunkCommand.run() }
        // v5 is light only, and its type must exist before the first view renders.
        Theme.registerFonts()
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(coordinator)
        } label: {
            if coordinator.hasLostTrack {
                Image(nsImage: Self.lostTrackIcon)
            } else if coordinator.recording == nil {
                Image(nsImage: MenuBarGlyph.image)
            } else {
                Image(systemName: "record.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Theme.Color.error)
            }
        }
        .menuBarExtraStyle(.window)

        Window("Chrupio", id: "main") {
            MainWindow()
                .environment(coordinator)
                .frame(minWidth: 980, minHeight: 560)
        }
        .defaultSize(width: 1240, height: 760)
        // A menu-bar app: show the window at launch only until setup is done.
        .defaultLaunchBehavior(AppSettings.shared.hasCompletedOnboarding ? .suppressed : .presented)

        Settings {
            SettingsView()
                .environment(coordinator)
        }
        .windowResizability(.contentSize)
        // The standard place, for when the app menu is showing; the menu bar panel has the same item.
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                    .disabled(!Updater.shared.canCheckForUpdates)
            }
        }
    }

    /// Shown while the mic or call audio is lost. Not a template image, so the menu bar keeps it red
    /// instead of tinting it to match the other icons; this is the warning that works with notifications off.
    private static let lostTrackIcon: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Audio lost")?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return image
    }()
}

/// `Chrupio --download-parakeet` downloads the Parakeet models and exits without starting the app.
/// For manual use: the app otherwise fetches them the first time a Polish call needs them.
enum ParakeetDownloadCommand {
    static let flag = "--download-parakeet"

    static func run() -> Never {
        Task.detached {
            do {
                try await ParakeetTranscriber.downloadModels()
                try await ParakeetTranscriber.downloadVocabularyModel()
                print("Parakeet models are in \(ParakeetTranscriber.modelsDirectory.path)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Couldn't download the Parakeet models: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }
}

/// `Chrupio --compress-chunk <wav>` compresses one chunk and exits. Audio retention runs it as a child process it can
/// kill: Core Audio's Opus decoder hangs forever on some chunks, and in the app that froze recording for hours.
enum CompressChunkCommand {
    static let flag = "--compress-chunk"
    static let timeout: TimeInterval = 120

    static func run() -> Never {
        guard let index = CommandLine.arguments.firstIndex(of: flag), index + 1 < CommandLine.arguments.count else { exit(2) }
        let wav = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        // <root>/<meeting>/audio/<chunk>.wav
        let store = MeetingStore(root: wav.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        do {
            _ = try store.compressChunk(wav)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would record the same meeting twice and fight over the extension port.
        if let bundleID = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { $0 != .current }) {
            other.activate()
            exit(0)
        }
        NSApp.setActivationPolicy(.accessory)
        MainThreadWatchdog.shared.start()
        Task { @MainActor in
            // Snapshots only render: no detection, extension server, model downloads or notifications.
            if let directory = DebugSnapshot.directory {
                await DebugSnapshot.run(into: directory)
                return
            }
            MeetingCoordinator.shared.start()
            Updater.shared.start()
            Notifier.requestAuthorization()
            if SelfTest.seconds == nil { ChromeExtensionInstaller.installAtLaunch() }
            if let seconds = SelfTest.seconds { await SelfTest.run(seconds: seconds) }
        }
    }

    /// How long quitting waits for the last chunks and queued saves before giving up on them.
    static let quitTimeout: Duration = .seconds(10)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Whichever comes first, the flush or the timeout, quits; a stop stuck in Core Audio can't hold the app open.
        var replied = false
        @MainActor func reply() {
            guard !replied else { return }
            replied = true
            // Unfinished chunks stay on disk and are transcribed on the next launch.
            ProcessRunner.terminateAll()
            LocalAPI.clearOwnEndpoint()
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await MeetingCoordinator.shared.prepareForQuit()
            reply()
        }
        Task { @MainActor in
            try? await Task.sleep(for: Self.quitTimeout)
            reply()
        }
        return .terminateLater
    }
}
