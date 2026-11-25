import Foundation
import Observation

/// Writes a meeting's summary; `ClaudeSummarizer` in the app, a fake in tests.
public protocol MeetingSummarizing: Sendable {
    func summarize(_ meeting: Meeting) async throws -> MeetingSummary
}

extension ClaudeSummarizer: MeetingSummarizing {}

/// What the summary scheduler asks the rest of the app.
@MainActor
public protocol SummarySchedulerEnvironment: AnyObject {
    /// A call is being recorded; summaries wait for it to end.
    var isRecording: Bool { get }
    /// "Write summaries with Claude" is on. Off: nothing is sent to Anthropic, not even a retry.
    var claudeEnabled: Bool { get }
    /// The meeting's transcript is still being written (recorded now, chunks queued, or finishing).
    func isTranscriptOpen(_ id: UUID) -> Bool
    /// Recording, transcribing, diarizing or summarizing.
    func isBusy(_ id: UUID) -> Bool
    /// The project roster's expected attendees for a meeting with this title.
    func expectedAttendees(for title: String) -> [String]?
    /// A summarizer set up for this meeting (project context, template, known people, timeout).
    func makeSummarizer(for meeting: Meeting) -> MeetingSummarizing
    /// Summaries started or ended: App Nap may need holding off or may be allowed again.
    func activityChanged()
}

/// Summarizes meetings once their transcript is final: fragments are flagged instead (unless forced), summaries
/// asked for during a call wait for it to end, a rewrite keeps ticked action items and adopts the suggested title
/// and attendees, a retryable failure is retried on a backoff, and a summary asked for while one is running is
/// redone when it lands.
@MainActor
@Observable
public final class SummaryScheduler {
    /// Summaries waiting for the current call to end.
    public private(set) var postCallHold = PostCallHold()

    @ObservationIgnored private let library: MeetingLibrary
    @ObservationIgnored public weak var environment: SummarySchedulerEnvironment?
    @ObservationIgnored public weak var notifier: MeetingNotifying?
    /// Last check for failed summaries whose retry is due; distantPast retries every pending one at launch.
    @ObservationIgnored private var lastRetryCheck = Date.distantPast

    public init(library: MeetingLibrary) {
        self.library = library
    }

    public var summarizing: Set<UUID> { library.phases.summarizing }

