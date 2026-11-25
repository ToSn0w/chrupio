import Foundation
@testable import ChrupioCore
import XCTest

/// Answers each recovery from a script; once out of script, nothing recovered and nothing blocked.
final class FakeOrphanSource: OrphanRecovering, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [(recovered: [Meeting], blocked: Int)] = []
    private(set) var calls = 0

    func script(_ recovered: [Meeting], blocked: Int) { lock.withLock { results.append((recovered, blocked)) } }
    var callCount: Int { lock.withLock { calls } }

    func recoverOrphans(lockTimeout: TimeInterval?) -> (recovered: [Meeting], blocked: Int) {
        lock.withLock {
            calls += 1
            return results.isEmpty ? ([], 0) : results.removeFirst()
        }
    }
}

@MainActor
final class FakeOrphanEnvironment: OrphanRecoveryEnvironment {
    var minimumMeetingSeconds: TimeInterval = 60
    var withAudio: Set<UUID> = []
    var queues = true
    private(set) var events: [String] = []

    func hasAudio(_ id: UUID) -> Bool { withAudio.contains(id) }
    func retranscribe(_ id: UUID) { events.append("retranscribe") }
    func isQueued(_ id: UUID) -> Bool { queues }
    func finishWithoutAudio(_ id: UUID) { events.append("finish") }
    func summarizeInterrupted(_ id: UUID) { events.append("summarize") }
}

@MainActor
final class OrphanRecoverySchedulerTests: XCTestCase {
    private var library: MeetingLibrary!
    private var source: FakeOrphanSource!
    private var environment: FakeOrphanEnvironment!
    private var scheduler: OrphanRecoveryScheduler!

    override func setUp() async throws {
        library = MeetingLibrary(saver: FakeSaver())
        source = FakeOrphanSource()
        environment = FakeOrphanEnvironment()
        scheduler = OrphanRecoveryScheduler(library: library, source: source)
        scheduler.environment = environment
    }

    private func meeting(_ status: MeetingStatus, lastSpeech: Double = 600, startedMinutesAgo: Double = 60) -> Meeting {
        Meeting(title: "Call", platform: .meet, startedAt: Date().addingTimeInterval(-startedMinutesAgo * 60),
                segments: [TranscriptSegment(start: 0, end: lastSpeech, speaker: .me, text: "Hi")], status: status)
    }

    func testInterruptedSummaryIsOnlyWrittenAgain() {
        let call = meeting(.summarizing)
        library.add([call])
        scheduler.launchFinished(blockedOrphans: 0)
        XCTAssertEqual(library.meeting(call.id)?.status, .done)
        XCTAssertEqual(environment.events, ["summarize"])
    }

    func testInterruptedRecordingEndsAtItsLastSpeechAndIsTranscribed() throws {
        let call = meeting(.recording)
        let done = meeting(.done)
        library.add([call, done])
        environment.withAudio = [call.id]
        scheduler.launchFinished(blockedOrphans: 0)
        let stored = try XCTUnwrap(library.meeting(call.id))
        XCTAssertEqual(stored.status, .transcribing)
        XCTAssertEqual(try XCTUnwrap(stored.endedAt).timeIntervalSince(call.startedAt), 600, accuracy: 0.001)
        XCTAssertEqual(environment.events, ["retranscribe"], "finished meetings are left alone")
        XCTAssertNil(library.phases[call.id])
    }

    func testShortRecoveredMeetingIsADiscardCandidateUnlessNothingWasQueued() {
        let short = meeting(.transcribing, lastSpeech: 20)
        let unqueued = meeting(.transcribing, lastSpeech: 20)
        library.add([short, unqueued])
        environment.withAudio = [short.id, unqueued.id]
        scheduler.recoverInterrupted(short)
        XCTAssertEqual(library.phases[short.id], .transcribing(discardIfShort: true))
        environment.queues = false
        scheduler.recoverInterrupted(unqueued)
        XCTAssertNil(library.phases[unqueued.id], "a later, manual retranscribe must not discard it")
        XCTAssertEqual(environment.events, ["retranscribe", "retranscribe"])
    }

    func testMeetingWithoutAudioIsFinishedFromItsTranscript() {
        let call = meeting(.transcribing)
        library.add([call])
        scheduler.recoverInterrupted(call)
        XCTAssertEqual(environment.events, ["finish"])
    }

    /// A blocked orphan is tried again on the 10 s timer; the store splits a recording with long gaps into one
    /// meeting per stretch, and every piece is loaded and transcribed.
    func testBlockedOrphanIsRetriedAndEachSplitPieceRecovered() async throws {
        let first = meeting(.recording, startedMinutesAgo: 120)
        let second = meeting(.recording, startedMinutesAgo: 60)
        environment.withAudio = [first.id, second.id]
        source.script([], blocked: 1)
        source.script([first, second], blocked: 0)
        scheduler.launchFinished(blockedOrphans: 1)
        XCTAssertTrue(scheduler.orphansBlocked)

        let start = Date()
        await scheduler.retryBlockedIfDue(now: start)?.value
        XCTAssertTrue(scheduler.orphansBlocked, "still locked")
        XCTAssertNil(scheduler.retryBlockedIfDue(now: start.addingTimeInterval(5)), "not due yet")

        await scheduler.retryBlockedIfDue(now: start.addingTimeInterval(10))?.value
        XCTAssertFalse(scheduler.orphansBlocked)
        XCTAssertEqual(Set(library.meetings.map(\.id)), [first.id, second.id])
        XCTAssertEqual(library.meetings.map { $0.status }, [.transcribing, .transcribing])
        XCTAssertEqual(environment.events, ["retranscribe", "retranscribe"])
        XCTAssertNil(scheduler.retryBlockedIfDue(now: start.addingTimeInterval(60)), "nothing left to retry")
        XCTAssertEqual(source.callCount, 2)
    }
}
