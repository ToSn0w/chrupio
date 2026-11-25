import Foundation
@testable import ChrupioCore
import XCTest

/// Answers with scripted results, in order; once out of script, a summary titled "Notes". `gate` holds a call
/// until the test opens it.
final class FakeSummarizer: MeetingSummarizing, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<MeetingSummary, Error>] = []
    private(set) var calls: [Meeting] = []
    var gate: CheckedContinuation<Void, Never>?
    var holds = false

    func script(_ result: Result<MeetingSummary, Error>) { lock.withLock { results.append(result) } }
    var callCount: Int { lock.withLock { calls.count } }

    func summarize(_ meeting: Meeting) async throws -> MeetingSummary {
        let hold = lock.withLock { calls.append(meeting); return holds }
        if hold { await withCheckedContinuation { continuation in lock.withLock { gate = continuation } } }
        let result = lock.withLock { results.isEmpty ? .success(MeetingSummary(markdown: "Notes", model: "fake")) : results.removeFirst() }
        return try result.get()
    }

    func open() {
        lock.withLock {
            holds = false
            gate?.resume()
            gate = nil
        }
    }

    var isWaiting: Bool { lock.withLock { gate != nil } }
}

@MainActor
final class FakeSummaryEnvironment: SummarySchedulerEnvironment {
    var isRecording = false
    var claudeEnabled = true
    var open: Set<UUID> = []
    var busy: Set<UUID> = []
    var expected: [String]?
    let summarizer = FakeSummarizer()
    private(set) var activityChanges = 0

    func isTranscriptOpen(_ id: UUID) -> Bool { open.contains(id) }
    func isBusy(_ id: UUID) -> Bool { busy.contains(id) }
    func expectedAttendees(for title: String) -> [String]? { expected }
    func makeSummarizer(for meeting: Meeting) -> MeetingSummarizing { summarizer }
    func activityChanged() { activityChanges += 1 }
}

struct FakeSummaryError: LocalizedError {
    var errorDescription: String? { "Claude: session limit" }
}

@MainActor
final class SummarySchedulerTests: XCTestCase {
    private var library: MeetingLibrary!
    private var environment: FakeSummaryEnvironment!
    private var notifier: FakeNotifier!
    private var scheduler: SummaryScheduler!

    override func setUp() async throws {
        library = MeetingLibrary(saver: FakeSaver())
        environment = FakeSummaryEnvironment()
        notifier = FakeNotifier()
        scheduler = SummaryScheduler(library: library)
        scheduler.environment = environment
        scheduler.notifier = notifier
    }

    private func meeting(minutes: Double = 10, lines: Int = 5) -> Meeting {
        let start = Date().addingTimeInterval(-3_600)
        let segments = (0..<lines).map { TranscriptSegment(start: Double($0) * 10, end: Double($0) * 10 + 5, speaker: .me, text: "Line \($0)") }
        let meeting = Meeting(title: "Browser call", platform: .meet, startedAt: start, endedAt: start.addingTimeInterval(minutes * 60),
                              segments: segments, status: .done)
        library.add([meeting])
        return meeting
    }

    private func finished(_ id: UUID) async -> Bool {
        await until { self.library.phases[id] == nil && self.library.meeting(id)?.status == .done }
    }

    func testFragmentIsFlaggedNotSummarizedUnlessForced() async {
        let short = meeting(minutes: 0.5, lines: 2)
        scheduler.summarize(short.id)
        XCTAssertEqual(library.meeting(short.id)?.fragment, true)
        XCTAssertEqual(environment.summarizer.callCount, 0)
        scheduler.summarize(short.id, force: true)
        let done = await finished(short.id)
        XCTAssertTrue(done)
        XCTAssertEqual(library.meeting(short.id)?.summary?.markdown, "Notes")
    }

    func testNothingIsSentToClaudeWhileSummariesAreOff() async {
        environment.claudeEnabled = false
        var call = meeting()
        scheduler.summarize(call.id, force: true)
        await settle()
        XCTAssertEqual(environment.summarizer.callCount, 0)
        XCTAssertNil(library.meeting(call.id)?.summary)

        call.summaryPending = SummaryPending(reason: "x", attempts: 1, nextAttempt: .distantPast)
        library.meetings[library.meetings.count - 1] = call
        scheduler.retryPendingIfDue(now: Date())
        await settle()
        XCTAssertEqual(environment.summarizer.callCount, 0)

        // Turned back on: the launch-style retry still runs, because the off check didn't use it up.
        environment.claudeEnabled = true
        scheduler.retryPendingIfDue(now: Date())
        let done = await until { self.library.meeting(call.id)?.summary != nil }
        XCTAssertTrue(done)
    }

