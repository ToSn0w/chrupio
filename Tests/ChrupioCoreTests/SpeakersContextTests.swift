import Foundation
@testable import ChrupioCore
import XCTest

final class VoiceFeatureTests: XCTestCase {
    /// A voiced-like signal: a fundamental with harmonics and a slow amplitude wobble, so frames vary in energy.
    static func voice(pitch: Float, brightness: Float, seconds: Double = 3, seed: Float = 0) -> [Float] {
        let count = Int(seconds * 16_000)
        return (0..<count).map { i in
            let t = Float(i) / 16_000
            var sample: Float = 0
            for harmonic in 1...8 { sample += pow(brightness, Float(harmonic - 1)) * sin(2 * .pi * pitch * Float(harmonic) * t + seed) }
            return 0.2 * sample * (0.6 + 0.4 * sin(2 * .pi * 3 * t + seed))
        }
    }

    func testFeaturesHaveFixedSizeAndNeedEnoughAudio() {
        XCTAssertEqual(VoiceFeatures.compute(Self.voice(pitch: 120, brightness: 0.7))?.count, VoiceFeatures.size)
        XCTAssertNil(VoiceFeatures.compute(Self.voice(pitch: 120, brightness: 0.7, seconds: 0.3)))
        XCTAssertNil(VoiceFeatures.compute([Float](repeating: 0, count: 48_000)))
    }

    func testDifferentVoicesClusterApart() {
        let low = (0..<6).compactMap { VoiceFeatures.compute(Self.voice(pitch: 110, brightness: 0.8, seed: Float($0))) }
        let high = (0..<6).compactMap { VoiceFeatures.compute(Self.voice(pitch: 240, brightness: 0.4, seed: Float($0))) }
        let labels = VoiceAttribution.cluster(low + high)
        XCTAssertEqual(Set(labels.prefix(6)).count, 1)
        XCTAssertEqual(Set(labels.suffix(6)).count, 1)
        XCTAssertNotEqual(labels[0], labels[6])
    }

    func testAnnotateOnlyTouchesSystemChunks() {
        let samples = Self.voice(pitch: 150, brightness: 0.6, seconds: 4)
        let segment = TranscriptSegment(start: 10.5, end: 13.5, speaker: .remote(nil), text: "hi")
        let url = URL(fileURLWithPath: "/dev/null")
        let system = AudioChunk(track: .system, index: 1, url: url, startOffset: 10, duration: 4, rms: 0.1)
        let mic = AudioChunk(track: .mic, index: 1, url: url, startOffset: 10, duration: 4, rms: 0.1)
        XCTAssertEqual(VoiceFeatures.annotate([segment], chunk: system, samples: samples).first?.voice?.count, VoiceFeatures.size)
        XCTAssertNil(VoiceFeatures.annotate([segment], chunk: mic, samples: samples).first?.voice)
    }
}

final class VoiceClusterTests: XCTestCase {
    static func point(_ base: Float, jitter: Float) -> [Float] {
        (0..<VoiceFeatures.size).map { base + jitter * Float(($0 % 3) - 1) }
    }

    func testStrayLinesFoldIntoTheNearestVoice() {
        var vectors = (0..<20).map { Self.point(0, jitter: Float($0 % 5) * 0.01) }
        vectors += (0..<20).map { Self.point(10, jitter: Float($0 % 5) * 0.01) }
        vectors.append(Self.point(7, jitter: 0))
        let labels = VoiceAttribution.cluster(vectors)
        XCTAssertEqual(Set(labels).count, 2)
        XCTAssertEqual(labels.last, labels[20])
    }

    func testClusterNumbersFollowFirstAppearance() {
        let vectors = [Self.point(10, jitter: 0), Self.point(0, jitter: 0), Self.point(10, jitter: 0.01), Self.point(0, jitter: 0.01)]
        XCTAssertEqual(VoiceAttribution.cluster(vectors), [0, 1, 0, 1])
    }
}

