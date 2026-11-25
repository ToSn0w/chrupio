import Foundation
@testable import ChrupioCore
import XCTest

final class MeetingRaceTests: XCTestCase {
    private func meeting(_ labels: [String?]) -> Meeting {
        Meeting(title: "Sync", platform: .meet, segments: labels.enumerated().map { index, label in
            TranscriptSegment(start: Double(index), end: Double(index) + 1, speaker: .remote(label), text: "line \(index)")
        })
    }

    func testEditDuringDiarizationSurvivesTheDiarizedLines() throws {
        var edits = DiarizationEdits()
        let id = UUID()
        var current = meeting(["Speaker 1", "Speaker 2"])
        current.status = .transcribing
        let edit = MeetingEdit.assignSpeaker(speaker: "Speaker 2", name: "Marek")
        XCTAssertThrowsError(try edit.apply(to: &current), "lines aren't final while diarizing")
        edits.record(edit, for: id)
        _ = try MeetingEdit.addNote(text: "check budget", author: "Claude").apply(to: &current)
        edits.record(.addNote(text: "check budget", author: "Claude"), for: id)

        let diarized = meeting(["Speaker 1", "Speaker 2", "Speaker 2"]).segments
        edits.finish(id, meeting: &current, diarized: diarized)
        XCTAssertEqual(current.segments.map(\.speaker.label), ["Speaker 1", "Marek", "Marek"])
        XCTAssertEqual(current.status, .transcribing)
        // Edits that don't touch the lines are already on the meeting and aren't repeated.
        XCTAssertEqual(current.notes?.count, 1)
        // Nothing is replayed twice.
        edits.finish(id, meeting: &current, diarized: diarized)
        XCTAssertEqual(current.notes?.count, 1)
    }

    func testFailedDiarizationStillGivesTheNames() {
        var edits = DiarizationEdits()
        let id = UUID()
        var current = meeting(["Speaker 2"])
        current.status = .transcribing
        edits.record(.assignSpeaker(speaker: "Speaker 2", name: "Marek"), for: id)
        edits.finish(id, meeting: &current, diarized: nil)
        XCTAssertEqual(current.segments.map(\.speaker.label), ["Marek"])
    }

    func testExternalWriteWhileBusyIsLoadedLater() {
        let id = UUID()
        var changes = ExternalChanges(known: [id: Date(timeIntervalSince1970: 1)])
        let onDisk = [id: Date(timeIntervalSince1970: 2)]
        XCTAssertEqual(changes.changed(onDisk: onDisk), [id])
        // Busy: the app skips the load and doesn't acknowledge the date.
        XCTAssertEqual(changes.changed(onDisk: onDisk), [id])
        changes.loaded(id, modified: onDisk[id]!)
        XCTAssertEqual(changes.changed(onDisk: onDisk), [])
        XCTAssertEqual(changes.removed(onDisk: [:]), [id])
        XCTAssertNil(changes.known[id])
    }

    func testConcurrentPrintUpdatesBothPersist() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prints-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    try? SpeakerPrints.update(at: url) { $0.learn("Person \(index)", embedding: [1, Float(index)]) }
                }
            }
        }
        XCTAssertEqual(SpeakerPrints.load(from: url).people.count, 40)
    }

    func testDiarizationsRunOneAtATimeInOrder() {
        var queue = SerialJobQueue<UUID>()
        let a = UUID(), b = UUID()
        queue.enqueue(a)
        queue.enqueue(b)
        queue.enqueue(a)
        XCTAssertEqual(queue.next(), a)
        XCTAssertNil(queue.next(), "one runs at a time")
        queue.finished()
        XCTAssertEqual(queue.next(), b)
        queue.finished()
        XCTAssertNil(queue.next())
        XCTAssertFalse(queue.isRunning)
    }
}
