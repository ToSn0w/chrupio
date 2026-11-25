import Foundation
@testable import ChrupioCore
import XCTest

final class MeetingPhaseTests: XCTestCase {
    private func run(_ events: [MeetingPhase.Event], from start: MeetingPhase? = nil) -> MeetingPhase? {
        events.reduce(start) { MeetingPhase.transition(from: $0, event: $1) }
    }

    func testARecordedCallMayBeDiscardedOnceItsLastChunksAreIn() {
        XCTAssertEqual(run([.recordingStarted]), .recording)
        XCTAssertEqual(run([.recordingStarted, .stopRequested]), .stopping)
        XCTAssertEqual(run([.recordingStarted, .stopRequested, .lastChunksQueued]), .transcribing(discardIfShort: true))
        XCTAssertNil(run([.recordingStarted, .stopRequested, .lastChunksQueued, .transcribed]))
    }

    func testRetranscribingAFinishedMeetingNeverDiscardsIt() {
        XCTAssertEqual(run([.transcriptionQueued]), .transcribing(discardIfShort: false))
        XCTAssertEqual(run([.transcriptionQueued], from: .summaryFailed(reason: "x")), .transcribing(discardIfShort: false))
    }

    func testRecoveryKeepsTheDiscardFlagThroughItsRetranscribeOrDropsItWhenNothingQueued() {
        XCTAssertEqual(run([.recoveredShortCandidate, .transcriptionQueued]), .transcribing(discardIfShort: true))
        XCTAssertNil(run([.recoveredShortCandidate, .transcriptionSkipped]))
        XCTAssertNil(run([.transcriptionSkipped]))
    }

    func testDiarizationEndsIdle() {
        XCTAssertEqual(run([.transcriptionQueued, .transcribed, .diarizationStarted]), .diarizing)
        XCTAssertNil(run([.diarizationStarted, .diarizationFinished]))
        XCTAssertEqual(run([.diarizationFinished], from: .summarizing(rerun: false, previousError: nil)),
                       .summarizing(rerun: false, previousError: nil), "only a diarizing meeting finishes diarizing")
    }

    func testSummaryCarriesTheLastFailureAndAskedRerun() {
        XCTAssertEqual(run([.summaryStarted]), .summarizing(rerun: false, previousError: nil))
        XCTAssertEqual(run([.summaryStarted, .rerunRequested]), .summarizing(rerun: true, previousError: nil))
        XCTAssertNil(run([.summaryStarted, .summarySucceeded]))
        let failed = run([.summaryStarted, .summaryFailed(reason: "timeout")])
        XCTAssertEqual(failed, .summaryFailed(reason: "timeout"))
        XCTAssertEqual(run([.summaryStarted], from: failed), .summarizing(rerun: false, previousError: "timeout"))
        XCTAssertEqual(run([.summaryStarted, .rerunRequested, .summaryFailed(reason: "b")], from: failed), .summaryFailed(reason: "b"))
    }

    func testEventsThatDontApplyLeaveThePhase() {
        XCTAssertNil(run([.rerunRequested]))
        XCTAssertNil(run([.summarySucceeded]))
        XCTAssertNil(run([.lastChunksQueued]))
        XCTAssertEqual(run([.summaryStarted], from: .diarizing), .diarizing)
        XCTAssertEqual(run([.stopRequested], from: .diarizing), .diarizing)
        XCTAssertEqual(run([.transcribed], from: .summaryFailed(reason: "x")), .summaryFailed(reason: "x"))
    }

    func testDeleteForgetsEverything() {
        for phase: MeetingPhase in [.recording, .stopping, .transcribing(discardIfShort: true), .diarizing,
                                    .summarizing(rerun: true, previousError: "x"), .summaryFailed(reason: "x")] {
            XCTAssertNil(MeetingPhase.transition(from: phase, event: .deleted))
        }
    }

    func testMapReturnsThePhaseLeftAndListsBusyMeetings() {
        var phases = MeetingPhases()
        let a = UUID(), b = UUID()
        XCTAssertNil(phases.send(.transcriptionQueued, to: a))
        XCTAssertEqual(phases.send(.transcribed, to: a), .transcribing(discardIfShort: false))
        phases.send(.diarizationStarted, to: a)
        phases.send(.summaryStarted, to: b)
        XCTAssertEqual(phases.diarizing, [a])
        XCTAssertEqual(phases.summarizing, [b])
        phases.send(.deleted, to: b)
        XCTAssertNil(phases[b])
    }
}
