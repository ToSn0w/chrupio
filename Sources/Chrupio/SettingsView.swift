import AVFoundation
import Combine
import ChrupioCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", transcription = "Transcription", summaries = "Summaries", meetings = "Meetings"
        case claudeCode = "Claude Code"
        var id: Self { self }
    }

    @State private var tab: Tab
    @State private var window: NSWindow?

    init(tab: Tab = .general) { _tab = State(initialValue: tab) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsTitleBar()
            SettingsTabStrip(selection: $tab)
                .padding(.horizontal, 30)
                .padding(.top, 20)
            Group {
                switch tab {
                case .general: GeneralSettings()
                case .transcription: TranscriptionSettings()
                case .summaries: SummarySettings()
                case .meetings: IntegrationSettings()
                case .claudeCode: ClaudeCodeSettings()
                }
            }
            .environment(\.settingsPagePadding, 30)
        }
        .frame(width: 720)
        .background(Theme.surface)
        .background(SettingsWindowChrome(window: $window))
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.light)
        // Esc closes, as Cmd+W does.
        .background {
            Button("Close") { window?.performClose(nil) }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

/// The D1 black title bar: three orange squares and the window name, to the right of the system window buttons.
/// The bar drags the window; its height matches the unified title bar so the window buttons sit centred in it.
private struct SettingsTitleBar: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in Rectangle().fill(Theme.accent).frame(width: 14, height: 14) }
            Text("Chrupio Settings")
                .font(Theme.font(14, .bold))
                .textCase(.uppercase)
                .tracking(1.5)
                .foregroundStyle(Theme.surface)
                .padding(.leading, 12)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.leading, 84)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(Theme.ink)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }
}

/// D1 bordered tabs: black borders, bold capitals, the selected tab filled orange. Cmd+1 to Cmd+5 switch tabs.
private struct SettingsTabStrip: View {
    @Binding var selection: SettingsView.Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(SettingsView.Tab.allCases.enumerated()), id: \.element) { index, tab in
                let isOn = tab == selection
                Button { selection = tab } label: {
                    Text(tab.rawValue)
                        .font(Theme.font(12, .bold))
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(isOn ? Theme.accent : Theme.surface)
                        .focusRing(inset: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                if index < SettingsView.Tab.allCases.count - 1 {
                    Rectangle().fill(Theme.ink).frame(width: Theme.Border.regular)
                }
            }
        }
        .fixedSize()
        .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.regular))
    }
}

/// Hides the native title and lets the content run under the title bar; an empty unified toolbar makes the bar
/// as tall as the D1 header so the system window buttons stay centred in it.
private struct SettingsWindowChrome: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView { ChromeView(window: $window) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class ChromeView: NSView {
        let binding: Binding<NSWindow?>
        init(window: Binding<NSWindow?>) { binding = window; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            if window.toolbar == nil { window.toolbar = NSToolbar(identifier: "ChrupioSettingsChrome") }
            window.toolbar?.showsBaselineSeparator = false
            window.toolbarStyle = .unified
            window.isMovableByWindowBackground = false
            window.backgroundColor = .white
            let binding = binding
            DispatchQueue.main.async { binding.wrappedValue = window }
        }
    }
}

/// A settings tab: D1 cards on white, square controls, always light.
extension EnvironmentValues {
    /// The tallest the settings page grows before it scrolls. Debug snapshots raise it to show a whole page.
    @Entry var settingsPageHeight: CGFloat = 760
    /// The page's outer margin; the Settings window uses the D1 30 pt margin, standalone snapshots 20.
    @Entry var settingsPagePadding: CGFloat = 20
}

/// Fits its content's height up to `settingsPageHeight`, then scrolls.
private struct SettingsPage<Content: View>: View {
    @Environment(\.settingsPageHeight) private var maxHeight
    @Environment(\.settingsPagePadding) private var margin
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .padding(margin)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: contentHeight > 0 ? min(contentHeight, maxHeight) : maxHeight)
        .font(Theme.body)
        .foregroundStyle(Theme.ink)
        .toggleStyle(.brutalist)
        .buttonStyle(.brutalistCompact)
        .textFieldStyle(FieldStyle())
        .background(Theme.surface)
        .preferredColorScheme(.light)
    }
}