    func testTurningSummariesOffMidRunLeavesNoErrorAndKeepsAnEarlierRetry() async {
        // A fresh meeting: the summarizer stops at its next Claude call because the switch went off meanwhile.
        let fresh = meeting()
        environment.summarizer.holds = true
        environment.summarizer.script(.failure(ClaudeSummariesOff()))
        scheduler.summarize(fresh.id, force: true)
        let started = await until { self.environment.summarizer.isWaiting }
        XCTAssertTrue(started)
        environment.claudeEnabled = false
        environment.summarizer.open()
        let stopped = await finished(fresh.id)
        XCTAssertTrue(stopped)
        let left = library.meeting(fresh.id)
        XCTAssertNil(left?.summary)
        XCTAssertNil(left?.error)
        XCTAssertNil(left?.summaryError)
        XCTAssertNil(left?.summaryPending)
        XCTAssertTrue(notifier.posted.isEmpty)

        // A meeting already waiting for a retry keeps that retry and its error, untouched.
        environment.claudeEnabled = true
        let retrying = meeting()
        let pending = SummaryPending(reason: "Claude Code hit its usage limit: x", attempts: 2, nextAttempt: Date().addingTimeInterval(600))
        library.update(retrying.id) {
            $0.summaryPending = pending
            $0.error = pending.reason
            $0.summaryError = pending.reason
        }
        environment.summarizer.script(.failure(ClaudeSummariesOff()))
        scheduler.summarize(retrying.id, force: true)
        let done = await until { self.library.meeting(retrying.id)?.status == .done && self.library.phases[retrying.id]?.isSummarizing != true }
        XCTAssertTrue(done)
        let kept = library.meeting(retrying.id)
        XCTAssertNil(kept?.summary)
        XCTAssertEqual(kept?.summaryPending, pending)
        XCTAssertEqual(kept?.error, pending.reason)
        XCTAssertEqual(kept?.summaryError, pending.reason)
        XCTAssertTrue(notifier.posted.isEmpty)
    }

    func testSummaryWaitsWhileTheTranscriptIsOpenOrACallIsRecorded() async {
        let call = meeting()
        environment.open = [call.id]
        scheduler.summarize(call.id)
        XCTAssertNil(library.phases[call.id])
        environment.open = []
        environment.isRecording = true
        scheduler.summarize(call.id)
        XCTAssertTrue(scheduler.postCallHold.isHolding(call.id))
        XCTAssertEqual(environment.summarizer.callCount, 0)
        environment.isRecording = false
        scheduler.releaseHeld()
        let done = await finished(call.id)
        XCTAssertTrue(done)
        XCTAssertEqual(environment.summarizer.callCount, 1)
        XCTAssertFalse(scheduler.postCallHold.isHolding(call.id))
    }

    func testRetryableFailureIsRetriedAndNotifiesOnce() async {
        let call = meeting()
        environment.summarizer.script(.failure(FakeSummaryError()))
        environment.summarizer.script(.failure(FakeSummaryError()))
        scheduler.summarize(call.id)
        var failed = await until { if case .summaryFailed = self.library.phases[call.id] { true } else { false } }
        XCTAssertTrue(failed)
        XCTAssertEqual(library.meeting(call.id)?.summaryPending?.attempts, 1)
        XCTAssertEqual(library.meeting(call.id)?.error, "Claude: session limit")
        // Launch: every pending summary is retried at once.
        scheduler.retryPendingIfDue(now: Date())
        failed = await until { self.library.meeting(call.id)?.summaryPending?.attempts == 2 }
        XCTAssertTrue(failed)
        XCTAssertEqual(notifier.titles.filter { $0 == "Couldn't write the summary" }.count, 1, "only the first failure notifies")
        // Not due yet: nothing runs.
        scheduler.retryPendingIfDue(now: Date().addingTimeInterval(31))
        await settle()
        XCTAssertEqual(environment.summarizer.callCount, 2)
        // Due: the third try succeeds, clearing the error and the pending retry.
        scheduler.retryPendingIfDue(now: Date().addingTimeInterval(7 * 3_600))
        let done = await until { self.library.meeting(call.id)?.summary != nil }
        XCTAssertTrue(done)
        XCTAssertNil(library.meeting(call.id)?.summaryPending)
        XCTAssertNil(library.meeting(call.id)?.error)
        XCTAssertNil(library.phases[call.id])
    }