final class VoiceAttributionTests: XCTestCase {
    func segment(_ start: TimeInterval, _ speaker: Speaker, voice: [Float]?, length: TimeInterval = 3) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + length, speaker: speaker, text: "line \(start)", voice: voice)
    }

    let a = VoiceClusterTests.point(0, jitter: 0)
    let b = VoiceClusterTests.point(10, jitter: 0)

    func testLiveNameSpreadsToItsVoiceAndOthersGetPlaceholders() {
        var meeting = Meeting(title: "Sync", platform: .slack)
        meeting.segments = [
            segment(0, .remote("Anna"), voice: a), segment(5, .remote(nil), voice: a), segment(10, .remote(nil), voice: a),
            segment(15, .remote(nil), voice: b), segment(20, .remote(nil), voice: b), segment(25, .remote(nil), voice: b),
            segment(26, .remote(nil), voice: nil, length: 1), segment(30, .me, voice: nil),
        ]
        VoiceAttribution.apply(to: &meeting, prints: VoicePrints())
        XCTAssertEqual(meeting.segments.map(\.speaker.label), ["Anna", "Anna", "Anna", "Speaker 1", "Speaker 1", "Speaker 1", "Speaker 1", "You"])
    }

    func testSingleFreeAttendeeNamesTheOnlyUnnamedVoice() {
        var meeting = Meeting(title: "1:1", platform: .meet)
        meeting.attendees = ["Me Myself", "Kuba"]
        meeting.selfName = "Me Myself"
        meeting.segments = (0..<4).map { segment(Double($0) * 5, .remote(nil), voice: a) }
        VoiceAttribution.apply(to: &meeting, prints: VoicePrints())
        XCTAssertEqual(Set(meeting.segments.map(\.speaker.label)), ["Kuba"])
    }

    func testStoredPrintNamesAVoice() {
        var prints = VoicePrints()
        var known = Meeting(title: "Earlier", platform: .meet)
        known.segments = (0..<4).map { segment(Double($0) * 5, .remote("Tomasz"), voice: a) }
            + (0..<4).map { segment(30 + Double($0) * 5, .remote("Piotr"), voice: b) }
        prints.learn(from: known, liveNames: ["Tomasz", "Piotr"])
        XCTAssertEqual(Set(prints.people.keys), ["Tomasz", "Piotr"])

        XCTAssertEqual(prints.closest(to: b, preferring: [], excluding: []), "Piotr")
        XCTAssertNil(prints.closest(to: b, preferring: [], excluding: ["Piotr", "Tomasz"]))
    }

    func testStoredPrintOfSomeoneNotInTheMeetingStaysUnnamed() {
        var prints = VoicePrints()
        var known = Meeting(title: "Earlier", platform: .meet)
        known.segments = (0..<4).map { segment(Double($0) * 5, .remote("Tomasz Elsewhere"), voice: a) }
            + (0..<4).map { segment(30 + Double($0) * 5, .remote("Piotr Elsewhere"), voice: b) }
        prints.learn(from: known, liveNames: ["Tomasz Elsewhere", "Piotr Elsewhere"])
        var meeting = Meeting(title: "huddle", platform: .slack)
        meeting.attendees = ["Me Myself", "Ola Inside", "Ewa Inside"]
        meeting.selfName = "Me Myself"
        meeting.segments = (0..<4).map { segment(Double($0) * 5, .remote(nil), voice: b) }
        VoiceAttribution.apply(to: &meeting, prints: prints)
        XCTAssertEqual(Set(meeting.segments.map(\.speaker.label)), ["Speaker 1"])
    }

    func testStoredPrintUnderAnotherSpellingTakesTheAttendeeSpelling() {
        var prints = VoicePrints()
        var known = Meeting(title: "Earlier", platform: .meet)
        known.segments = (0..<4).map { segment(Double($0) * 5, .remote("Łukasz Żółć"), voice: a) }
            + (0..<4).map { segment(30 + Double($0) * 5, .remote("Tomasz Gdzieindziej"), voice: b) }
        prints.learn(from: known, liveNames: ["Łukasz Żółć", "Tomasz Gdzieindziej"])
        var meeting = Meeting(title: "huddle", platform: .slack)
        meeting.attendees = ["Me Myself", "Lukasz Zolc", "Ewa Inna"]
        meeting.selfName = "Me Myself"
        meeting.segments = (0..<4).map { segment(Double($0) * 5, .remote(nil), voice: a) }
        VoiceAttribution.apply(to: &meeting, prints: prints)
        XCTAssertEqual(Set(meeting.segments.map(\.speaker.label)), ["Lukasz Zolc"])
    }

    func testLearningNeedsThreeLinesAndOnlyLiveNames() {
        var prints = VoicePrints()
        var meeting = Meeting(title: "x", platform: .meet)
        meeting.segments = [segment(0, .remote("Anna"), voice: a), segment(5, .remote("Anna"), voice: a),
                            segment(10, .remote("Speaker 1"), voice: b), segment(15, .remote("Speaker 1"), voice: b), segment(20, .remote("Speaker 1"), voice: b)]
        prints.learn(from: meeting, liveNames: ["Anna"])
        XCTAssertTrue(prints.people.isEmpty)
    }

    func testPlaceholderPattern() {
        XCTAssertTrue(VoiceAttribution.isPlaceholder("Speaker 3"))
        XCTAssertFalse(VoiceAttribution.isPlaceholder("Speaker"))
        XCTAssertFalse(VoiceAttribution.isPlaceholder("Anna Speaker 3"))
    }
}