    /// Writes the meeting's summary. Without `force` (every automatic path) a fragment is only flagged; the user's
    /// own "Summarize" passes `force`.
    public func summarize(_ meetingID: UUID, force: Bool = false) {
        guard let environment, environment.claudeEnabled else { return }
        let phase = library.phases[meetingID]
        // Never summarize a transcript that is still being written.
        guard phase?.isSummarizing != true, phase != .diarizing, !environment.isTranscriptOpen(meetingID),
              var meeting = library.meeting(meetingID) else { return }
        if !force, MeetingFragment.isFragment(meeting) {
            CoreLog.coordinator.info("\(meetingID, privacy: .public) is a fragment; no summary")
            if meeting.fragment != true { library.update(meetingID) { $0.fragment = true; $0.summaryPending = nil } }
            return
        }
        if postCallHold.holdSummary(meetingID, recording: environment.isRecording) {
            CoreLog.coordinator.info("summary of \(meetingID, privacy: .public) waits for the call to end")
            return
        }
        // Meetings recorded before expected attendees existed get them now, for owner checks and the prompt.
        if meeting.expectedAttendees == nil, let expected = environment.expectedAttendees(for: meeting.title), !expected.isEmpty {
            meeting.expectedAttendees = expected
            library.update(meetingID) { $0.expectedAttendees = expected }
        }
        library.phases.send(.summaryStarted, to: meetingID)
        let previousError: String? = if case .summarizing(_, let error) = library.phases[meetingID] { error } else { nil }
        environment.activityChanged()
        library.update(meetingID) { $0.status = .summarizing }
        let summarizer = environment.makeSummarizer(for: meeting)
        Task {
            let outcome: MeetingPhase.Event
            do {
                var summary = try await summarizer.summarize(meeting)
                library.update(meetingID) {
                    // A rewrite keeps the ticks the user already made.
                    if let old = $0.summary?.markdown { summary.markdown = ActionItem.carryingDone(from: old, into: summary.markdown) }
                    $0.summary = summary
                    $0.status = .done
                    // Only a title the app made up is replaced; attendees only when the call reported none.
                    $0.adoptSuggestedTitle(summary.suggestedTitle)
                    $0.fillAttendeesFromSpeakers()
                    // Transcription and audio warnings stay; only the earlier summary failure is resolved, including one
                    // saved before summaryError existed.
                    if $0.error == previousError || $0.error == $0.summaryPending?.reason || $0.error == $0.summaryError
                        || ($0.summaryError == nil && ClaudeSummarizerError.isSummaryFailure($0.error)) { $0.error = nil }
                    $0.summaryPending = nil
                    $0.summaryError = nil
                }
                notifier?.post(title: "Meeting notes ready", body: meeting.title)
                outcome = .summarySucceeded
            } catch is ClaudeSummariesOff {
                // Turned off mid-summary: the partial result is dropped, and the meeting keeps the summary, error and
                // retry it had before. Not a failure, so nothing is notified or retried.
                CoreLog.coordinator.info("summary of \(meetingID, privacy: .public) stopped: Claude summaries are off")
                library.update(meetingID) { $0.status = .done }
                outcome = .summaryStopped
            } catch {
                let message = error.localizedDescription
                let retry = SummaryPending.isRetryable(error)
                let pending = SummaryPending.failed(meeting.summaryPending, reason: message)
                outcome = .summaryFailed(reason: message)
                library.update(meetingID) {
                    $0.status = .done
                    $0.error = message
                    $0.summaryError = message
                    // A final failure also ends any retry left from an earlier one.
                    $0.summaryPending = retry ? SummaryPending.failed($0.summaryPending, reason: message) : nil
                }
                // Only the first failure notifies; the retries are shown on the meeting.
                if meeting.summaryPending == nil || !retry {
                    let body = retry ? message + " Retrying at \(pending.nextAttempt.formatted(date: .omitted, time: .shortened))." : message
                    notifier?.post(title: "Couldn't write the summary", body: body)
                }
            }
            let rerun = if case .summarizing(true, _) = library.phases[meetingID] { true } else { false }
            library.phases.send(outcome, to: meetingID)
            if rerun { summarize(meetingID) }
        }
    }

    /// The speaker names changed: a running summary read the old labels and is redone when it lands; otherwise
    /// the summary is written again now.
    public func namesChanged(_ meetingID: UUID) {
        if library.phases[meetingID]?.isSummarizing == true { library.phases.send(.rerunRequested, to: meetingID) } else { summarize(meetingID) }
    }

    /// Picks the summary template by hand and writes the summary with it.
    public func setTemplate(_ meetingID: UUID, _ template: SummaryTemplate) {
        library.update(meetingID) { $0.summaryTemplate = template.rawValue }
        summarize(meetingID, force: true)
    }

    /// Summarizes again, every 30 s, the meetings whose failed summary is due for a retry; at launch, all of them.
    public func retryPendingIfDue(now: Date) {
        // Off doesn't move lastRetryCheck. Turned back on, only the retries already due run; if summaries were off
        // since launch, the launch check is still unused, so every pending one runs.
        guard now.timeIntervalSince(lastRetryCheck) >= 30, let environment, environment.claudeEnabled else { return }
        let launch = lastRetryCheck == .distantPast
        lastRetryCheck = now
        for id in SummaryPending.due(library.meetings, now: now, launch: launch) where !environment.isBusy(id) {
            CoreLog.coordinator.info("retrying the summary of \(id, privacy: .public)")
            summarize(id)
        }
    }

    /// The call ended: the summaries held during it start, in the order asked.
    public func releaseHeld() {
        postCallHold.release().forEach { summarize($0) }
    }

    /// A deleted meeting is never summarized.
    public func forget(_ meetingID: UUID) { postCallHold.forget(meetingID) }
}