    func testBusyMeetingIsNotRetried() async {
        var call = meeting()
        call.summaryPending = SummaryPending(reason: "x", attempts: 1, nextAttempt: .distantPast)
        library.meetings[0] = call
        environment.busy = [call.id]
        scheduler.retryPendingIfDue(now: Date())
        XCTAssertEqual(environment.summarizer.callCount, 0)
    }

    func testRenamingDuringASummaryRunsItAgainAfterwards() async {
        let call = meeting()
        environment.summarizer.holds = true
        scheduler.summarize(call.id)
        let waiting = await until { self.environment.summarizer.isWaiting }
        XCTAssertTrue(waiting)
        scheduler.namesChanged(call.id)
        XCTAssertEqual(library.phases[call.id], .summarizing(rerun: true, previousError: nil))
        environment.summarizer.open()
        let twice = await until { self.environment.summarizer.callCount == 2 }
        XCTAssertTrue(twice)
        let done = await finished(call.id)
        XCTAssertTrue(done)
    }

    func testStoppingARegenerateKeepsTheOldSummary() async {
        var call = meeting()
        let old = MeetingSummary(markdown: "## Action items\n- [x] Send the deck (Ann)", model: "fake")
        call.summary = old
        library.meetings[0] = call
        environment.summarizer.holds = true
        environment.summarizer.script(.failure(ClaudeSummariesOff()))
        scheduler.summarize(call.id, force: true)
        let waiting = await until { self.environment.summarizer.isWaiting }
        XCTAssertTrue(waiting)
        environment.claudeEnabled = false
        environment.summarizer.open()
        let done = await finished(call.id)
        XCTAssertTrue(done)
        let kept = library.meeting(call.id)
        XCTAssertEqual(kept?.summary, old)
        XCTAssertNil(kept?.error)
        XCTAssertNil(kept?.summaryPending)
        XCTAssertTrue(notifier.posted.isEmpty)
    }

    func testStoppingASummaryWithARenameRequestedLeavesTheOldSummaryAndRunsNothingMore() async {
        // The rename asked for a rerun, but the switch is off when the stopped summary lands: the rerun doesn't
        // reach Claude and the old summary, with the old names, stays until the user turns summaries on and regenerates.
        var call = meeting()
        let old = MeetingSummary(markdown: "## Summary\nSpeaker 2 ships it.", model: "fake")
        call.summary = old
        library.meetings[0] = call
        environment.summarizer.holds = true
        environment.summarizer.script(.failure(ClaudeSummariesOff()))
        scheduler.summarize(call.id, force: true)
        let waiting = await until { self.environment.summarizer.isWaiting }
        XCTAssertTrue(waiting)
        scheduler.namesChanged(call.id)
        environment.claudeEnabled = false
        environment.summarizer.open()
        let done = await finished(call.id)
        XCTAssertTrue(done)
        await settle()
        XCTAssertEqual(environment.summarizer.callCount, 1)
        XCTAssertEqual(library.meeting(call.id)?.summary, old)
        XCTAssertNil(library.phases[call.id])
        XCTAssertTrue(notifier.posted.isEmpty)
    }

    func testRewriteKeepsTicksAdoptsTitleAndFillsExpectedAttendees() async {
        var call = meeting()
        call.summary = MeetingSummary(markdown: "## Action items\n- [x] Send the deck (Ann)", model: "fake")
        library.meetings[0] = call
        environment.expected = ["Ann", "Bob"]
        var summary = MeetingSummary(markdown: "## Action items\n- [ ] Send the deck (Ann)", model: "fake")
        summary.suggestedTitle = "Deck review"
        environment.summarizer.script(.success(summary))
        scheduler.setTemplate(call.id, .standup)
        let done = await until { self.library.meeting(call.id)?.title == "Deck review" }
        XCTAssertTrue(done)
        let stored = library.meeting(call.id)
        XCTAssertEqual(stored?.summary?.markdown.contains("- [x] Send the deck"), true)
        XCTAssertEqual(stored?.expectedAttendees, ["Ann", "Bob"])
        XCTAssertEqual(stored?.summaryTemplate, SummaryTemplate.standup.rawValue)
        XCTAssertEqual(notifier.titles, ["Meeting notes ready"])
    }

