import XCTest
@testable import ChrupioCore

final class ClaudeFallbackTests: XCTestCase {
    let meeting: Meeting = {
        var meeting = Meeting(title: "x", platform: .meet)
        meeting.segments = [TranscriptSegment(start: 0, end: 90, speaker: .me, text: "hello")]
        return meeting
    }()

    func testSessionLimitIsRecognised() {
        let stdout = #"{"type":"result","is_error":true,"result":"You've hit your session limit · resets 3pm (Europe/Warsaw)"}"#
        XCTAssertThrowsError(try ClaudeSummarizer.parse(stdout: stdout, stderr: "", status: 1)) {
            XCTAssertEqual($0 as? ClaudeSummarizerError, .usageLimit("You've hit your session limit · resets 3pm (Europe/Warsaw)"))
        }
        XCTAssertThrowsError(try ClaudeSummarizer.parse(stdout: "", stderr: "Claude usage limit reached. Your limit will reset at 5pm.", status: 1)) {
            guard case .usageLimit = $0 as? ClaudeSummarizerError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(ClaudeSummarizerError.usageLimit("x").reason, "session limit")
        XCTAssertEqual(ClaudeSummarizerError.notInstalled.reason, "not installed")
    }

    func testLaunchFailureKeepsTheRealError() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Executable bit set but not a runnable program: the launch fails though the file is there.
        let broken = folder.appendingPathComponent("claude")
        try Data([0xCA, 0xFE, 0x00, 0x01]).write(to: broken)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path)
        do {
            _ = try await ClaudeSummarizer(executable: broken, workingDirectory: folder).summarize(meeting)
            XCTFail("expected an error")
        } catch let error as ClaudeSummarizerError {
            guard case .launchFailed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testTimeoutScalesWithTranscriptLength() {
        XCTAssertEqual(ClaudeSummarizer.timeout(forTranscriptCharacters: 2_000), 300)
        XCTAssertEqual(ClaudeSummarizer.timeout(forTranscriptCharacters: 90_000), 900)
        XCTAssertEqual(ClaudeSummarizer.timeout(forTranscriptCharacters: 10_000_000), 1_800, "capped")
    }

    func testFallbackReasonIsStoredAndOldSummariesDecode() throws {
        var summary = MeetingSummary(markdown: "x", model: "gemma3:4b")
        summary.fallbackReason = "Claude: session limit; local model used"
        let round = try JSONDecoder().decode(MeetingSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(round.fallbackReason, summary.fallbackReason)
        let old = ###"{"markdown":"x","model":"gemma3:4b","createdAt":0}"###
        XCTAssertNil(try JSONDecoder().decode(MeetingSummary.self, from: Data(old.utf8)).fallbackReason)
    }

    func testPendingSummaryBacksOffAndIsKeptInMeetingJSON() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var pending = SummaryPending.failed(nil, reason: "Claude Code is not installed.", now: start)
        XCTAssertEqual(pending.attempts, 1)
        XCTAssertEqual(pending.nextAttempt, start.addingTimeInterval(300))
        let waits = (2...7).map { _ -> TimeInterval in
            pending = SummaryPending.failed(pending, reason: "timed out", now: start)
            return pending.nextAttempt.timeIntervalSince(start)
        }
        XCTAssertEqual(waits, [900, 3_600, 10_800, 21_600, 21_600, 21_600], "capped at 6 hours")
        XCTAssertEqual(pending.reason, "timed out")

        var meeting = Meeting(title: "x", platform: .meet, status: .done)
        meeting.summaryPending = pending
        let round = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        XCTAssertEqual(round.summaryPending, pending)
    }

    func testPendingSummariesDueOnScheduleAndAllAtLaunch() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var late = Meeting(title: "late", platform: .meet), soon = Meeting(title: "soon", platform: .meet)
        let none = Meeting(title: "none", platform: .meet)
        late.summaryPending = SummaryPending(reason: "x", attempts: 3, nextAttempt: now.addingTimeInterval(-60))
        soon.summaryPending = SummaryPending(reason: "x", attempts: 1, nextAttempt: now.addingTimeInterval(60))
        XCTAssertEqual(SummaryPending.due([none, soon, late], now: now), [late.id])
        XCTAssertEqual(SummaryPending.due([none, soon, late], now: now, launch: true), [late.id, soon.id])
    }

    func testEveryFailureButAnEmptyTranscriptAModelOrAnOldCLIIsRetried() {
        XCTAssertTrue(SummaryPending.isRetryable(ClaudeSummarizerError.notInstalled))
        XCTAssertTrue(SummaryPending.isRetryable(ClaudeSummarizerError.usageLimit("limit")))
        XCTAssertTrue(SummaryPending.isRetryable(ClaudeSummarizerError.timedOut))
        XCTAssertFalse(SummaryPending.isRetryable(SummarizerError.emptyTranscript))
        XCTAssertFalse(SummaryPending.isRetryable(ClaudeSummarizerError.modelUnavailable("no such model")))
        XCTAssertFalse(SummaryPending.isRetryable(ClaudeSummarizerError.outdated("unknown option")))
        XCTAssertTrue(SummaryPending.isRetryable(ClaudeSummarizerError.failed("overloaded")))
        XCTAssertFalse(SummaryPending.isRetryable(ClaudeSummariesOff()), "turned off is not a failure to retry")
    }

    func testEditingTheSummaryEndsTheRetries() throws {
        var meeting = Meeting(title: "x", platform: .meet, status: .done)
        meeting.summaryPending = SummaryPending(reason: "x", attempts: 1, nextAttempt: Date())
        _ = try MeetingEdit.setSummary(markdown: "## Summary\nWritten by hand.").apply(to: &meeting)
        XCTAssertNil(meeting.summaryPending)
    }

    func testDoneStatesCarryOverToTheRewrite() {
        let old = """
        ## Action items
        - [x] Anna: send the deck to Sam (Friday)
        - [ ] Speaker 2: check prod
        - [x] You: book the room
        """
        let new = """
        ## Summary
        Better.

        ## Action items
        - [ ] Piotr Kowalski: Check the prod environment
        - [ ] Anna Nowak: Send the deck to Sam (Friday)
        - [ ] Łukasz: Update the roadmap
        """
        let carried = ActionItem.carryingDone(from: old, into: new)
        XCTAssertEqual(ActionItem.parse(carried).map(\.done), [false, true, false])
        XCTAssertEqual(ActionItem.carryingDone(from: "## Action items\n- [ ] Anna: x", into: new), new)
    }
}