final class MeetingContextTests: XCTestCase {
    let context = MeetingContext(
        vocabulary: ["Acme", "Stripe", "Mailchimp"],
        corrections: ["ack me": "Acme", "mail chimp": "Mailchimp", "bar": "Bar"],
        people: [.init(name: "Piotr", aliases: ["Pete"], role: "dev", internal: true)],
        profiles: [
            .init(name: "Acme core", match: ["acme"], attendees: ["Piotr", "Tomasz"], topics: ["backups"], vocabulary: ["Elasticsearch"], language: "pl"),
            .init(name: "Management standup", match: ["management", "acme"], attendees: ["Marek"], topics: nil, vocabulary: ["Reports Export"], language: "en"),
        ],
        summaryStyle: "Short bullets, owners by first name.")

    func testCorrectionsAreWholeWordAndCaseInsensitive() {
        XCTAssertEqual(context.correct("We moved Ack Me off mail chimp."), "We moved Acme off Mailchimp.")
        XCTAssertEqual(context.correct("barbecue at the bar"), "barbecue at the Bar")
    }

    func testMostSpecificProfileWins() {
        XCTAssertEqual(context.profile(for: "I: Management Standup | Acme")?.name, "Management standup")
        XCTAssertEqual(context.profile(for: "team-acme-core")?.name, "Acme core")
        XCTAssertNil(context.profile(for: "Lunch"))
    }

    func testTermsPutTheMeetingsOwnFirstWithoutDuplicates() {
        XCTAssertEqual(context.terms(for: "team-acme-core"), ["Elasticsearch", "Acme", "Stripe", "Mailchimp"])
    }

    func testSummaryGuidance() throws {
        let guidance = try XCTUnwrap(context.summaryGuidance(for: Meeting(title: "team-acme-core", platform: .slack)))
        XCTAssertTrue(guidance.contains("Short bullets"))
        XCTAssertTrue(guidance.contains("Usual attendees: Piotr, Tomasz"))
        XCTAssertTrue(guidance.contains("report only what the transcript says"))
        XCTAssertNil(MeetingContext().summaryGuidance(for: Meeting(title: "x", platform: .meet)))
    }

    func testDecodesPartialFileAndCachesByModificationDate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("context-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"vocabulary":["Stripe"],"unknown":1}"#.utf8).write(to: url)
        let file = MeetingContextFile()
        XCTAssertEqual(file.context(at: url.path)?.vocabulary, ["Stripe"])
        XCTAssertNil(file.context(at: "/nonexistent/context.json"))
    }
}

