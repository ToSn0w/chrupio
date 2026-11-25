import Foundation
@testable import ChrupioCore
import XCTest

@MainActor
final class LiveCallMonitorTests: XCTestCase {
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
        monitor.selfNames = { ["Łukasz"] }
    }

    private let key = BrowserMeetingTracker.key(tabId: 3, callId: 100)

    private func event(speakers: [String]? = nil, participants: [String]? = nil, title: String? = nil, at now: Date) -> ExtensionEvent {
        ExtensionEvent(type: .meeting, platform: .meet, tabId: 3, callId: 100, title: title, inMeeting: true,
                       participants: participants, activeSpeakers: speakers, ts: now.timeIntervalSince1970 * 1000)
    }

    func testExtensionContactAndVersion() {
        XCTAssertFalse(monitor.isExtensionConnected())
        let now = Date()
        monitor.hello("0.3.0", now: now)
        XCTAssertEqual(monitor.extensionVersion, "0.3.0")
        XCTAssertTrue(monitor.isExtensionConnected(now: now.addingTimeInterval(60)))
        XCTAssertFalse(monitor.isExtensionConnected(now: now.addingTimeInterval(120)))
    }

    func testSpeakersOfTheRecordedTabBecomeEventsWhenSomeoneElseTalks() throws {
        let start = Date()
        let id = try XCTUnwrap(recorder.start(MeetingCandidate(key: key, platform: .meet, title: "Standup"), manual: false))
        monitor.handle(event(speakers: ["Ann"], at: start.addingTimeInterval(1)), now: start.addingTimeInterval(1))
        monitor.handle(event(speakers: ["Ann"], at: start.addingTimeInterval(2)), now: start.addingTimeInterval(2))
        XCTAssertEqual(library.meeting(id)?.speakerEvents.count, 0, "one run while the same people talk")
        monitor.handle(event(speakers: ["Bob"], at: start.addingTimeInterval(3)), now: start.addingTimeInterval(3))
        XCTAssertEqual(library.meeting(id)?.speakerEvents.map(\.names), [["Ann"]])
        // Another tab's speakers are not this meeting's.
        monitor.handle(ExtensionEvent(type: .meeting, platform: .meet, tabId: 9, inMeeting: true, activeSpeakers: ["Eve"]), now: start.addingTimeInterval(4))
        XCTAssertEqual(library.meeting(id)?.speakerEvents.count, 1)
    }

    func testTickTakesAttendeesAndTitleAndClosesTheOpenRun() throws {
        let now = Date()
        let id = try XCTUnwrap(recorder.start(MeetingCandidate(key: key, platform: .meet, title: nil), manual: false))
        monitor.handle(event(speakers: ["Ann"], participants: ["Ann", "Bob", "Łukasz"], title: "Planning", at: now), now: now)
        monitor.tick(now: now.addingTimeInterval(2))
        let meeting = try XCTUnwrap(library.meeting(id))
        XCTAssertEqual(meeting.title, "Planning")
        XCTAssertEqual(Set(meeting.attendees), ["Ann", "Bob"], "the user is not an attendee")
        XCTAssertEqual(meeting.speakerEvents.map(\.names), [["Ann"]], "saved with who is talking up to now")
    }

    func testHandOverRetargetsTheRecordingAndNamesTheMeeting() throws {
        let id = try XCTUnwrap(recorder.start(MeetingCandidate(key: "app:chrome", platform: .other, title: "Chrome"), manual: false))
        monitor.handOver(to: MeetingCandidate(key: key, platform: .meet, title: "Design review"))
        XCTAssertEqual(recorder.recording?.sourceKey, key)
        XCTAssertEqual(recorder.recording?.candidateKey, key)
        XCTAssertEqual(library.meeting(id)?.platform, .meet)
        XCTAssertEqual(library.meeting(id)?.title, "Design review")
    }
}
