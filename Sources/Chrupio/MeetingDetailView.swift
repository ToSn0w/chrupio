import AppKit
import ChrupioCore
import SwiftUI
import UniformTypeIdentifiers

struct MeetingDetailView: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    /// The main window's Claude Code status; read only, never refreshed from here.
    @Environment(ClaudeCodeIntegration.self) private var integration: ClaudeCodeIntegration?
    let meeting: Meeting

    enum Tab: String, CaseIterable { case summary = "Summary", transcript = "Transcript" }

    @State private var tab: Tab

    /// `tab` is the tab shown first; snapshots open the transcript.
    init(meeting: Meeting, tab: Tab = .summary) {
        self.meeting = meeting
        _tab = State(initialValue: tab)
    }
    @State private var title = ""
    @FocusState private var titleFocused: Bool
    @State private var confirmDelete = false
    @State private var copied = false
    @State private var followUpCopied = false
    @State private var followUpError: String?
    @State private var exportError: String?
    /// The transcript line whose speaker picker is open.
    @State private var picking: UUID?

    private var isRecording: Bool { coordinator.recording?.meetingID == meeting.id }
    private var claudeOn: Bool { AppSettings.shared.claudeSummaries }
    /// Naming a voice relabels the transcript and rewrites the summary; not while it is still being written.
    private var canNameSpeakers: Bool {
        !isRecording && coordinator.pendingChunks[meeting.id] == nil && [.done, .failed, .summarizing].contains(meeting.status)
    }
    private var isBusy: Bool { coordinator.summarizing.contains(meeting.id) || coordinator.pendingChunks[meeting.id] != nil }

    var body: some View {
        // Header inside the scroll view: its wrapped notes, measured at a narrow width, otherwise made SwiftUI
        // size the window content ~2000 pt tall, and the window showed only the bottom of it.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                    .padding(.bottom, 16)
                if MeetingExporter.isExportable(meeting), [.connected, .partial].contains(integration?.state) {
                    ClaudeReferenceBar(id: meeting.id)
                        .id(meeting.id)
                        .frame(maxWidth: 1100, alignment: .leading)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 16)
                }
                SegmentedSwitch(selection: $tab, options: Tab.allCases.map { ($0, $0.rawValue) })
                    .frame(width: 300)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 14)
                HStack(alignment: .top, spacing: 22) {
                    Group {
                        switch tab {
                        case .summary: summary
                        case .transcript:
                            TranscriptView(meeting: meeting, isLive: isRecording, picking: $picking,
                                           candidates: { coordinator.speakerCandidates(for: meeting) },
                                           assign: canNameSpeakers ? { speaker, name in
                                               coordinator.assignSpeaker(meeting.id, speaker: speaker, name: name)
                                           } : nil)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .brutalistPanel(padding: 24)
                    VStack(alignment: .leading, spacing: 18) {
                        if let notes = meeting.notes, !notes.isEmpty { notesSection(notes) }
                        TypedNotesEditor(meeting: meeting, isLive: isRecording)
                            .id(meeting.id)
                    }
                    .frame(width: 250)
                }
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(Theme.body)
        .foregroundStyle(Theme.ink)
        .background(Theme.surface)
        .onAppear {
            title = meeting.title
            if meeting.summary == nil { tab = .transcript }
        }
        // Don't replace what the user is typing when Claude Code renames the meeting.
        .onChange(of: meeting.title) { if !titleFocused { title = meeting.title } }
        // Only the first summary switches tabs; a rewrite after naming a speaker leaves the transcript open.
        .onChange(of: meeting.summary == nil) { _, missing in if !missing { tab = .summary } }
        .toolbar { toolbar }
        .confirmationDialog("Delete “\(meeting.title)”?", isPresented: $confirmDelete) {
            Button("Delete meeting, transcript and audio", role: .destructive) { coordinator.delete(meeting) }
        } message: {
            Text("This can't be undone.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(Theme.font(26, .bold))
                .foregroundStyle(Theme.ink)
                .focused($titleFocused)
                .onSubmit { coordinator.rename(meeting.id, to: title) }
                .onChange(of: titleFocused) { if !titleFocused, title != meeting.title { coordinator.rename(meeting.id, to: title) } }
            HStack(spacing: 14) {
                Label(meeting.platform.displayName, systemImage: "video")
                Label(meeting.startedAt.shown(date: .abbreviated, time: .shortened), systemImage: "calendar")
                Label(TranscriptFormatter.durationText(meeting.duration), systemImage: "clock")
                if isRecording {
                    Label("Recording", systemImage: "record.circle.fill").font(Theme.font(13, .bold)).foregroundStyle(Theme.Color.error)
                } else if meeting.status == .transcribing {
                    Label("Transcribing…", systemImage: "text.bubble")
                } else if meeting.status == .summarizing {
                    Label("Writing summary…", systemImage: "sparkles")
                }
            }
            .font(Theme.font(13))
            .foregroundStyle(Theme.muted)
            .monospacedDigit()
            if !meeting.attendees.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(meeting.attendees, id: \.self) { name in
                        Text(name + (name == meeting.selfName ? " (you)" : ""))
                            .font(Theme.font(12, .bold))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(name == meeting.selfName ? Theme.accent : Theme.surface)
                            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.regular))
                    }
                }
            }
            if let error = meeting.error {
                NoteView(text: error, kind: meeting.status == .failed ? .error : .warning) {
                    coordinator.dismissError(meeting.id)
                }
                .padding(.top, 4)
            }
            if let hint = namesHint {
                NoteView(text: hint).padding(.top, 4)
            }
            if meeting.fragment == true, meeting.summary == nil, !isRecording {
                fragmentNote.padding(.top, 4)
            }
            if let followUpError {
                NoteView(text: "Couldn't draft the follow-up: \(followUpError)", kind: .warning) { self.followUpError = nil }
                    .padding(.top, 4)
            }
            if let exportError {
                NoteView(text: "Couldn't save the transcript: \(exportError)", kind: .error) { self.exportError = nil }
                    .padding(.top, 4)
            }
        }
    }

    /// A call too short to summarize: merge it into the call next to it, or delete it.
    private var fragmentNote: some View {
        let neighbours = coordinator.mergeNeighbours(of: meeting)
        let busy = coordinator.isBusy(meeting.id)
        return VStack(alignment: .leading, spacing: 10) {
            NoteView(text: "This looks like a fragment (under a minute or fewer than 3 transcript lines), so no summary was written. "
                + "Merge it into the call next to it, or delete it.")
            HStack(spacing: 8) {
                if let previous = neighbours.previous {
                    Button("Merge into previous meeting") { coordinator.merge(meeting.id, into: previous.id) }
                        .help("Into “\(previous.title)”, \(previous.startedAt.shown(date: .omitted, time: .shortened))")
                        .disabled(busy || coordinator.isBusy(previous.id))
                }
                if let next = neighbours.next {
                    Button("Merge into next meeting") { coordinator.merge(meeting.id, into: next.id) }
                        .help("Into “\(next.title)”, \(next.startedAt.shown(date: .omitted, time: .shortened))")
                        .disabled(busy || coordinator.isBusy(next.id))
                }
                Button("Delete…", role: .destructive) { confirmDelete = true }
                    .disabled(busy)
            }
            .buttonStyle(BrutalistButtonStyle(compact: true))
        }
    }

    /// Why remote voices have numbers instead of names, when nothing named anyone during the call.
    private var namesHint: String? {
        guard meeting.status == .done, meeting.speakerEvents.isEmpty,
              meeting.segments.contains(where: { !$0.speaker.isMe }) else { return nil }
        switch meeting.platform {
        case .meet, .teams, .slack:
            return "Nobody was named while this call ran, so voices are numbered. Keep the Chrupio extension enabled in Chrome during calls to get names."
        case .zoom:
            return "Nobody was named while this call ran, so voices are numbered. Allow Accessibility for Chrupio so it can see who Zoom marks as talking."
        case .other:
            return nil
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 20) {
            summaryBody
        }
    }

    /// Notes Claude Code (or another tool) added through chrupio-mcp: orange cards in the right column.
    private func notesSection(_ notes: [MeetingNote]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notes").sectionLabel()
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text("\(note.author) · \(note.createdAt.shown(date: .abbreviated, time: .shortened))")
                            .font(Theme.font(11, .bold))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button { coordinator.removeNote(meeting.id, noteID: note.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.ink)
                            .help("Remove note")
                            .accessibilityLabel("Remove note")
                    }
                    MarkdownView(markdown: note.text, onAccent: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .tint(Theme.ink)
                .brutalistPanel(fill: Theme.accent, border: Theme.Border.heavy, shadow: Theme.Shadow.large, padding: 12)
                // Border lines up with the notes editor's; the hard shadow hangs past the column.
                .padding(.trailing, -Theme.Shadow.large)
            }
        }
    }

    private var summaryBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pending = pendingShown {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(claudeOn ? "Summary pending: \(pending.reason) Retrying at \(pending.nextAttempt.shown(date: .omitted, time: .shortened))."
                                   : "Claude summaries are off in Settings.",
                          systemImage: "clock.arrow.circlepath")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Retry now") { coordinator.summarize(meeting.id, force: true) }
                        .buttonStyle(BrutalistButtonStyle(compact: true))
                        .disabled(isBusy || !claudeOn)
                        .help(claudeOn ? "" : "Claude summaries are off in Settings.")
                }
            }
            unnamedSpeakersNote
            summaryContent
        }
    }

    /// The failed summary's retry, shown above the summary unless one is being written now.
    private var pendingShown: SummaryPending? {
        coordinator.summarizing.contains(meeting.id) ? nil : meeting.summaryPending
    }

    /// Action items left "Unassigned" because voices had no names: opens the picker on the first unnamed voice.
    @ViewBuilder
    private var unnamedSpeakersNote: some View {
        let unnamed = meeting.unnamedSpeakersBlockingOwners
        if !unnamed.isEmpty, canNameSpeakers {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("\(unnamed.count) unnamed speaker\(unnamed.count == 1 ? "" : "s") — name them to assign action items",
                      systemImage: "person.crop.circle.badge.questionmark")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button("Name \(unnamed[0])") {
                    tab = .transcript
                    let line = TranscriptFormatter.grouped(meeting.segments).first { $0.speaker == .remote(unnamed[0]) }
                    // After the tab switch, so the popover has a label to attach to.
                    Task { @MainActor in picking = line?.id }
                }
                .buttonStyle(BrutalistButtonStyle(compact: true))
                .help("Say who \(unnamed[0]) is; the summary is rewritten with the name")
            }
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        if let summary = meeting.summary {
            VStack(alignment: .leading, spacing: 12) {
                MarkdownView(markdown: summary.markdown, onToggle: isBusy ? nil : { number, done in
                    coordinator.setActionItem(meeting.id, number: number, done: done)
                })
                Text("Written by \(ClaudeSummarizer.attribution(model: summary.model)) · \(summary.createdAt.shown(date: .abbreviated, time: .shortened))")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.faint)
                if let reason = summary.fallbackReason {
                    Text(reason)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.faint)
                }
                ForEach(summary.warnings ?? [], id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.muted)
                }
            }
        } else if coordinator.summarizing.contains(meeting.id) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Writing the summary with \(ClaudeSummarizer.displayName(model: ClaudeSummarizer.defaultModel))…").foregroundStyle(Theme.muted)
            }
        } else if coordinator.postCallHold.isHolding(meeting.id) || isRecording || meeting.status == .transcribing {
            // Off with a retry pending: the line above already says summaries are off.
            if !claudeOn && pendingShown != nil {
                EmptyView()
            } else {
                Text(!claudeOn ? "Claude summaries are off in Settings."
                     : coordinator.postCallHold.isHolding(meeting.id) ? "The summary will be written when the current call ends."
                     : "The summary will appear here after the meeting ends.").foregroundStyle(Theme.muted)
            }
        } else if meeting.segments.isEmpty {
            Text("No speech was transcribed for this meeting.").foregroundStyle(Theme.muted)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("No summary yet.").foregroundStyle(Theme.muted)
                Button("Summarize") { coordinator.summarize(meeting.id, force: true) }
                    .buttonStyle(BrutalistButtonStyle(compact: true))
                    .disabled(!claudeOn)
                    .help(claudeOn ? "" : "Claude summaries are off in Settings.")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                coordinator.summarize(meeting.id, force: true)
            } label: {
                Label(meeting.summary == nil ? "Summarize" : "Regenerate summary", systemImage: "sparkles")
            }
            .disabled(!claudeOn || isRecording || isBusy || meeting.segments.isEmpty)
            .help(claudeOn ? (meeting.summary == nil ? "Summarize" : "Regenerate summary") : "Claude summaries are off in Settings.")

            Menu {
                let current = SummaryTemplate.resolved(for: meeting)
                ForEach(SummaryTemplate.allCases) { template in
                    Button {
                        coordinator.setSummaryTemplate(meeting.id, template)
                    } label: {
                        if template == current { Label(template.displayName, systemImage: "checkmark") } else { Text(template.displayName) }
                    }
                }
            } label: {
                Label("Summary template", systemImage: "list.bullet.rectangle")
            }
            .disabled(!claudeOn || isRecording || isBusy || meeting.segments.isEmpty)
            .help("Summary template: \(SummaryTemplate.resolved(for: meeting).displayName). Picking one rewrites the summary.")

            Button {
                followUpError = nil
                coordinator.draftFollowUp(meeting.id) { error in
                    followUpError = error
                    guard error == nil else { return }
                    followUpCopied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); followUpCopied = false }
                }
            } label: {
                Label("Draft follow-up", systemImage: followUpCopied ? "checkmark" : coordinator.draftingFollowUp.contains(meeting.id) ? "hourglass" : "envelope")
            }
            .disabled(!claudeOn || isRecording || meeting.segments.isEmpty || coordinator.draftingFollowUp.contains(meeting.id))
            .help(claudeOn ? "Draft a recap message for Slack or email and copy it" : "Claude summaries are off in Settings.")

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(TranscriptFormatter.markdown(meeting), forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Label("Copy as Markdown", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .help("Copy notes and transcript as Markdown")

            Menu {
                Button("Export as Markdown…") { export() }
                Button("Retranscribe audio") { coordinator.retranscribe(meeting.id) }
                    .disabled(isRecording || isBusy || !coordinator.hasAudio(meeting.id))
                Button("Show audio in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([coordinator.audioFolder(for: meeting.id)])
                }
                .disabled(!coordinator.hasAudio(meeting.id))
                if let url = SafeLink.url(meeting.url) {
                    Button("Open meeting link") { NSWorkspace.shared.open(url) }
                }
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = true }
                    .disabled(coordinator.isBusy(meeting.id))
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(meeting.startedAt.formatted(.iso8601.year().month().day())) \(meeting.title).md"
            .replacingOccurrences(of: "/", with: "-")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FilePermissions.writePrivately(Data(TranscriptFormatter.markdown(meeting).utf8), to: url)
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }
}

