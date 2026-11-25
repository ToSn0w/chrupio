import Foundation
@testable import ChrupioCore
import XCTest

@MainActor
final class FakeEditorEnvironment: MeetingEditorEnvironment {
    var busy: Set<UUID> = []
    private(set) var learned: [MeetingEdit] = []
    private(set) var deleted: [UUID] = []
    func isBusy(_ id: UUID) -> Bool { busy.contains(id) }
    func canonicalName(_ name: String) -> String { name == "ann" ? "Ann Smith" : name }
    func learnAssignment(_ edit: MeetingEdit, before: Meeting) { learned.append(edit) }
    func delete(_ meeting: Meeting) { deleted.append(meeting.id) }
}

@MainActor
final class MeetingEditorTests: XCTestCase {
    private var saver: FakeSaver!
    private var library: MeetingLibrary!
    private var summaryEnvironment: FakeSummaryEnvironment!
    private var environment: FakeEditorEnvironment!
    private var finisher: TranscriptFinisher!
    private var editor: MeetingEditor!

    override func setUp() async throws {
        saver = FakeSaver()
        library = MeetingLibrary(saver: saver)
        summaryEnvironment = FakeSummaryEnvironment()
        let summaries = SummaryScheduler(library: library)
        summaries.environment = summaryEnvironment
        finisher = TranscriptFinisher(library: library,
                                      transcription: TranscriptionScheduler(engines: NoEngines(), makeTranscriber: { Transcriber(model: WhisperModel.all[1]) }),
                                      diarization: DiarizationScheduler { _ in Diarization(turns: [], centroids: [:]) })
        environment = FakeEditorEnvironment()
        editor = MeetingEditor(library: library, summaries: summaries, finisher: finisher)
        editor.environment = environment
    }

    private func meeting() -> Meeting {
        let start = Date().addingTimeInterval(-3_600)
        let meeting = Meeting(title: "Call", platform: .meet, startedAt: start, endedAt: start.addingTimeInterval(600),
                              segments: (0..<5).map { TranscriptSegment(start: Double($0) * 10, end: Double($0) * 10 + 5, speaker: .remote("Speaker 1"), text: "Line \($0)") },
                              status: .done)
        library.add([meeting])
        return meeting
    }

    func testNamingASpeakerSavesLearnsAndRewritesTheSummary() async throws {
        let call = meeting()
        let message = try editor.apply(.assignSpeaker(speaker: "Speaker 1", name: "ann"), to: call.id)
        XCTAssertTrue(message.hasSuffix("Rewriting the summary."))
        XCTAssertEqual(saver.saved.last?.id, call.id, "saved at once")
        XCTAssertEqual(environment.learned, [.assignSpeaker(speaker: "Speaker 1", name: "Ann Smith")])
        let rewritten = await until { self.summaryEnvironment.summarizer.callCount == 1 }
        XCTAssertTrue(rewritten)
    }

    func testNamingWhileDiarizingWaitsForTheLines() throws {
        let call = meeting()
        library.phases.send(.diarizationStarted, to: call.id)
        let message = try editor.apply(.assignSpeaker(speaker: "Speaker 1", name: "ann"), to: call.id)
        XCTAssertTrue(message.contains("will be named Ann Smith when it is done"))
        XCTAssertTrue(environment.learned.isEmpty)
        XCTAssertTrue(saver.saved.isEmpty)
    }

    func testRemoteEditOfAnUnknownMeetingIs404() {
        let response = editor.applyRemoteEdit(LocalAPI.EditRequest(id: UUID(), edit: .rename(title: "X")))
        XCTAssertEqual(response.status, 404)
    }

    func testBusyMeetingsAreNotMerged() {
        let first = meeting(), second = meeting()
        environment.busy = [second.id]
        editor.merge(first.id, into: second.id)
        XCTAssertTrue(environment.deleted.isEmpty)
    }

    func testTypedNotesAndTitleAreTrimmed() {
        let call = meeting()
        editor.rename(call.id, to: "  Planning ")
        editor.setTypedNotes(call.id, "   ")
        XCTAssertEqual(library.meeting(call.id)?.title, "Planning")
        XCTAssertNil(library.meeting(call.id)?.typedNotes)
    }
}

private struct NoEngines: SpeechEngines {
    func whisper(_ wav: URL, transcriber: Transcriber) async throws -> Transcription { throw CocoaError(.featureUnsupported) }
    func parakeet(_ wav: URL, language: String?, chunk: AudioChunk, vocabulary: [String], aliases: [String: [String]]) async throws -> Transcription {
        throw CocoaError(.featureUnsupported)
    }
    func removeEcho(_ chunk: AudioChunk) async -> URL? { nil }
}