private struct GeneralSettings: View {
    @Bindable private var settings = AppSettings.shared
    @State private var launchAtLogin = Permissions.launchesAtLogin
    @State private var loginMessage: String?
    @State private var notificationsDenied = false

    var body: some View {
        SettingsPage {
            SettingsCard("Recording") {
                Toggle("Take notes automatically when a meeting starts", isOn: $settings.autoRecord)
                Toggle("Record the other participants (system audio)", isOn: $settings.captureSystemAudio)
                SettingRow(title: "Discard meetings shorter than") {
                    MenuPicker(selection: $settings.minimumMeetingSeconds,
                               options: [(0.0, "Keep all"), (30.0, "30 seconds"), (60.0, "1 minute"), (120.0, "2 minutes")])
                }
                Toggle("Show notifications", isOn: $settings.notify)
                if settings.notify, notificationsDenied {
                    NoteView(text: "Notifications are off for Chrupio in System Settings, so warnings show only as a red menu bar icon.", kind: .warning)
                    Button("Open Notification Settings") { Notifier.openSystemSettings() }
                }
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard enabled != Permissions.launchesAtLogin else { return }
                        do {
                            loginMessage = try Permissions.setLaunchAtLogin(enabled)
                        } catch {
                            loginMessage = error.localizedDescription
                            launchAtLogin = Permissions.launchesAtLogin
                        }
                    }
                if let loginMessage { NoteView(text: loginMessage, kind: .warning) }
            }
            SettingsCard("Speakers") {
                Toggle("Remove call audio the microphone picks up", isOn: $settings.echoCancellation)
                Text("For calls without headphones: cleans your track before transcribing so others' words aren't credited to you. The saved audio is unchanged.").secondaryText()
            }
            SettingsCard("Storage") {
                Toggle("Keep audio recordings after transcription", isOn: $settings.keepAudio)
                Text("Everything stays on this Mac in ~/Library/Application Support/Chrupio. Audio is deleted after 30 days; transcripts stay.").secondaryText()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([MeetingStore.defaultRoot])
                }
            }
            PermissionsSection()
        }
        .task { notificationsDenied = DebugSnapshot.directory == nil ? await Notifier.isDenied() : false }
    }
}

struct PermissionsSection: View {
    @State private var micStatus = Permissions.microphoneStatus
    @State private var axTrusted = Permissions.accessibilityTrusted
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsCard("Permissions") {
            PermissionRow(title: "Microphone", detail: "Records your side of the call.", granted: micStatus == .authorized) {
                if micStatus == .notDetermined {
                    Task { _ = await Permissions.requestMicrophone(); micStatus = Permissions.microphoneStatus }
                } else {
                    Permissions.openPrivacyPane("Privacy_Microphone")
                }
            }
            PermissionRow(title: "System audio", detail: "Asked the first time a meeting is recorded; records the other participants.", granted: nil) {
                Permissions.openPrivacyPane("Privacy_AudioCapture")
            }
            PermissionRow(title: "Accessibility", detail: "Reads Zoom participant names.", granted: axTrusted) {
                ZoomMonitor.promptForAccessibility()
                Permissions.openPrivacyPane("Privacy_Accessibility")
            }
        }
        .onReceive(timer) { _ in
            micStatus = Permissions.microphoneStatus
            axTrusted = Permissions.accessibilityTrusted
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool?
    let action: () -> Void

    var body: some View {
        SettingRow(title: title, detail: detail) {
            HStack(spacing: 8) {
                if granted == true {
                    StatusPill(text: "Allowed", kind: .ok)
                } else {
                    if granted == false { StatusPill(text: "Not allowed", kind: .warning) }
                    Button(granted == nil ? "Open Settings" : "Grant…", action: action)
                }
            }
        }
    }
}

private struct TranscriptionSettings: View {
    @Bindable private var settings = AppSettings.shared
    @State private var downloader = ModelDownloader.shared
    @State private var refresh = 0