    func testModelErrorEndsTheRetries() async {
        var call = meeting()
        call.summaryPending = SummaryPending(reason: "earlier", attempts: 1, nextAttempt: .distantPast)
        library.meetings[library.meetings.count - 1] = call
        environment.summarizer.script(.failure(ClaudeSummarizerError.modelUnavailable("no such model")))
        scheduler.summarize(call.id)
        let failed = await until { if case .summaryFailed = self.library.phases[call.id] { true } else { false } }
        XCTAssertTrue(failed)
        XCTAssertNil(library.meeting(call.id)?.summaryPending, "a model error isn't retried")
        XCTAssertEqual(library.meeting(call.id)?.error, "Claude Code can't use the summary model: no such model")
        scheduler.retryPendingIfDue(now: Date().addingTimeInterval(7 * 3_600))
        await settle()
        XCTAssertEqual(environment.summarizer.callCount, 1)
    }

    func testRegenerateAfterARestartClearsAFinalSummaryError() async throws {
        let call = meeting()
        environment.summarizer.script(.failure(ClaudeSummarizerError.outdated("unknown option '--tools'")))
        scheduler.summarize(call.id)
        let failed = await until { if case .summaryFailed = self.library.phases[call.id] { true } else { false } }
        XCTAssertTrue(failed)
        let message = try XCTUnwrap(library.meeting(call.id)?.error)

        // Restart: the meeting is read back from disk into a fresh library and scheduler.
        let saved = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(library.meeting(call.id)))
        library = MeetingLibrary(saver: FakeSaver())
        library.add([saved])
        scheduler = SummaryScheduler(library: library)
        scheduler.environment = environment
        XCTAssertEqual(library.meeting(call.id)?.error, message)
        XCTAssertNil(library.meeting(call.id)?.summaryPending)

        scheduler.summarize(call.id, force: true)
        let done = await until { self.library.meeting(call.id)?.summary != nil && self.library.phases[call.id] == nil }
        XCTAssertTrue(done)
        XCTAssertNil(library.meeting(call.id)?.error, "the summary error is gone once a summary is written")
    }

    func testASummaryKeepsATranscriptionWarning() async {
        var call = meeting()
        call.error = "Part of the audio couldn't be transcribed."
        library.meetings[library.meetings.count - 1] = call
        scheduler.summarize(call.id)
        let done = await until { self.library.meeting(call.id)?.summary != nil && self.library.phases[call.id] == nil }
        XCTAssertTrue(done)
        XCTAssertEqual(library.meeting(call.id)?.error, "Part of the audio couldn't be transcribed.")
    }

    /// Meetings that failed before summaryError existed only have the message in `error`.
    func testASuccessfulSummaryClearsASummaryErrorLeftBeforeTheUpgrade() async {
        var call = meeting()
        call.error = "Claude Code could not write the summary: error: unknown option '--safe-mode'"
        library.meetings[library.meetings.count - 1] = call
        scheduler.summarize(call.id, force: true)
        let done = await until { self.library.meeting(call.id)?.summary != nil && self.library.phases[call.id] == nil }
        XCTAssertTrue(done)
        XCTAssertNil(library.meeting(call.id)?.error)
    }

    func testSummaryFailureMessagesAreRecognised() {
        let summaryFailures: [ClaudeSummarizerError] = [.notInstalled, .notLoggedIn, .timedOut, .usageLimit("x"), .launchFailed("x"),
                                                        .failed("x"), .modelUnavailable("x"), .outdated("x")]
        for failure in summaryFailures {
            XCTAssertTrue(ClaudeSummarizerError.isSummaryFailure(failure.localizedDescription), failure.localizedDescription)
        }
        XCTAssertTrue(ClaudeSummarizerError.isSummaryFailure(SummarizerError.emptyTranscript.localizedDescription))
        XCTAssertTrue(ClaudeSummarizerError.isSummaryFailure(SummarizerError.notesWontShrink.localizedDescription))
        XCTAssertFalse(ClaudeSummarizerError.isSummaryFailure("Part of the audio couldn't be transcribed: x Fix it, then use More > Retranscribe audio."))
        XCTAssertFalse(ClaudeSummarizerError.isSummaryFailure("No saved audio for this meeting. Turn on Keep audio in Settings to allow retranscribing."))
        XCTAssertFalse(ClaudeSummarizerError.isSummaryFailure("Claude Code is great"))
    }
}
