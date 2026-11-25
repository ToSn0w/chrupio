import ChrupioCore
import SwiftUI

struct MenuBarView: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Bindable private var settings = AppSettings.shared
    private var updater = Updater.shared
    /// Snapshots only: show this meeting in the recording card without recording.
    var previewRecording: Meeting?
    @State private var integration = ClaudeCodeIntegration()

    init(previewRecording: Meeting? = nil) {
        self.previewRecording = previewRecording
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let meeting = previewRecording ?? coordinator.activeMeeting {
                RecordingCard(meeting: meeting, claudeConnected: integration.state == .connected)
            } else {
                idleCard
                claudeCodeBar
            }
            if !coordinator.meetings.isEmpty {
                recentMeetings
            }
            footer
        }
        .padding(16)
        .frame(width: 360)
        .font(Theme.body)
        .foregroundStyle(Theme.ink)
        .background(Theme.surface)
        .preferredColorScheme(.light)
        .background(MenuBarAnchor())
        .onAppear { integration.refresh() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: MenuBarGlyph.image)
                .renderingMode(.template)
                .resizable()
                .frame(width: 18, height: 18)
                .foregroundStyle(Theme.ink)
                .frame(width: 32, height: 32)
                .background(Theme.accent)
                .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.regular))
            Text("Chrupio").font(Theme.heading(18)).textCase(.uppercase)
            Spacer()
            Toggle(isOn: $settings.autoRecord) {
                Text("Auto").font(Theme.label).textCase(.uppercase)
            }
            .toggleStyle(BrutalistToggleStyle(small: true))
            .fixedSize()
            .help("Record meetings automatically when they start")
        }
    }

    private var idleCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let candidate = coordinator.detectedCandidate {
                Label("\(candidate.platform.displayName) detected", systemImage: "dot.radiowaves.left.and.right")
                    .tagChip(.accent, size: 12)
            } else {
                Label(settings.autoRecord ? "Waiting for a meeting" : "Auto-recording is off",
                      systemImage: settings.autoRecord ? "ear" : "pause.circle")
                    .font(Theme.label)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.muted)
            }
            Button {
                coordinator.startManualRecording()
            } label: {
                Label("Start taking notes", systemImage: "record.circle")
            }
            .buttonStyle(BrutalistButtonStyle(kind: .ink, fullWidth: true))
            if let error = coordinator.lastError {
                NoteView(text: error, kind: .error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .brutalistPanel(padding: 16)
    }

    /// Black strip: "> CLAUDE CODE" and the connection state in Settings' words.
    private var claudeCodeBar: some View {
        Button {
            NSApp.activate()
            openSettings()
        } label: {
            HStack(spacing: 8) {
                Text(">").foregroundStyle(Theme.accent).accessibilityHidden(true)
                // "Claude Code not found" already names Claude Code; show the state alone then.
                if integration.state != .cliMissing {
                    Text("Claude Code").textCase(.uppercase)
                }
                Spacer()
                if let label = integration.state.label {
                    Text(integration.state == .connected ? "■" : "!")
                        .foregroundStyle(integration.state == .connected ? Theme.accent : Theme.surface)
                        .accessibilityHidden(true)
                    Text(label).textCase(.uppercase)
                } else {
                    ProgressView().controlSize(.mini).tint(Theme.surface)
                }
            }
            .font(Theme.font(12, .bold))
            .foregroundStyle(Theme.surface)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(Theme.ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Claude Code settings")
    }

    private var recentMeetings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent").sectionLabel()
            VStack(spacing: 0) {
                ForEach(Array(coordinator.meetings.prefix(4).enumerated()), id: \.element.id) { index, meeting in
                    if index > 0 { Rectangle().fill(Theme.ink).frame(height: Theme.Border.regular) }
                    Button {
                        MainWindowSelection.shared.meetingID = meeting.id
                        open("main")
                    } label: {
                        HStack(spacing: 10) {
                            PlatformTag(platform: meeting.platform)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.title).font(Theme.font(14, .bold)).lineLimit(1)
                                Text(meeting.startedAt.shown(date: .abbreviated, time: .shortened))
                                    .secondaryText()
                            }
                            Spacer(minLength: 4)
                            StatusBadge(meeting: meeting)
                            RowChevron()
                        }
                        .padding(10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.heavy))
            if integration.state == .connected {
                Text("> readable from Claude Code")
                    .accessibilityLabel("readable from Claude Code")
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Open notes") { open("main") }
                .buttonStyle(.brutalistCompact)
            Spacer()
            if Updater.isConfigured {
                Button {
                    Updater.shared.checkForUpdates()
                } label: {
                    Image(systemName: updater.availableVersion == nil ? "arrow.down.circle" : "arrow.down.circle.fill")
                }
                    .buttonStyle(SquareIconButtonStyle(size: 32))
                    .disabled(!updater.canCheckForUpdates)
                    .help(updater.availableVersion.map { "Chrupio \($0) is available" } ?? "Check for Updates…")
                    .accessibilityLabel(updater.availableVersion.map { "Update to Chrupio \($0)" } ?? "Check for Updates…")
            }
            Button {
                NSApp.activate()
                openSettings()
            } label: { Image(systemName: "gearshape") }
                .buttonStyle(SquareIconButtonStyle(size: 32))
                .help("Settings")
                .accessibilityLabel("Settings")
            Button {
                NSApp.terminate(nil)
            } label: { Image(systemName: "power") }
                .buttonStyle(SquareIconButtonStyle(size: 32))
                .help("Quit Chrupio")
                .accessibilityLabel("Quit Chrupio")
        }
    }

    private func open(_ id: String) {
        NSApp.activate()
        openWindow(id: id)
    }
}

/// A list row: white, light grey while pressed.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.ink)
            .background(configuration.isPressed ? Theme.tile : Theme.surface)
            .focusRing(inset: true)
            .focusEffectDisabled()
    }
}