    var body: some View {
        SettingsPage {
            SettingsCard("Speech engine") {
                SettingRow(title: "whisper.cpp", uppercase: false) {
                    if let cli = Transcriber.findWhisperCLI() {
                        StatusPill(text: WhisperBinaries.isBundled(cli) ? "Included" : "Homebrew", kind: .ok)
                    } else {
                        // Bundled in Chrupio.app; only a development build without Homebrew's gets here.
                        VStack(alignment: .trailing, spacing: 6) {
                            StatusPill(text: "Not found", kind: .error)
                            CommandText(text: "brew install whisper-cpp")
                        }
                    }
                }
                SettingRow(title: "Language") {
                    MenuPicker(selection: $settings.language, options: AppSettings.languages.map { ($0.code, $0.name) })
                }
                .disabled(settings.whisperModel.isEnglishOnly)
                .opacity(settings.whisperModel.isEnglishOnly ? 0.5 : 1)
                if settings.language == "auto", !settings.whisperModel.isEnglishOnly {
                    SettingRow(title: "Usual language", detail: "Used when detection is unsure. English calls are still recognized.") {
                        MenuPicker(selection: $settings.preferredLanguage,
                                   options: [("", "None")] + AppSettings.languages.dropFirst().map { ($0.code, $0.name) })
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Use Parakeet for Polish calls", isOn: $settings.parakeetForPolish)
                    Text("Parts of a call in Polish are transcribed with Parakeet, which gets more Polish words right than whisper. Everything else stays on whisper.").secondaryText()
                }
                VStack(alignment: .leading, spacing: 8) {
                    SettingRow(title: "Your name(s)", detail: "How calls show you, one per line or comma. Keeps you off the attendee list and out of speaker names.") {
                        EmptyView()
                    }
                    TextEditor(text: $settings.selfNames)
                        .font(Theme.font(13, .medium))
                        .foregroundStyle(Theme.ink)
                        .scrollContentBackground(.hidden)
                        .fieldBox()
                        .frame(height: 48)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SettingRow(title: "Vocabulary", detail: "Names and terms to spell right, one per line or comma. Meeting participants are added on their own.") {
                        EmptyView()
                    }
                    TextEditor(text: $settings.vocabulary)
                        .font(Theme.font(13, .medium))
                        .foregroundStyle(Theme.ink)
                        .scrollContentBackground(.hidden)
                        .fieldBox()
                        .frame(height: 96)
                }
            }
            ProjectContextCard()
            SettingsCard("Model") {
                ForEach(WhisperModel.all) { model in
                    let inUse = settings.whisperModelName == model.name
                    HStack(spacing: 12) {
                        Button { if model.isDownloaded { settings.whisperModelName = model.name } } label: { EmptyView() }
                            .buttonStyle(SquareRadioButtonStyle(isSelected: inUse))
                            .disabled(!model.isDownloaded)
                            .accessibilityLabel(model.name)
                            .accessibilityAddTraits(inUse ? .isSelected : [])
                        VStack(alignment: .leading, spacing: 2) {
                            // The radio button already carries the name for VoiceOver.
                            // Grey like the disabled radio mark until the model is downloaded (faint is 4.54:1 on white).
                            Text(model.name).font(Theme.font(14, .bold))
                                .foregroundStyle(model.isDownloaded ? Theme.ink : Theme.faint)
                                .accessibilityHidden(true)
                            Text(model.sizeDescription).secondaryText()
                            if let error = downloader.errors[model.name] {
                                Text(error).font(Theme.caption).foregroundStyle(Theme.Color.error)
                            }
                        }
                        Spacer()
                        if let progress = downloader.progress[model.name] {
                            LevelBar(value: progress).frame(width: 100)
                            Button("Cancel") { downloader.cancel(model) }
                        } else if model.isDownloaded {
                            if !inUse {
                                Button("Use") { settings.whisperModelName = model.name }
                            } else {
                                StatusPill(text: "In use", kind: .ok)
                            }
                        } else {
                            Button("Download") { downloader.download(model) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 56)
                    .background(inUse ? Theme.tile : .clear)
                    .id("\(model.name)-\(refresh)-\(downloader.progress[model.name] == nil)")
                }
            }
        }
    }
}

private struct SummarySettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        SettingsPage {
            SettingsCard("Summaries") {
                Toggle("Write summaries with Claude", isOn: $settings.claudeSummaries)
                Toggle("Summarize meetings automatically", isOn: $settings.autoSummarize)
                    .disabled(!settings.claudeSummaries)
                SettingRow(title: "Model") {
                    Text(ClaudeSummarizer.displayName(model: ClaudeSummarizer.defaultModel)).secondaryText()
                }
                SettingRow(title: "Claude account folder") {
                    TextField("Default (~/.claude)", text: $settings.claudeConfigDir).frame(width: 200)
                }
                let store = ClaudeCLIStore.shared
                if store.current() == nil {
                    Label("Claude Code is not installed; summaries wait until it is.", systemImage: "exclamationmark.triangle")
                        .font(Theme.font(13, .medium)).foregroundStyle(Theme.ink)
                } else if store.readiness?.login == .notLoggedIn {
                    Label("Claude Code is not logged in. Run claude in Terminal and type /login; summaries wait until then.",
                          systemImage: "exclamationmark.triangle")
                        .font(Theme.font(13, .medium)).foregroundStyle(Theme.ink)
                } else if let readiness = store.readiness, !readiness.missingFlags.isEmpty {
                    NoteView(text: "Claude Code is too old for Chrupio's summaries. Run claude update.", kind: .warning)
                    CopyableCommand(text: "claude update")
                }
                Text("Audio and transcription stay on this Mac. Summaries send the meeting title, date and attendees, your name, the transcript, your notes and any project context to Anthropic, using your Claude plan's quota. Each summary uses isolated claude -p calls (no tools, hooks or saved session).")
                    .secondaryText()
            }
        }
        .onAppear { ClaudeCLIStore.shared.refreshReadiness(force: true) }
        // Checked again once typing in the account folder pauses, not on every keystroke.
        .task(id: settings.claudeConfigDir) {
            guard (try? await Task.sleep(for: .seconds(0.8))) != nil else { return }
            ClaudeCLIStore.shared.refreshReadiness()
        }
    }
}

private struct IntegrationSettings: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        SettingsPage {
            SettingsCard("Google Meet, Microsoft Teams and Slack in Chrome") {
                SettingRow(title: "Chrome extension") {
                    // Re-evaluated on a timer: the status goes stale without any new event.
                    TimelineView(.periodic(from: .now, by: 5)) { _ in
                        if coordinator.isExtensionConnected {
                            StatusPill(text: "Connected", kind: .ok)
                        } else if !coordinator.isChromeRunning {
                            StatusPill(text: "Chrome not running", kind: .neutral, systemImage: "moon.zzz")
                        } else {
                            StatusPill(text: "Not connected", kind: .warning)
                        }
                    }
                }
                if coordinator.isExtensionConnected, let bundled = ChromeExtensionInstaller.bundledVersion,
                   ExtensionPackage.isOlder(coordinator.extensionVersion ?? "0", than: bundled) {
                    NoteView(text: "Chrome runs an older extension (\(coordinator.extensionVersion ?? "before 0.2.0")). This app ships \(bundled). In chrome://extensions, click the reload arrow on Chrupio Companion.",
                             kind: .warning)
                }
                let missing = ExtensionPackage.chromeProfilesWithoutExtension()
                if !missing.isEmpty, FileManager.default.fileExists(atPath: ExtensionPackage.chromeFolder.path) {
                    NoteView(text: "Not loaded in these Chrome profiles: \(missing.joined(separator: ", ")). Calls there are recorded as \"Browser call\" without names, and back-to-back calls can merge into one. Load the extension in every profile you take calls in.",
                             kind: .warning)
                }
                Text("The extension tells Chrupio when you join a call and who is in it.")
                    .secondaryText()
                ExtensionLoadSteps()
                Toggle("Also record when Chrome uses the microphone without the extension", isOn: $settings.detectWithoutExtension)
                if let serverError = coordinator.serverError {
                    NoteView(text: serverError, kind: .error)
                }
            }
            SettingsCard("Zoom") {
                Text("Zoom calls are detected from the Zoom app. Participant names are read from Zoom's Participants panel, which needs the Accessibility permission. Open the panel during the call to capture everyone. Zoom doesn't expose who is talking, so in calls with more than one other person their lines are labelled \"Others\".")
                    .secondaryText()
            }
            SettingsCard("Diagnostics") {
                Toggle("Save diagnostics", isOn: $settings.saveDiagnostics)
                Text("Saves what the Chrome extension and Zoom saw during a call (page structure, participant names) next to the meeting, to fix speaker detection. Off by default.")
                    .secondaryText()
            }
            PermissionsSection()
        }
    }
}

