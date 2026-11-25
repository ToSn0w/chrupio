import AppKit
import ChrupioCore
import SwiftUI

/// Renders the app's screens to PNGs from a demo library and quits. Used to review the UI without a display session:
/// `CHRUPIO_SNAPSHOT_DIR=<dir> CHRUPIO_MEETINGS_DIR=<demo meetings> CHRUPIO_SUPPORT_DIR=<temp> CHRUPIO_SESSIONS_DIR=<temp>
/// CHRUPIO_SKIP_MIGRATION=1 .build/debug/Chrupio` (a bare binary, so its defaults are not the installed app's).
/// Nothing shown is read from the real home or saved preferences: see `UserHome` and `AppSettings.snapshotDomain`.
@MainActor
enum DebugSnapshot {
    nonisolated static var directory: URL? {
        ProcessInfo.processInfo.environment["CHRUPIO_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Quits a snapshot run that could touch the real library, support folder, Claude sessions or the installed app's settings.
    nonisolated static func refuseUnsafeRun() {
        guard directory != nil else { return }
        let environment = ProcessInfo.processInfo.environment
        // Resolved and case-insensitive, as APFS is by default: a symlink or "chrupio" must not reach the real folder.
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppPaths.folderName).resolvingSymlinksInPath().path.lowercased()
        for key in ["CHRUPIO_MEETINGS_DIR", "CHRUPIO_SUPPORT_DIR", "CHRUPIO_SESSIONS_DIR"] {
            guard let path = environment[key], !path.isEmpty,
                  !URL(fileURLWithPath: path).resolvingSymlinksInPath().path.lowercased().hasPrefix(real) else {
                FileHandle.standardError.write(Data("Snapshot refused: set \(key) to a temporary folder.\n".utf8))
                exit(2)
            }
        }
        if Bundle.main.bundleIdentifier != nil {
            FileHandle.standardError.write(Data("Snapshot refused: run the bare binary, not an app bundle.\n".utf8))
            exit(2)
        }
    }

    static func run(into directory: URL) async {
        // Everything shown comes from a fake home (UserHome.url, a new temporary folder): demo Chrome profiles that all
        // load the extension, no Desktop copy, the notes folder, and the Claude config homes. Settings start from an
        // empty defaults domain of their own (AppSettings.snapshotDomain).
        let home = UserHome.url
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writeChromeProfiles(home: home)
        let demoNotes = MeetingExporter.defaultFolder
        try? FileManager.default.createDirectory(at: demoNotes, withIntermediateDirectories: true)
        let coordinator = MeetingCoordinator.shared
        // The coordinator is not started (no detection or server); the demo library is loaded here.
        coordinator.meetings = MeetingStore().loadAll().sorted { $0.startedAt > $1.startedAt }
        let settings = AppSettings.shared
        settings.hasCompletedOnboarding = true
        settings.exportFolderPath = demoNotes.path
        settings.selfNames = SelfNames.usual(in: coordinator.meetings) ?? ""
        for window in NSApp.windows where window.isVisible { window.orderOut(nil) }
        // One connected status for every screen, read from the fake homes (see ClaudeCodeIntegration.snapshotHome).
        let integration = ClaudeCodeIntegration()
        integration.refresh(force: true)
        try? await Task.sleep(for: .seconds(1))

        let sample = coordinator.meetings.first(where: MeetingExporter.isExportable)
        MainWindowSelection.shared.meetingID = sample?.id
        await snap(MainWindow().environment(coordinator), name: "app-main", width: 1240, height: 760, titled: true, wait: 3,
                   into: directory)
        if let sample {
            await snap(MeetingDetailView(meeting: sample, tab: .transcript).environment(coordinator).environment(integration),
                       name: "app-meeting", width: 1000, height: 1300, wait: 2, into: directory)
        }
        await snap(MenuBarView().environment(coordinator), name: "app-menu-idle", width: 360, into: directory)
        if var live = sample {
            live.status = .recording
            live.startedAt = Date().addingTimeInterval(-(23 * 60 + 47))
            live.endedAt = nil
            await snap(MenuBarView(previewRecording: live).environment(coordinator), name: "app-menu-recording", width: 360,
                       into: directory)
        }
        await snap(SettingsView().environment(coordinator), name: "app-settings", width: 720, titled: true, wait: 2, into: directory)
        // Every tab at full height, the way the window shows it on a tall screen.
        for tab in SettingsView.Tab.allCases {
            let slug = tab.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
            await snap(SettingsView(tab: tab).environment(\.settingsPageHeight, 2000).environment(coordinator),
                       name: "settings-d1-\(slug)", width: 720, titled: true, wait: 2, into: directory)
        }
        await snap(ClaudeCodeSettings().frame(width: 680).environment(coordinator), name: "app-settings-claude-code", width: 680,
                   wait: 2, into: directory)
        await snap(OnboardingView(), name: "app-onboarding", width: 680, wait: 2, into: directory)
        // The other Claude Code states, each from its own fake home (an empty one: never connected).
        let emptyHome = FileManager.default.temporaryDirectory.appendingPathComponent("chrupio-snapshot-claude-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        if let full = ClaudeCodeIntegration.snapshotHome {
            // A height shows the whole page, buttons included, where the app's 560 pt page would cut it off.
            let scenes: [(String, ClaudeCodeIntegration.Snapshot, CGFloat?)] = [
                ("not-connected", .init(home: emptyHome), nil),
                ("switches-off", .init(home: emptyHome, components: ClaudeCodeSetup.Components.none), nil),
                ("outside-applications", .init(home: emptyHome, outsideApplications: true), nil),
                ("hooks-switched-off-but-installed", .init(home: full, components: .defaults), 740),
                ("cli-missing", .init(home: full, cliInstalled: false, components: .defaults), 700),
            ]
            for (name, scene, height) in scenes {
                let sceneIntegration = ClaudeCodeIntegration(snapshot: scene)
                sceneIntegration.refresh(force: true)
                await snap(ClaudeCodeSettings(integration: sceneIntegration).frame(width: 680)
                            .environment(\.settingsPageHeight, height ?? 560).environment(coordinator),
                           name: "app-settings-claude-code-\(name)", width: 680, wait: 1, into: directory)
                if name == "not-connected" || name == "switches-off" || name == "outside-applications" {
                    await snap(OnboardingView(integration: sceneIntegration), name: "app-onboarding-\(name)", width: 680, wait: 1,
                               into: directory)
                }
            }
        }
        try? FileManager.default.removeItem(at: emptyHome)
        await snap(MenuBarView().environment(coordinator), name: "app-dark-check", width: 360, dark: true, into: directory)
        await snap(GlyphPreview(), name: "app-menubar-glyph", width: 360, into: directory)

        UserDefaults.standard.removePersistentDomain(forName: AppSettings.snapshotDomain)
        try? FileManager.default.removeItem(at: home)
        exit(0)
    }

    /// Hosts a view in a window and renders it; without a height the window takes the view's fitting size.
    /// `titled` windows get a title bar, so toolbars and native tabs render.
    private static func snap(_ view: some View, name: String, width: CGFloat, height: CGFloat? = nil, titled: Bool = false,
                             wait: Double = 1, dark: Bool = false, into directory: URL) async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height ?? 600),
                              styleMask: titled ? [.titled, .fullSizeContentView] : [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: view.frame(width: width, height: height))
        if height == nil { window.setContentSize(window.contentView!.fittingSize) }
        // Key and active, as in the real app, so the sidebar selection can draw in its active colour. AppKit may still
        // draw the inactive grey when the snapshot process is not frontmost.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(wait))
        render(window, name: name, into: directory)
        window.orderOut(nil)
    }

    /// Writes two connected Claude Code homes (the default one and `~/.claude-team`) into the fake home.
    static func makeClaudeHomes(serverBinary: URL) -> URL? {
        let fileManager = FileManager.default
        let home = UserHome.url
        let setup = ClaudeCodeSetup(serverBinary: serverBinary, home: home, environment: [:])
        let server: [String: Any] = ["mcpServers": [ClaudeCodeSetup.serverName: ["type": "stdio", "command": serverBinary.path, "args": []]]]
        var hooks: [String: Any] = [:]
        for hook in ClaudeCodeSetup.hooks {
            hooks[hook.event] = [["hooks": [["type": "command", "command": setup.command(for: hook), "timeout": hook.timeout]]]]
        }
        let settings: [String: Any] = ["hooks": hooks]
        let files: [(String, [String: Any])] = [
            (".claude.json", server), (".claude/settings.json", settings),
            (".claude-team/.claude.json", server), (".claude-team/settings.json", settings),
        ]
        do {
            for (path, json) in files {
                let url = home.appendingPathComponent(path)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]).write(to: url)
            }
            return home
        } catch {
            return nil
        }
    }

    /// Demo Chrome profiles in the fake home, each loading the extension from Chrupio's folder, so the Meetings tab
    /// lists no profile without it.
    private static func writeChromeProfiles(home: URL) {
        let chrome = ExtensionPackage.chromeFolder(home: home)
        let extensionPath = home.appendingPathComponent("Library/Application Support/\(AppPaths.folderName)/\(ExtensionPackage.folderName)").path
        let profiles = ["Default": "Work", "Profile 1": "Personal"]
        let state: [String: Any] = ["profile": ["info_cache": profiles.mapValues { ["name": $0] }]]
        let preferences: [String: Any] = ["extensions": ["settings": ["chrupiodemo": ["path": extensionPath, "state": 1, "disable_reasons": []]]]]
        do {
            try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: state).write(to: chrome.appendingPathComponent("Local State"))
            for folder in profiles.keys {
                let profile = chrome.appendingPathComponent(folder, isDirectory: true)
                try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: preferences).write(to: profile.appendingPathComponent("Secure Preferences"))
            }
        } catch {
            FileHandle.standardError.write(Data("Snapshot: demo Chrome profiles not written: \(error.localizedDescription)\n".utf8))
        }
    }

    private static func render(_ window: NSWindow, name: String, into directory: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = directory.appendingPathComponent(name.isEmpty ? "window" : name).appendingPathExtension("png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// The menu-bar mark at real size on light and dark bars, and zoomed. Debug preview only, not part of the app's UI.
private struct GlyphPreview: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                bar(background: Color(hex: 0xECECEC), foreground: Theme.ink)
                bar(background: Color(hex: 0x2A2A2A), foreground: Theme.surface)
            }
            Image(nsImage: MenuBarGlyph.image).renderingMode(.template).resizable().frame(width: 128, height: 128).foregroundStyle(Theme.ink)
        }
        .padding(16)
        .background(Theme.surface)
    }

    private func bar(background: Color, foreground: Color) -> some View {
        Image(nsImage: MenuBarGlyph.image).renderingMode(.template).foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 24).background(background)
    }
}