/// The recording panel: orange, black border, large shadow, a big timer and segmented level meters.
struct RecordingCard: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    let meeting: Meeting
    /// Shows the "shared with Claude Code" footer; only true when the MCP server is connected.
    var claudeConnected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    // The red recording dot, kept from the old card, as a square.
                    Text("■").foregroundStyle(Theme.Color.error).accessibilityHidden(true)
                    Text("Taking notes")
                }
                .tagChip()
                Spacer()
                PlatformTag(platform: meeting.platform, onDark: true)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(TranscriptFormatter.timestamp(meeting.duration))
                    .font(Theme.font(64, .bold))
                    .tracking(-2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text(meeting.title).font(Theme.font(15, .bold)).lineLimit(1)
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                HStack(spacing: 10) {
                    LevelTile(label: "You", level: coordinator.micLevel)
                    LevelTile(label: "Others", level: coordinator.systemLevel)
                }
            }
            if !meeting.attendees.isEmpty {
                Text(meeting.attendees.joined(separator: ", "))
                    .font(Theme.font(12, .bold)).lineLimit(2)
            }
            if let last = meeting.segments.last {
                // Same characters as before ("<label>: <text>"); only the name is bold.
                Text("\(Text(last.speaker.label).font(Theme.font(12, .bold))): \(last.text)")
                    .font(Theme.font(12)).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .brutalistPanel(border: Theme.Border.regular, shadow: 0, padding: 10)
            }
            if let error = meeting.error {
                // Red text needs white behind it; red on orange is unreadable.
                NoteView(text: error, kind: .error)
            }
            Button(role: .destructive) {
                coordinator.stopRecording()
            } label: {
                Label("Stop and create notes", systemImage: "stop.fill")
            }
            .buttonStyle(BrutalistButtonStyle(kind: .ink, fullWidth: true, shadowColor: Theme.surface))
            if claudeConnected {
                Text("> Shared with Claude Code when the call ends")
                    .accessibilityLabel("Shared with Claude Code when the call ends")
                    .font(Theme.font(11, .bold))
                    .textCase(.uppercase)
            }
        }
        .foregroundStyle(Theme.ink)
        .brutalistPanel(fill: Theme.accent, border: Theme.Border.frame, shadow: Theme.Shadow.large, padding: 18)
    }
}

private struct LevelTile: View {
    let label: String
    let level: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(Theme.label).textCase(.uppercase)
            LevelBar(value: Double(level))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .brutalistPanel(border: Theme.Border.regular, shadow: 0, padding: 10)
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int((min(1, max(0, level)) * 100).rounded())) percent")
    }
}

/// Keeps the menu bar panel hanging from the menu bar. AppKit keeps a window's bottom edge when its height changes,
/// so when the content got shorter (recording card replaced by the idle card) the panel slid down, away from the icon.
struct MenuBarAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) { view.pin() }

    final class AnchorView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didMoveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pin() }
                })
            }
            pin()
        }

        func pin() {
            guard let window else { return }
            // The status item's own window marks the bar on whichever display holds the icon; the panel's `screen`
            // could be another display, which put the panel far below the bar.
            let item = NSApp.windows.first { $0 !== window && $0.className.contains("StatusBarWindow") && $0.isVisible }
            guard let screen = item?.screen ?? window.screen ?? NSScreen.main else { return }
            let top = item.map { $0.frame.minY } ?? MenuBarAnchor.top(of: screen.frame, visible: screen.visibleFrame)
            let left = MenuBarAnchor.left(window.frame.minX, width: window.frame.width, screen: screen.frame)
            guard abs(window.frame.maxY - top) > 0.5 || abs(window.frame.minX - left) > 0.5 else { return }
            window.setFrameTopLeftPoint(NSPoint(x: left, y: top))
        }

    }

    /// Under the icon, but never past the screen's right edge (an icon near the edge pushed the panel half off screen).
    static func left(_ x: CGFloat, width: CGFloat, screen: NSRect, margin: CGFloat = 8) -> CGFloat {
        max(screen.minX + margin, min(x, screen.maxX - width - margin))
    }

    /// Just below the menu bar; with a hidden menu bar the visible frame reaches the top, so use the screen's top less the bar.
    static func top(of screen: NSRect, visible: NSRect) -> CGFloat {
        visible.maxY < screen.maxY ? visible.maxY : screen.maxY - NSStatusBar.system.thickness
    }
}