struct TranscriptView: View {
    let meeting: Meeting
    let isLive: Bool
    /// The line whose speaker picker is open.
    @Binding var picking: UUID?
    /// People a "Speaker N" can be named as; read when the picker opens.
    var candidates: () -> [String] = { [] }
    /// Names a voice; nil while the meeting is being processed, which leaves labels plain.
    var assign: ((_ speaker: String, _ name: String) -> Void)?

    var body: some View {
        let groups = TranscriptFormatter.grouped(meeting.segments)
        VStack(alignment: .leading, spacing: 14) {
            if groups.isEmpty {
                Text(isLive ? "Recording. The transcript is written when the call ends."
                            : "No transcript.")
                    .foregroundStyle(Theme.muted)
            }
            ForEach(groups) { segment in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(TranscriptFormatter.timestamp(segment.start))
                        .font(Theme.caption.monospacedDigit())
                        .foregroundStyle(Theme.faint)
                        .frame(width: 52, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        speakerLabel(segment)
                        Text(segment.text)
                            .font(Theme.font(14))
                            .lineSpacing(3)
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if isLive && !groups.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Listening…").font(Theme.caption).foregroundStyle(Theme.muted)
                }
                .padding(.leading, 64)
            }
        }
    }
}

extension TranscriptView {
    @ViewBuilder
    private func speakerLabel(_ segment: TranscriptSegment) -> some View {
        let text = speakerName(segment)
        if let assign, case .remote(let label?) = segment.speaker {
            Button { picking = segment.id } label: {
                HStack(spacing: 3) {
                    text
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.muted)
                }
            }
            .buttonStyle(.plain)
            .help(Meeting.isUnnamedSpeaker(label) ? "Say who \(label) is" : "Not \(label)? Pick who it is")
            .popover(isPresented: Binding(get: { picking == segment.id }, set: { if !$0 { picking = nil } }), arrowEdge: .bottom) {
                SpeakerPicker(speaker: label, candidates: candidates()) { name in
                    picking = nil
                    assign(label, name)
                }
            }
        } else {
            text
        }
    }

    /// Bold black name; the user's own lines get an orange chip. The words are the same as before.
    @ViewBuilder
    private func speakerName(_ segment: TranscriptSegment) -> some View {
        if segment.speaker.isMe {
            Text(meeting.selfName.map { "\($0) (you)" } ?? "You")
                .tagChip(.accent, size: 11, uppercase: false)
        } else {
            Text(segment.speaker.label)
                .font(Theme.font(12, .bold))
                .foregroundStyle(Theme.ink)
        }
    }
}