/// Records a real meeting for `CHRUPIO_SELFTEST_SECONDS` while macOS speech plays, waits for notes, prints them and quits.
/// Exercises the whole app pipeline (capture, chunking, whisper, attribution, summary) without a person at the Mac.
@MainActor
enum SelfTest {
    static var seconds: Double? {
        ProcessInfo.processInfo.environment["CHRUPIO_SELFTEST_SECONDS"].flatMap(Double.init)
    }

    static func run(seconds: Double) async {
        let coordinator = MeetingCoordinator.shared
        let began = Date()
        func mark(_ step: String) { print(String(format: "SELFTEST %.1fs %@", Date().timeIntervalSince(began), step)) }
        coordinator.startManualRecording()
        mark("recording started")
        guard let id = coordinator.recording?.meetingID else {
            print("SELFTEST FAIL: recording did not start: \(coordinator.lastError ?? "unknown")")
            exit(1)
        }
        let speech = Process()
        speech.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        speech.arguments = ["Hello team. We agreed to launch the billing page on Friday. Priya will write the release notes by Thursday. Tom fixes the rounding bug."]
        try? speech.run()
        try? await Task.sleep(for: .seconds(seconds))
        mark("stopping")
        coordinator.stopRecording()
        mark("stopped")

        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(2))
            guard let meeting = coordinator.meetings.first(where: { $0.id == id }) else {
                print("SELFTEST: meeting discarded (shorter than the minimum length)")
                exit(1)
            }
            if (meeting.status == .done || meeting.status == .failed), !coordinator.summarizing.contains(id) {
                mark("finished")
                print("SELFTEST status=\(meeting.status.rawValue) error=\(meeting.error ?? "none")")
                print("SELFTEST transcript:\n\(TranscriptFormatter.plainText(meeting.segments))")
                print("SELFTEST summary:\n\(meeting.summary?.markdown ?? "none")")
                exit(meeting.segments.isEmpty ? 1 : 0)
            }
        }
        print("SELFTEST FAIL: timed out")
        exit(1)
    }
}
