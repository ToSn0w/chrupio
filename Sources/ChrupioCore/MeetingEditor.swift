import Foundation

/// What editing asks the rest of the app.
@MainActor
public protocol MeetingEditorEnvironment: AnyObject {
    /// Recording, transcribing, diarizing, summarizing or having its audio compressed.
    func isBusy(_ id: UUID) -> Bool
    /// A reported or typed name in the project roster's spelling.
    func canonicalName(_ name: String) -> String
    /// Learns the voice of a speaker the user named, off the main thread.
    func learnAssignment(_ edit: MeetingEdit, before: Meeting)
    func delete(_ meeting: Meeting)
}

/// Edits from the meeting window, the summary view and `chrupio-mcp`: each is applied to the meeting in memory and
/// saved at once, so a later save can't undo it. Naming a speaker waits for a running diarization and rewrites the
/// summary; merging folds a fragment into its neighbour.
@MainActor
public final class MeetingEditor {
    private let library: MeetingLibrary
    private let summaries: SummaryScheduler
    private let finisher: TranscriptFinisher
    public weak var environment: MeetingEditorEnvironment?

    public init(library: MeetingLibrary, summaries: SummaryScheduler, finisher: TranscriptFinisher) {
        self.library = library
        self.summaries = summaries
        self.finisher = finisher
    }

    public func rename(_ meetingID: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        library.update(meetingID) { $0.title = trimmed }
    }

    public func dismissError(_ meetingID: UUID) { library.update(meetingID) { $0.error = nil; $0.summaryError = nil } }

    /// Ticks or reopens an action item from the summary view.
    public func setActionItem(_ meetingID: UUID, number: Int, done: Bool) {
        _ = try? apply(.setActionItem(item: String(number), done: done), to: meetingID)
    }

    /// The notes the user types in the meeting window; empty text clears them.
    public func setTypedNotes(_ meetingID: UUID, _ text: String) {
        let notes = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        guard library.meeting(meetingID)?.typedNotes != notes else { return }
        library.update(meetingID) { $0.typedNotes = notes }
    }

    public func removeNote(_ meetingID: UUID, noteID: UUID) {
        library.update(meetingID) { meeting in
            meeting.notes?.removeAll { $0.id == noteID }
            if meeting.notes?.isEmpty == true { meeting.notes = nil }
        }
    }

    /// Applies an edit to the in-memory meeting and saves it, so a later save can't undo it.
    @discardableResult
    public func apply(_ edit: MeetingEdit, to meetingID: UUID) throws -> String {
        guard let index = library.index(of: meetingID) else {
            throw MeetingEdit.Failure.invalid("No meeting with id \(meetingID.uuidString).")
        }
        let title = library.meetings[index].title
        if case .setSummary = edit, library.phases[meetingID]?.isSummarizing == true {
            throw MeetingEdit.Failure.invalid("\"\(title)\" is being summarized right now; try again when it is done.")
        }
        var edit = edit
        if case .assignSpeaker(let speaker, let name) = edit {
            let canonical = environment?.canonicalName(name) ?? PersonName.stripMarkers(name)
            edit = .assignSpeaker(speaker: speaker, name: canonical)
            // The diarizer is relabelling the lines; the name is given on its lines when it finishes.
            if library.phases[meetingID] == .diarizing {
                finisher.diarizationEdits.record(edit, for: meetingID)
                return "\"\(title)\" is still telling voices apart; \(speaker) will be named \(canonical) when it is done."
            }
        }
        let before = library.meetings[index]
        var meeting = before
        let message = try edit.apply(to: &meeting)
        library.meetings[index] = meeting
        guard library.persistNow(meeting) else { throw MeetingEdit.Failure.invalid("Chrupio couldn't save the change; the disk may be full.") }
        if case .assignSpeaker = edit {
            environment?.learnAssignment(edit, before: before)
            // A running summary read the old labels; it is redone when it lands.
            summaries.namesChanged(meetingID)
            return message + " Rewriting the summary."
        }
        return message
    }

    /// Edits sent by `chrupio-mcp` through the local API.
    public func applyRemoteEdit(_ request: LocalAPI.EditRequest) -> (status: Int, response: LocalAPI.EditResponse) {
        guard library.meeting(request.id) != nil else {
            return (404, LocalAPI.EditResponse(ok: false, message: "Chrupio has no meeting with id \(request.id.uuidString)."))
        }
        do {
            return (200, LocalAPI.EditResponse(ok: true, message: try apply(request.edit, to: request.id)))
        } catch {
            return (422, LocalAPI.EditResponse(ok: false, message: error.localizedDescription))
        }
    }

    /// Folds `sourceID` into `targetID` (transcripts by time, attendees, notes and audio), deletes the source and
    /// writes the target's summary again.
    public func merge(_ sourceID: UUID, into targetID: UUID) {
        guard let environment, sourceID != targetID, !environment.isBusy(sourceID), !environment.isBusy(targetID),
              let source = library.meeting(sourceID), let target = library.meeting(targetID) else { return }
        // Both on disk as they are in memory, so the audio moves next to the transcript it belongs to.
        guard library.persistNow(source), library.persistNow(target) else {
            library.lastError = "Couldn't merge \"\(source.title)\": the meetings could not be saved first."
            return
        }
        let (merged, targetShift, sourceShift) = MeetingMerge.merged(source, into: target)
        do {
            try library.store.moveAudio(from: sourceID, into: targetID, targetShift: targetShift, sourceShift: sourceShift)
        } catch {
            library.lastError = "Couldn't merge \"\(source.title)\": \(error.localizedDescription)"
            return
        }
        library.update(targetID) { $0 = merged }
        CoreLog.coordinator.info("merged \(sourceID, privacy: .public) into \(targetID, privacy: .public)")
        environment.delete(source)
        summaries.summarize(targetID, force: true)
    }
}