final class ZoomLabelTests: XCTestCase {
    func testSpeakerLabels() {
        XCTAssertEqual(ZoomMonitor.speakerName(fromLabel: "Talking: Anna Nowak"), "Anna Nowak")
        XCTAssertEqual(ZoomMonitor.speakerName(fromLabel: "Anna Nowak is talking"), "Anna Nowak")
        XCTAssertEqual(ZoomMonitor.speakerName(fromLabel: "Anna Nowak (Host), speaking"), "Anna Nowak")
        XCTAssertNil(ZoomMonitor.speakerName(fromLabel: "Mute"))
        XCTAssertEqual(ZoomMonitor.speakerName(fromLabel: "Anna Nowak, Speaking now"), "Anna Nowak")
        XCTAssertNil(ZoomMonitor.speakerName(fromLabel: "Stop talking about it"))
        XCTAssertNil(ZoomMonitor.speakerName(fromLabel: "I was speaking"))
        XCTAssertNil(ZoomMonitor.speakerName(fromLabel: "Someone is talking"))
        XCTAssertNil(ZoomMonitor.speakerName(fromLabel: "Thanks everyone for joining the call, great talking"))
    }

    func testTileLabels() {
        XCTAssertEqual(ZoomMonitor.tileName(fromLabel: "Anna Nowak, Video on"), "Anna Nowak")
        XCTAssertNil(ZoomMonitor.tileName(fromLabel: "Share Screen"))
    }
}

final class ProbeAndPromptTests: XCTestCase {
    func testProbeDecodesAnyJSONAndMergesIntoProbeFile() throws {
        let json = #"{"type":"meeting","platform":"meet","tabId":3,"probe":{"v":1,"tiles":[{"name":"Anna","recent":4}],"ok":true,"none":null}}"#
        let event = try JSONDecoder().decode(ExtensionEvent.self, from: Data(json.utf8))
        guard case .object(let probe)? = event.probe else { return XCTFail("no probe") }
        XCTAssertEqual(probe["v"], .number(1))
        XCTAssertEqual(probe["ok"], .bool(true))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let id = UUID()
        try store.writeProbe(["extension": event.probe!], for: id)
        try store.writeProbe(["zoomLabels": .array([.string("Talking: Anna")])], for: id)
        let saved = try JSONDecoder().decode([String: AnyJSON].self, from: Data(contentsOf: store.directory(for: id).appendingPathComponent("probe.json")))
        XCTAssertNotNil(saved["extension"])
        XCTAssertEqual(saved["zoomLabels"], .array([.string("Talking: Anna")]))
        XCTAssertNotNil(saved["updatedAt"])
    }

    func testTrackerKeyMatchesRecordingSource() {
        XCTAssertEqual(BrowserMeetingTracker.key(tabId: 3, callId: 7), "chrome-tab:3#7")
    }

    func testSummaryPromptsExplainPlaceholdersAndCarryGuidance() {
        XCTAssertTrue(Prompts.summarySystem(language: "pl").contains(Prompts.speakerRule))
        XCTAssertTrue(Prompts.structuredSystem(language: nil).contains(Prompts.speakerRule))
        XCTAssertTrue(Prompts.speakerRule.contains("Speaker 1"))
        XCTAssertTrue(Prompts.withGuidance("base", "extra").hasSuffix("\n\nextra"))
        XCTAssertEqual(Prompts.withGuidance("base", nil), "base")
    }

    func testSegmentVoiceRoundTripsAndOldFilesDecode() throws {
        var meeting = Meeting(title: "x", platform: .meet)
        meeting.segments = [TranscriptSegment(start: 0, end: 1, speaker: .remote(nil), text: "a", voice: [1, 2])]
        let decoded = try MeetingStore.decoder.decode(Meeting.self, from: MeetingStore.encoder.encode(meeting))
        XCTAssertEqual(decoded.segments.first?.voice, [1, 2])
    }
}