struct ClaudeCodeSettings: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    @Bindable private var settings = AppSettings.shared
    @State private var integration: ClaudeCodeIntegration
    @State private var exportMessage: String?

    init(integration: ClaudeCodeIntegration = ClaudeCodeIntegration()) {
        _integration = State(initialValue: integration)
    }

    var body: some View {
        SettingsPage {
            SettingsCard("Meeting tools for Claude Code") {
                SettingRow(title: "Status") { status }
                Text("Lets Claude Code in any project list, search and read your meetings: summaries, action items, transcripts and attendees, including a meeting that is still recording (its transcript comes when the call ends). Claude Code can also add notes to a meeting, tick off action items, rename meetings, update summaries and put names to unnamed speakers. It never changes the words of a transcript. Works even when Chrupio is closed.")
                    .secondaryText()
                VStack(alignment: .leading, spacing: 10) {
                    componentToggle("Meeting tools", \.mcp,
                                    "Claude Code can search, read and update your meetings when you ask.")
                    componentToggle("Recent meetings at session start", \.digest,
                                    "Each new Claude Code session starts with a short list of the last 7 days' meetings and open action items. This uses a little of every session's context.")
                    componentToggle("New meetings while you work", \.prompt,
                                    "When a meeting ends during a Claude Code session, your next message gets one line about it.")
                }
                .disabled(integration.isWorking || integration.state == .checking)
                if integration.state == .connected || integration.state == .partial {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(integration.details.enumerated()), id: \.element.target) { index, detail in
                            if index > 0 { DashedRule() }
                            ConfigFileChecks(path: integration.label(for: detail.target),
                                             checks: detail.checks(binary: ClaudeCodeIntegration.serverBinary.path,
                                                                  components: integration.components))
                                .padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.regular))
                }
                HStack {
                    switch integration.state {
                    case .connected:
                        disconnectButton
                    case .notConnected:
                        Button("Connect to Claude Code") { integration.connect() }
                            .buttonStyle(BrutalistButtonStyle(kind: .ink, compact: true))
                            .disabled(integration.components.isEmpty || integration.locationRefusal != nil)
                    case .partial:
                        Button("Repair connection") { integration.connect() }
                            .buttonStyle(BrutalistButtonStyle(kind: .ink, compact: true))
                            .disabled(integration.locationRefusal != nil)
                        disconnectButton
                    case .cliMissing:
                        Button("Check again") { integration.checkAgain() }
                            .buttonStyle(BrutalistButtonStyle(kind: .ink, compact: true))
                        if integration.installed != nil { disconnectButton }
                    case .checking:
                        EmptyView()
                    }
                    if integration.isWorking { ProgressView().controlSize(.small) }
                }
                .disabled(integration.isWorking)
                if integration.state == .notConnected, integration.components.isEmpty {
                    Text("Turn on at least one switch to connect.").secondaryText()
                }
                if integration.state == .cliMissing {
                    Text("Install Claude Code, then check again.").secondaryText()
                    CopyableCommand(text: "curl -fsSL https://claude.ai/install.sh | bash")
                }
                if integration.state == .notConnected || integration.state == .partial, let refusal = integration.locationRefusal {
                    NoteView(text: refusal, kind: .warning)
                }
                if let message = integration.message {
                    Text(message).secondaryText().textSelection(.enabled)
                }
                Text("Ask things like \"what did we decide in yesterday's pricing call?\" or \"list my open action items from this week\". In Claude Code, @chrupio: mentions a meeting and /chrupio:recent_meetings recaps the week.")
                    .secondaryText()
            }
            SettingsCard("Markdown notes") {
                Toggle("Save each meeting as a Markdown file", isOn: $settings.exportMarkdown)
                SettingRow(title: "Folder") {
                    Text(UserHome.display(settings.exportFolderPath))
                        .font(Theme.font(13, .medium)).foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                FlowLayout(spacing: 8) {
                    Button("Change…", action: chooseFolder)
                    Button("Show in Finder") {
                        let folder = URL(fileURLWithPath: settings.exportFolderPath, isDirectory: true)
                        if MeetingExporter.isDefaultFolder(folder) {
                            try? FilePermissions.ensurePrivateDirectory(folder)
                        } else {
                            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        }
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    Button("Export all now") { exportAll() }
                    Button("Link a project…", action: linkProject)
                        .help("Adds a meetings link to this folder inside a project, so Claude Code there can read the notes as files.")
                }
                .disabled(!settings.exportMarkdown)
                if let exportMessage { Text(exportMessage).secondaryText().textSelection(.enabled) }
                if let exportError = coordinator.exportError {
                    NoteView(text: exportError, kind: .error)
                }
                Text("One file per meeting with YAML front matter, the summary and the transcript. Renaming or deleting a meeting updates its file. Point Claude Code, Obsidian or any notes tool at this folder.")
                    .secondaryText()
            }
        }
        .onAppear { integration.refresh() }
        .onChange(of: settings.exportMarkdown) { _, enabled in if enabled { exportAll() } }
    }

    private var disconnectButton: some View {
        Button("Disconnect from Claude Code") { integration.disconnect() }
            .buttonStyle(BrutalistButtonStyle(compact: true))
            .help("Removes Chrupio's meeting tools and hooks from every Claude Code config it set up. Your meetings stay.")
    }

    /// One of the three switches; flipping it while connected applies at once (see `ClaudeCodeIntegration.set`).
    private func componentToggle(_ title: String, _ part: WritableKeyPath<ClaudeCodeSetup.Components, Bool>,
                                 _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: Binding(
                get: { integration.components[keyPath: part] },
                set: { on in
                    var components = integration.components
                    components[keyPath: part] = on
                    integration.set(components)
                }))
                .accessibilityHint(detail)
            Text(detail).secondaryText()
        }
    }

    @ViewBuilder private var status: some View {
        if let label = integration.state.label {
            StatusPill(text: label, kind: integration.state == .connected ? .ok : .warning)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func linkProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Link"
        panel.message = "Choose a project folder. A meetings link to your notes is added there (and to its .gitignore)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        integration.link(project: url, notes: URL(fileURLWithPath: settings.exportFolderPath, isDirectory: true))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = URL(fileURLWithPath: settings.exportFolderPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let old = URL(fileURLWithPath: settings.exportFolderPath, isDirectory: true)
        settings.exportFolderPath = url.path
        exportAll(movingFrom: old.standardizedFileURL == url.standardizedFileURL ? nil : old)
    }

    /// Writes every meeting to the current folder; after a folder change, removes them from the old one
    /// once the new copies are written, so a project linked to either folder doesn't read stale notes.
    private func exportAll(movingFrom old: URL? = nil) {
        exportMessage = nil
        Task {
            let result = await coordinator.exportAll(movingFrom: old)
            var message = "Exported \(result.written) meeting\(result.written == 1 ? "" : "s")."
            if let error = result.error { message += " Some failed: \(error)" }
            if old != nil, result.error == nil { message += " Removed them from the old folder; relink projects that used it." }
            exportMessage = message
        }
    }
}

