import Foundation
import ChrupioAudio
@testable import ChrupioCore
import XCTest

/// Re-names the voices of saved meetings without writing anything back. Point it at COPIES:
/// CHRUPIO_DRYRUN_DIR=/copy (meetings/<id>/meeting.json + audio, speaker-prints.json, chrupio-context.json,
/// diarizer-models/) swift test --filter SpeakerNamingDryRunTests
final class SpeakerNamingDryRunTests: XCTestCase {
    func testRenamesSavedMeetings() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHRUPIO_DRYRUN_DIR"] else {
            throw XCTSkip("set CHRUPIO_DRYRUN_DIR to a copy of meetings, prints, context and diarizer models")
        }
        let root = URL(fileURLWithPath: path)
        let store = MeetingStore(root: root.appendingPathComponent("meetings"))
        let context = MeetingContext.load(from: root.appendingPathComponent("chrupio-context.json"))
        let stored = SpeakerPrints.load(from: root.appendingPathComponent("speaker-prints.json"))
        let canonical: (String) -> String = { context?.canonicalName($0) ?? PersonName.stripMarkers($0) }
        let normalized = stored.normalized(canonical)
        // CHRUPIO_DRYRUN_COUNTS=1 prints only label kinds per meeting (attendee / generic / other name), never a name.
        let countsOnly = ProcessInfo.processInfo.environment["CHRUPIO_DRYRUN_COUNTS"] != nil
        if !countsOnly { print("prints: \(stored.people.keys.sorted()) -> \(normalized.people.keys.sorted())") }

        for saved in store.loadAll().sorted(by: { $0.startedAt < $1.startedAt }) {
            let system = AudioChunkScanner.chunks(in: store.audioDirectory(for: saved.id)).filter { $0.track == .system && !$0.isSilent }
            guard !system.isEmpty else { continue }
            let diarization = try await SpeakerDiarizer.diarize(system, models: root.appendingPathComponent("diarizer-models"))

            // The transcript as it was before voices were named: the call reported no speakers.
            var fresh = saved
            fresh.segments = saved.segments.map { segment in
                var segment = segment
                if !segment.speaker.isMe { segment.speaker = .remote(nil) }
                return segment
            }

            var old = fresh
            let oldOutcome = DiarizationNaming.names(for: diarization, meeting: old, prints: stored)
            DiarizationNaming.apply(diarization, names: oldOutcome.names, to: &old)

            var new = fresh
            new.canonicalizeNames(canonical)
            if let expected = context?.expectedAttendees(for: new.title), !expected.isEmpty { new.expectedAttendees = expected }
            let newOutcome = DiarizationNaming.names(for: diarization, meeting: new, prints: normalized)
            DiarizationNaming.apply(diarization, names: newOutcome.names, to: &new)

            if countsOnly {
                print("== \(saved.id.uuidString.prefix(8)) stored \(Self.kinds(saved)); now \(Self.kinds(new))")
                continue
            }
            print("\n== \(saved.title) (\(saved.id.uuidString.prefix(8))), expected \(new.expectedAttendees ?? [])")
            print("   stored  \(Self.tally(saved))")
            print("   old run \(Self.tally(old))")
            print("   new run \(Self.tally(new))")
            for cluster in DiarizationNaming.orderOfAppearance(diarization.turns) {
                guard let centroid = diarization.centroids[cluster] else { continue }
                let seconds = diarization.turns.filter { $0.cluster == cluster }.reduce(0) { $0 + $1.end - $1.start }
                let scores = normalized.people.map { ($0.key, SpeakerPrints.cosine($0.value.embedding, centroid)) }
                    .sorted { $0.1 > $1.1 }.prefix(3).map { "\($0.0) \(String(format: "%.2f", $0.1))" }
                print("   cluster \(cluster) \(Int(seconds)) s: old \(oldOutcome.names[cluster] ?? "-"), new \(newOutcome.names[cluster] ?? "-"); \(scores.joined(separator: ", "))")
            }
        }
    }

    /// Remote lines by kind of label: a name on this meeting's attendee list, "Speaker N", any other name, none.
    static func kinds(_ meeting: Meeting) -> String {
        let attendees = Set(meeting.attendees.map(PersonName.key))
        var attendee = 0, generic = 0, other = 0, none = 0
        for segment in meeting.segments where !segment.speaker.isMe {
            guard case .remote(let name?) = segment.speaker else { none += 1; continue }
            if Meeting.isUnnamedSpeaker(name) { generic += 1 } else if attendees.contains(PersonName.key(name)) { attendee += 1 } else { other += 1 }
        }
        return "attendee \(attendee), generic \(generic), other-name \(other), none \(none)"
    }

    /// "named/remote lines" plus lines per name.
    static func tally(_ meeting: Meeting) -> String {
        var counts: [String: Int] = [:]
        var named = 0, remote = 0
        for segment in meeting.segments where !segment.speaker.isMe {
            remote += 1
            guard case .remote(let name?) = segment.speaker else { counts["(none)", default: 0] += 1; continue }
            if !name.hasPrefix("Speaker ") { named += 1 }
            counts[name, default: 0] += 1
        }
        return "\(named)/\(remote) remote lines named; " + counts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
}
