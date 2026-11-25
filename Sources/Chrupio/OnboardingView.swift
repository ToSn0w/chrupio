import AVFoundation
import Combine
import ChrupioCore
import SwiftUI

/// First-run setup: permissions, Chrome extension, the speech model, Claude Code for summaries and its meeting tools.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = AppSettings.shared
    @State private var downloader = ModelDownloader.shared
    @State private var micStatus = Permissions.microphoneStatus
    @State private var integration: ClaudeCodeIntegration
    @State private var tick = 0
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    init(integration: ClaudeCodeIntegration = ClaudeCodeIntegration()) {
        _integration = State(initialValue: integration)
    }

    var body: some View {
        // Reading tick re-runs the checks below every 1.5 s without resetting child state (Copied, selection, focus).
        let _ = tick
        let claudeFound = integration.snapshotCLIInstalled ?? (ClaudeCLIStore.shared.current() != nil)
        let readiness = claudeFound ? ClaudeCLIStore.shared.readiness : nil
        let claudeReady = claudeFound && readiness?.login != .notLoggedIn
        let modelName = settings.whisperModel.name
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(nsImage: MenuBarGlyph.image)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Theme.ink)
                    .frame(width: 76, height: 76)
                    .brutalistPanel(fill: Theme.accent, border: Theme.Border.heavy, shadow: Theme.Shadow.regular, padding: 0)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Chrupio").font(Theme.heading(24)).textCase(.uppercase)
                    Text("Meeting notes for Meet, Teams, Slack and Zoom. Audio and transcripts stay on this Mac. Summaries send the meeting title, date and attendees, your name, the transcript, your notes and any project context to Anthropic, using your Claude plan's quota.")
                        .font(Theme.font(14))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                step(1, "Allow the microphone", done: micStatus == .authorized) {
                    Button("Allow") {
                        Task { _ = await Permissions.requestMicrophone(); micStatus = Permissions.microphoneStatus }
                    }
                }
                step(2, "Load the Chrome extension (Meet, Teams, Slack)", done: MeetingCoordinator.shared.isExtensionConnected) {
                    EmptyView()
                } below: {
                    ExtensionLoadSteps()
                }
                step(3, "Allow Accessibility (Zoom participant names)", done: Permissions.accessibilityTrusted) {
                    Button("Allow…") {
                        ZoomMonitor.promptForAccessibility()
                        Permissions.openPrivacyPane("Privacy_Accessibility")
                    }
                }
                step(4, "Speech engine (whisper.cpp)", done: Transcriber.findWhisperCLI() != nil) {
                    EmptyView()
                } below: {
                    // Bundled in Chrupio.app; only a development build (swift run) without Homebrew's gets here.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Missing from this copy of Chrupio. Reinstall it from the latest release, or for a development build:").secondaryText()
                        CopyableCommand(text: "brew install whisper-cpp")
                    }
                }
                step(5, "Speech model (\(modelName), \(settings.whisperModel.sizeDescription))",
                     done: settings.whisperModel.isDownloaded, busy: downloader.progress[modelName] != nil) {
                    if downloader.progress[modelName] != nil {
                        if let bytes = downloader.bytes[modelName], bytes.completed > 0 {
                            Text(DownloadProgressText.text(completed: bytes.completed, total: bytes.total))
                                .font(Theme.font(12, .bold))
                                .monospacedDigit()
                        }
                    } else {
                        if let error = downloader.errors[modelName] {
                            Text(error).font(Theme.caption).foregroundStyle(Theme.Color.error).lineLimit(2)
                        }
                        Button(downloader.errors[modelName] == nil ? "Download" : "Retry") {
                            downloader.download(settings.whisperModel)
                        }
                    }
                } below: {
                    if let progress = downloader.progress[modelName] {
                        LevelBar(value: progress, segments: 24, track: Theme.surface, height: 14)
                            .padding(6)
                            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.regular))
                    }
                }
                step(6, "Summaries (Claude Code, logged in)", done: claudeReady && readiness?.missingFlags.isEmpty != false) {
                    EmptyView()
                } below: {
                    if !claudeFound {
                        CopyableCommand(text: "curl -fsSL https://claude.ai/install.sh | bash")
                    } else if readiness?.login == .notLoggedIn {
                        Text("Not logged in. Run claude in Terminal and type /login.").secondaryText()
                    } else if let readiness, !readiness.missingFlags.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Claude Code is too old for Chrupio's summaries. Run claude update.").secondaryText()
                            CopyableCommand(text: "claude update")
                        }
                    }
                }
                step(7, "Meeting tools for Claude Code",
                     detail: "Lets Claude Code search, read and update your meetings in any project.",
                     done: integration.state == .connected) {
                    if integration.isWorking { ProgressView().controlSize(.small) }
                    Button("Connect") { integration.connect() }
                        .buttonStyle(BrutalistButtonStyle(kind: .ink, compact: true))
                        .disabled(integration.isWorking || integration.state == .cliMissing || integration.state == .checking
                                  || integration.locationRefusal != nil || integration.components.isEmpty)
                        .help(integration.state == .cliMissing ? "Install Claude Code first (step 6)" : "Adds Chrupio's meeting tools to Claude Code")
                } below: {
                    if let refusal = integration.locationRefusal {
                        NoteView(text: refusal, kind: .warning)
                    } else {
                        Text(integration.components.connectLine).secondaryText()
                    }
                }
            }
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.heavy))

            if let message = integration.message {
                Text(message).secondaryText().textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }

            Text("The first time a meeting is recorded, macOS asks to allow system audio recording so Chrupio can hear the other participants.")
                .font(Theme.caption)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") {
                    settings.hasCompletedOnboarding = true
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.brutalistInk)
            }
        }
        .padding(28)
        .frame(width: 680)
        .font(Theme.body)
        .foregroundStyle(Theme.ink)
        .buttonStyle(.brutalistCompact)
        .background(Theme.surface)
        .preferredColorScheme(.light)
        .onReceive(timer) { _ in
            micStatus = Permissions.microphoneStatus
            tick += 1
            ClaudeCLIStore.shared.refreshReadiness()
        }
        .onAppear {
            integration.refresh()
            ClaudeCLIStore.shared.refreshReadiness(force: true)
        }
        .onChange(of: claudeFound) { _, found in if found { integration.refresh(force: true) } }
    }

    /// One setup row. `below` sits under the title row, 40 pt in so it lines up with the title, while the step isn't done.
    /// `busy` fills the number box orange (a download in progress).
    private func step(_ number: Int, _ title: String, detail: String? = nil, done: Bool, busy: Bool = false,
                      @ViewBuilder action: () -> some View,
                      @ViewBuilder below: () -> some View = { EmptyView() }) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    ZStack {
                        Rectangle().fill(done ? Theme.ink : busy ? Theme.accent : Theme.surface).frame(width: 28, height: 28)
                            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.regular))
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.accent)
                                .accessibilityLabel("Done")
                        } else {
                            Text("\(number)").font(Theme.font(13, .bold)).foregroundStyle(Theme.ink)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(Theme.font(14, .bold)).foregroundStyle(done ? Theme.muted : Theme.ink)
                        if let detail, !done { Text(detail).secondaryText() }
                    }
                    Spacer()
                    if !done { action() }
                }
                .frame(minHeight: 56)
                if !done {
                    below()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 40)
                        .padding(.bottom, 14)
                }
            }
            .padding(.horizontal, 14)
            .background(done ? Theme.tile : Theme.surface)
            if number < 7 { Rectangle().fill(Theme.ink).frame(height: Theme.Border.regular) }
        }
    }
}