/// The project context file: vocabulary, misheard words, people and recurring meetings for one project.
private struct ProjectContextCard: View {
    @Bindable private var settings = AppSettings.shared
    @State private var message: String?

    private var context: MeetingContext? {
        let path = (settings.contextFile as NSString).expandingTildeInPath
        return path.isEmpty ? nil : MeetingContext.load(from: URL(fileURLWithPath: path))
    }

    var body: some View {
        SettingsCard("Project context") {
            SettingRow(title: "Context file", detail: "JSON with vocabulary, corrections, people and recurring meetings. Used for every transcript and summary.") {
                HStack(spacing: 8) {
                    TextField("None", text: $settings.contextFile).frame(width: 220)
                    Button("Choose…", action: choose)
                }
            }
            SettingRow(title: "Status", detail: message) {
                if let context {
                    StatusPill(text: "\(context.vocabulary?.count ?? 0) terms, \(context.corrections?.count ?? 0) fixes, \(context.profiles?.count ?? 0) meetings", kind: .ok)
                } else if settings.contextFile.isEmpty {
                    StatusPill(text: "Not set", kind: .neutral)
                } else {
                    StatusPill(text: "Can't read the file", kind: .error)
                }
            }
            SettingRow(title: "Vocabulary", detail: "Copy the file's terms into the vocabulary list below.") {
                Button("Import vocabulary", action: importVocabulary).disabled(context?.vocabulary?.isEmpty ?? true)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { settings.contextFile = url.path }
    }

    private func importVocabulary() {
        let current = settings.vocabulary.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var seen = Set(current.map { $0.lowercased() })
        let added = (context?.vocabulary ?? []).filter { seen.insert($0.lowercased()).inserted }
        settings.vocabulary = (current + added).joined(separator: "\n")
        message = added.isEmpty ? "Nothing new to add." : "Added \(added.count) terms."
    }
}

/// One Claude Code config file: its path in normal case, then a chip per check. Chips sit beside the path when
/// they fit and wrap below it when they don't (long paths, the OpenKrisp leftovers chip).
private struct ConfigFileChecks: View {
    let path: String
    let checks: [ClaudeCodeSetup.Status.Check]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                pathText
                Spacer(minLength: 8)
                HStack(spacing: 6) { chips }
            }
            VStack(alignment: .leading, spacing: 8) {
                pathText
                FlowLayout(spacing: 6) { chips }
            }
        }
    }

    private var pathText: some View {
        Text(path)
            .font(Theme.font(12, .bold))
            .lineLimit(1).truncationMode(.middle)
            .textSelection(.enabled)
    }

    private var chips: some View {
        ForEach(checks, id: \.title) { check in
            // A failing check is a black chip so it never shares the orange of the "Connected" pill.
            TagChip(text: check.title, kind: check.ok ? .plain : .ink, size: 10)
        }
    }
}

