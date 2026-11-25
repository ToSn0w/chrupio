import Foundation
@testable import ChrupioCore
import XCTest

/// Calibrates SpeakerPrints bars on saved meetings, leave-one-meeting-out: named voices of one meeting are matched
/// against prints learned from all the others. Prints only aggregate numbers. Point it at COPIES:
/// CHRUPIO_DRYRUN_DIR=/copy (meetings/<id>/meeting.json, chrupio-context.json) swift test --filter SpeakerPrintCalibrationTests
final class SpeakerPrintCalibrationTests: XCTestCase {
    struct Voice { var meeting: UUID; var name: String; var embedding: [Float] }

    func testThresholdGrid() throws {
        guard let path = ProcessInfo.processInfo.environment["CHRUPIO_DRYRUN_DIR"] else {
            throw XCTSkip("set CHRUPIO_DRYRUN_DIR to a copy of meetings and context")
        }
        let root = URL(fileURLWithPath: path)
        let store = MeetingStore(root: root.appendingPathComponent("meetings"))
        let context = MeetingContext.load(from: root.appendingPathComponent("chrupio-context.json"))
        let canonical: (String) -> String = { context?.canonicalName($0) ?? PersonName.stripMarkers($0) }

        var meetings: [UUID: Meeting] = [:]
        var voices: [Voice] = []
        for var meeting in store.loadAll() {
            meeting.canonicalizeNames(canonical)
            if let expected = context?.expectedAttendees(for: meeting.title), !expected.isEmpty { meeting.expectedAttendees = expected }
            meetings[meeting.id] = meeting
            for (label, embedding) in meeting.speakerVoices ?? [:] where !Meeting.isUnnamedSpeaker(label) {
                let name = canonical(label).isEmpty ? label : canonical(label)
                voices.append(Voice(meeting: meeting.id, name: name, embedding: embedding))
            }
        }
        let held = Set(voices.map(\.meeting))
        print("ground truth: \(voices.count) voices, \(held.count) meetings, \(Set(voices.map { PersonName.key($0.name) }).count) people")

        // Prints per held-out meeting, learned in meeting order from every other meeting.
        let ordered = voices.sorted { meetings[$0.meeting]!.startedAt < meetings[$1.meeting]!.startedAt }
        var printsFor: [UUID: SpeakerPrints] = [:]
        for id in held {
            var prints = SpeakerPrints()
            for voice in ordered where voice.meeting != id { prints.learn(voice.name, embedding: voice.embedding) }
            printsFor[id] = prints
        }

        func score(_ bars: SpeakerPrints.Bars) -> (precision: Double, coverage: Double) {
            var named = 0, correct = 0
            for voice in voices {
                let meeting = meetings[voice.meeting]!
                let reported = meeting.attendees + meeting.speakerEvents.flatMap(\.names)
                let expected = meeting.expectedAttendees ?? []
                guard let match = printsFor[voice.meeting]!.match(to: voice.embedding, attendees: reported + expected, excluding: [],
                                                                  only: expected.isEmpty ? nil : expected + reported, bars: bars) else { continue }
                named += 1
                if PersonName.key(match.name) == PersonName.key(voice.name) { correct += 1 }
            }
            return (named == 0 ? 1 : Double(correct) / Double(named), Double(named) / Double(max(voices.count, 1)))
        }

        let current = score(.standard)
        print(String(format: "current %.2f/%.2f: precision %.3f coverage %.3f", SpeakerPrints.threshold,
                     SpeakerPrints.attendeeThreshold, current.precision, current.coverage))
        var best: (threshold: Float, attendee: Float, precision: Double, coverage: Double)?
        for t in stride(from: 80, through: 60, by: -2) {
            for a in stride(from: 70, through: 50, by: -2) {
                let bars = SpeakerPrints.Bars(threshold: Float(t) / 100, attendee: Float(a) / 100,
                                              outsider: SpeakerPrints.outsiderThreshold, margin: SpeakerPrints.margin)
                let result = score(bars)
                print(String(format: "grid %.2f/%.2f: precision %.3f coverage %.3f", bars.threshold, bars.attendee, result.precision, result.coverage))
                // Highest coverage at precision >= 97%; ties go to the stricter bars.
                if result.precision >= 0.97, best == nil || result.coverage > best!.coverage {
                    best = (bars.threshold, bars.attendee, result.precision, result.coverage)
                }
            }
        }
        if let best {
            print(String(format: "chosen %.2f/%.2f: precision %.3f coverage %.3f", best.threshold, best.attendee, best.precision, best.coverage))
        } else {
            print("no setting reaches 97% precision")
        }
    }
}
