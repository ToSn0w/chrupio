import Foundation
@testable import ChrupioCore
import XCTest

/// "Save diagnostics" (off by default) decides whether probe.json is written next to a meeting.
@MainActor
final class DiagnosticsGateTests: XCTestCase {
    private var library: MeetingLibrary!
    private var environment: FakeRecordingEnvironment!
    private var recorder: RecordingController!
    private var monitor: LiveCallMonitor!

    override func setUp() async throws {
        library = MeetingLibrary(saver: FakeSaver())
        environment = FakeRecordingEnvironment()
        recorder = RecordingController(library: library, sleepHold: FakeSleepHold(), limits: RecordingLimits(silence: 60, maximum: 3_600))
        recorder.environment = environment
        monitor = LiveCallMonitor(library: library, recorder: recorder)
    }

    private let key = BrowserMeetingTracker.key(tabId: 3, callId: 100)

    private func probeFile(_ id: UUID) -> URL { library.store.directory(for: id).appendingPathComponent("probe.json") }

    private func sendProbe() throws {
        let json = #"{"type":"meeting","platform":"meet","tabId":3,"callId":100,"probe":{"v":1}}"#
        monitor.handle(try JSONDecoder().decode(ExtensionEvent.self, from: Data(json.utf8)))
    }

    func testNothingIsSavedWhileDiagnosticsAreOff() throws {
        XCTAssertFalse(monitor.saveDiagnostics(), "off by default")
        try sendProbe()
        let id = UUID()
        monitor.recordingStarted(id, key: key)
        monitor.snapshot(.object(["nodes": .number(1)]), key: key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: probeFile(id).path))
    }

    func testProbeIsSavedWhenOn() throws {
        monitor.saveDiagnostics = { true }
        try sendProbe()
        let id = UUID()
        monitor.recordingStarted(id, key: key)
        XCTAssertTrue(FileManager.default.fileExists(atPath: probeFile(id).path))
    }

    func testProbeOfTheRecordedCallIsNotSavedWhileOff() throws {
        let id = try XCTUnwrap(recorder.start(MeetingCandidate(key: key, platform: .meet, title: "Standup"), manual: false))
        try sendProbe()
        monitor.snapshot(.object(["nodes": .number(1)]), key: key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: probeFile(id).path))
    }

    func testWarningMentionsProbeOnlyWhenItIsSaved() {
        let event = ExtensionEvent(type: .meeting, platform: .meet, tabId: 1, participants: ["Me", "Anna"], selfName: "Me")
        let on = event.missingSpeakersWarning(speakerEventCount: 0, elapsed: 600, diagnosticsSaved: true)
        let off = event.missingSpeakersWarning(speakerEventCount: 0, elapsed: 600, diagnosticsSaved: false)
        XCTAssertTrue(on?.contains("probe.json") == true)
        XCTAssertEqual(off, "The Google Meet tab lists 1 participant(s) but no speaker was detected in 10 min, so the transcript won't name who spoke. Update the Chrupio Chrome extension.")
    }
}