/// A dashed black rule between config files.
private struct DashedRule: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(Theme.ink), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
        }
        .frame(height: 2)
    }
}

/// Numbered steps and buttons for loading the unpacked extension. Used in onboarding and Settings > Meetings.
struct ExtensionLoadSteps: View {
    @State private var error: String?
    @State private var copied = false
    @State private var movedNotice = ChromeExtensionInstaller.movedFolderNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let movedNotice { NoteView(text: movedNotice, kind: .warning) }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(ExtensionLoadGuide.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)").secondaryText()
                }
                Text(ExtensionLoadGuide.connectedNote).secondaryText()
            }
            Text(ChromeExtensionInstaller.displayPath)
                .font(Theme.font(12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy folder path") {
                    run(ChromeExtensionInstaller.copyFolderPath)
                    guard error == nil else { return }
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                }
                .accessibilityLabel(copied ? "Folder path copied" : "Copy folder path")
                Button("Show in Finder") { run(ChromeExtensionInstaller.showInFinder) }
                    .accessibilityLabel("Show extension folder in Finder")
                Button("Open Chrome extensions page") { run(ChromeExtensionInstaller.openExtensionsPage) }
                    .accessibilityLabel("Open Chrome extensions page")
            }
            .buttonStyle(BrutalistButtonStyle(compact: true))
            Text(ExtensionLoadGuide.developerModeNote).secondaryText()
            if let error { NoteView(text: error, kind: .error) }
        }
        .onAppear { movedNotice = ChromeExtensionInstaller.movedFolderNotice }
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
}
