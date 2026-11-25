import ChrupioCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class MainWindowSelection {
    static let shared = MainWindowSelection()
    var meetingID: UUID?
}

struct MainWindow: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    @Bindable private var selection = MainWindowSelection.shared
    @Bindable private var settings = AppSettings.shared
    @State private var search = ""
    @State private var pendingDelete: Meeting?
    @State private var integration = ClaudeCodeIntegration()
    @Environment(\.openSettings) private var openSettings
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.meetingID) {
                ForEach(groups, id: \.title) { group in
                    Section {
                        ForEach(group.meetings) { meeting in
                            MeetingRow(meeting: meeting).tag(meeting.id)
                                .contextMenu {
                                    Button("Delete…", role: .destructive) { pendingDelete = meeting }
                                        .disabled(coordinator.isBusy(meeting.id))
                                }
                        }
                    } header: {
                        Text(group.title).sectionLabel()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
            .tint(Theme.accent)
            .searchable(text: $search, placement: .sidebar, prompt: "Search notes")
            .confirmationDialog("Delete “\(pendingDelete?.title ?? "")”?",
                                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                presenting: pendingDelete) { meeting in
                Button("Delete meeting, transcript and audio", role: .destructive) { coordinator.delete(meeting) }
            } message: { _ in
                Text("This can't be undone.")
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 360)
            .font(Theme.body)
            .overlay {
                if coordinator.meetings.isEmpty {
                    EmptyState(title: "No meetings yet", systemImage: "waveform",
                               detail: "Join a Meet, Teams, Slack or Zoom call and Chrupio will take notes.")
                }
            }
            .toolbar {
                ToolbarItem(placement: .status) {
                    if let label = integration.state.label {
                        Button {
                            NSApp.activate()
                            openSettings()
                        } label: {
                            HStack(spacing: 6) {
                                Text(">").accessibilityHidden(true)
                                // "Claude Code not found" already names Claude Code.
                                Text(integration.state == .cliMissing ? label : "Claude Code: \(label)")
                            }
                            .tagChip(integration.state == .connected ? .accent : .plain, size: 11, uppercase: false)
                        }
                        .buttonStyle(.plain)
                        .help("Claude Code settings")
                    }
                }
                ToolbarItem {
                    if coordinator.recording == nil {
                        Button { coordinator.startManualRecording() } label: { Label("Record", systemImage: "record.circle") }
                            .help("Start taking notes now")
                    } else {
                        Button { coordinator.stopRecording() } label: { Label("Stop", systemImage: "stop.circle.fill") }
                            .tint(Theme.Color.error)
                            .help("Stop recording and create notes")
                    }
                }
            }
        } detail: {
            if let id = selection.meetingID, let meeting = coordinator.meetings.first(where: { $0.id == id }) {
                MeetingDetailView(meeting: meeting).id(meeting.id).environment(integration)
            } else {
                EmptyState(title: "Select a meeting", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.surface)
            }
        }
        .preferredColorScheme(.light)
        .onAppear(perform: selectFallback)
        .onAppear { integration.refresh() }
        // Connect/Disconnect happen in Settings; re-check when this window comes back to the front.
        .onChange(of: appearsActive) { _, active in if active { integration.refresh() } }
        // Meetings load after launch and can be deleted; never leave the detail pane empty when there are notes.
        .onChange(of: coordinator.meetings.map(\.id)) { selectFallback() }
        .sheet(isPresented: Binding(get: { !settings.hasCompletedOnboarding }, set: { if !$0 { settings.hasCompletedOnboarding = true } })) {
            OnboardingView()
        }
    }

    private func selectFallback() {
        if selection.meetingID.map({ id in coordinator.meetings.contains { $0.id == id } }) != true {
            selection.meetingID = coordinator.meetings.first?.id
        }
    }

    private var filtered: [Meeting] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return coordinator.meetings }
        return coordinator.meetings.filter { meeting in
            meeting.title.localizedCaseInsensitiveContains(query)
                || meeting.attendees.contains { $0.localizedCaseInsensitiveContains(query) }
                || (meeting.summary?.markdown.localizedCaseInsensitiveContains(query) ?? false)
                || meeting.segments.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    private var groups: [(title: String, meetings: [Meeting])] {
        let calendar = Date.displayCalendar
        var result: [(String, [Meeting])] = []
        for meeting in filtered {
            let title: String
            if calendar.isDateInToday(meeting.startedAt) {
                title = "Today"
            } else if calendar.isDateInYesterday(meeting.startedAt) {
                title = "Yesterday"
            } else {
                title = meeting.startedAt.shownMonthYear
            }
            if result.last?.0 == title {
                result[result.count - 1].1.append(meeting)
            } else {
                result.append((title, [meeting]))
            }
        }
        return result
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    @Environment(\.backgroundProminence) private var prominence
    private var selectedRow: Bool { prominence == .increased }

    /// Today and Yesterday headings already name the day; rows under a month heading need it.
    private var startText: String {
        let calendar = Date.displayCalendar
        if calendar.isDateInToday(meeting.startedAt) || calendar.isDateInYesterday(meeting.startedAt) {
            return meeting.startedAt.shown(date: .omitted, time: .shortened)
        }
        return meeting.startedAt.shownDayAndTime
    }

    /// One line, so a narrow column truncates at the end rather than mid-date.
    private var subtitle: String {
        var parts = [startText, TranscriptFormatter.durationText(meeting.duration)]
        if !meeting.attendees.isEmpty {
            parts.append(meeting.attendees.count == 1 ? "1 person" : "\(meeting.attendees.count) people")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            PlatformTag(platform: meeting.platform)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).lineLimit(1).font(Theme.font(14, .bold))
                    .foregroundStyle(selectedRow ? SelectionText.color : Theme.ink)
                Text(subtitle)
                    .lineLimit(1)
                    .font(Theme.caption)
                    // Grey is hard to read on the selection highlight; see SelectionText for the colour used there.
                    .foregroundStyle(selectedRow ? SelectionText.color : Theme.muted)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            StatusBadge(meeting: meeting)
            RowChevron()
        }
        .padding(.vertical, 5)
    }
}