/// Picks who a voice is: expected people, attendees and the project roster, filtered as you type; Return takes
/// the first match, or the typed name when nothing matches.
struct SpeakerPicker: View {
    let speaker: String
    let candidates: [String]
    let choose: (String) -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    private var matches: [String] {
        let key = PersonName.key(query.trimmingCharacters(in: .whitespaces))
        guard !key.isEmpty else { return candidates }
        return candidates.filter { PersonName.key($0).contains(key) }
    }

    private var typed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Who is \(speaker)?").font(Theme.font(12, .bold)).foregroundStyle(Theme.muted)
            TextField("Search or type a name", text: $query)
                .textFieldStyle(FieldStyle())
                .focused($focused)
                .onSubmit {
                    if let first = matches.first { choose(first) } else if !typed.isEmpty { choose(typed) }
                }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches, id: \.self) { name in
                        Button { choose(name) } label: {
                            Text(name).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if matches.isEmpty, !typed.isEmpty {
                        Button { choose(typed) } label: {
                            Text("Use “\(typed)”").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 220)
            Text("Names every line of \(speaker), remembers the voice and rewrites the summary.")
                .font(Theme.caption).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 260)
        .onAppear { focused = true }
    }
}

/// Wraps children onto new lines when they don't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// The user's own notes, typed during or after the call and saved a second after typing stops. The summary
/// follows them as its outline.
private struct TypedNotesEditor: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    let meeting: Meeting
    let isLive: Bool
    @State private var draft = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your notes").font(Theme.label).textCase(.uppercase)
            Text(isLive ? "The summary follows these" : "Used as the outline when the summary is written")
                .font(Theme.font(11))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $draft)
                .font(Theme.font(13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: isLive ? 160 : 120, maxHeight: 320)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Points to cover, decisions, who does what…")
                            .font(Theme.font(13))
                            .foregroundStyle(Theme.faint)
                            .padding(.horizontal, 5)
                            .allowsHitTesting(false)
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .brutalistPanel(border: Theme.Border.heavy, shadow: 0, padding: 12)
        .onAppear {
            draft = meeting.typedNotes ?? ""
            loaded = true
        }
        .task(id: draft) {
            guard loaded else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            coordinator.setTypedNotes(meeting.id, draft)
        }
        .onDisappear { if loaded { coordinator.setTypedNotes(meeting.id, draft) } }
    }
}

/// The meeting's Claude Code mention, ready to paste into a Claude Code prompt.
struct ClaudeReferenceBar: View {
    let id: UUID

    var body: some View {
        let mention = MeetingResource.mention(for: id)
        HStack(spacing: 12) {
            Text("In Claude Code:").font(Theme.label).textCase(.uppercase).foregroundStyle(Theme.surface)
                .fixedSize()
            Text(mention)
                .font(Theme.font(12))
                .foregroundStyle(Theme.surface)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            CopyButton(text: mention, help: "Paste into Claude Code to attach this meeting's summary")
                .accessibilityLabel("Copy Claude Code reference")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.ink)
    }
}