/// Text colour for the selected sidebar row. The highlight follows the system accent colour: orange (`.tint`) only
/// when the accent is Multicolor, otherwise the accent's selection colour. No single colour reads on both: on the
/// default blue (#0064E1) black is 3.9:1 and white 5.4:1; on orange (#FF5B1F) black is 6.8:1 and white 3.1:1.
/// The adaptive `.primary` style turns white under the selection, which fails on orange. So this picks black or
/// white, whichever contrasts more with the actual highlight; that is ≥4.5:1 on blue and on Multicolor orange.
enum SelectionText {
    static var color: SwiftUI.Color {
        // No AppleAccentColor in the global domain means Multicolor, where the List uses the app's tint.
        let multicolor = UserDefaults.standard.object(forKey: "AppleAccentColor") == nil
        let highlight = multicolor ? NSColor(Theme.accent) : NSColor.selectedContentBackgroundColor
        return contrastWithBlack(highlight) >= contrastWithWhite(highlight) ? Theme.ink : Theme.surface
    }

    static func contrastWithBlack(_ color: NSColor) -> Double { (luminance(color) + 0.05) / 0.05 }
    static func contrastWithWhite(_ color: NSColor) -> Double { 1.05 / (luminance(color) + 0.05) }

    /// WCAG relative luminance, in sRGB.
    static func luminance(_ color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }
}

/// The platform as a fixed-width upper-case tag ("MEET", "ZOOM"); black on the orange recording panel.
struct PlatformTag: View {
    let platform: Platform
    var onDark = false

    var body: some View {
        Text(platform.tag)
            .font(Theme.font(11, .bold))
            .tracking(0.5)
            .lineLimit(1)
            .foregroundStyle(onDark ? Theme.surface : Theme.ink)
            .frame(width: 58, height: 26)
            .background(onDark ? Theme.ink : Theme.surface)
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.regular))
            .help(platform.displayName)
            .accessibilityLabel(platform.displayName)
    }
}

/// The ">" at the end of a row that opens something. Black: orange text on white breaks the palette rule.
struct RowChevron: View {
    var body: some View {
        Text(">").font(Theme.font(16, .bold)).foregroundStyle(Theme.ink).accessibilityHidden(true)
    }
}

struct StatusBadge: View {
    let meeting: Meeting
    /// Selected sidebar rows: red and grey marks turn black, since red (2.1:1) and grey (2.4:1) don't read on orange.
    @Environment(\.backgroundProminence) private var prominence
    private var onSelection: Bool { prominence == .increased }

    var body: some View {
        switch meeting.status {
        case .recording:
            // Red, as before: the recording marker is one of the allowed red uses.
            Image(systemName: "record.circle.fill").foregroundStyle(onSelection ? Theme.ink : Theme.Color.error).help("Recording")
        case .transcribing:
            ProgressView().controlSize(.small).help("Transcribing")
        case .summarizing:
            ProgressView().controlSize(.small).help("Writing summary")
        case .failed:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.ink).help(meeting.error ?? "Failed")
        case .done:
            if meeting.error != nil {
                Image(systemName: "exclamationmark.circle").foregroundStyle(onSelection ? Theme.ink : Theme.muted).help(meeting.error ?? "")
            }
        }
    }
}

/// Icon in a bordered square, a bold capital title and an optional line.
struct EmptyState: View {
    let title: String
    let systemImage: String
    var detail: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 52, height: 52)
                .brutalistPanel(border: Theme.Border.regular, shadow: Theme.Shadow.small, padding: 0)
            Text(title).font(Theme.heading(17)).textCase(.uppercase).foregroundStyle(Theme.ink)
            if let detail {
                Text(detail).font(Theme.font(13)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center).frame(maxWidth: 280)
            }
        }
        .padding()
    }
}
