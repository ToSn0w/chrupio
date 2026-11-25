import XCTest
@testable import ChrupioCore

final class ActionItemQualityTests: XCTestCase {
    func meeting(seconds: TimeInterval = 120) -> Meeting {
        var meeting = Meeting(title: "Standup", platform: .meet, attendees: ["Piotr Kowalski", "Anna Nowak"], selfName: "Łukasz Żurek")
        meeting.expectedAttendees = ["Tomasz Lis"]
        meeting.segments = [TranscriptSegment(start: 0, end: seconds, speaker: .me, text: "Piotr, you take the export bug.")]
        return meeting
    }

    func testSpeechSecondsCountOverlapsOnce() {
        var meeting = meeting()
        meeting.segments = [TranscriptSegment(start: 0, end: 30, speaker: .me, text: "a"),
                            TranscriptSegment(start: 20, end: 40, speaker: .remote("Speaker 1"), text: "b"),
                            TranscriptSegment(start: 100, end: 110, speaker: .me, text: "c")]
        XCTAssertEqual(ActionItemRules.speechSeconds(meeting), 50, accuracy: 0.001)
    }

    func testSnapsMisheardOwnersToKnownPeople() {
        let known = ["Piotr Kowalski", "Anna Nowak", "Tomasz Lis", "Łukasz Żurek"]
        XCTAssertEqual(ActionItemRules.snapOwner("Mipiotr", known: known), "Piotr Kowalski")
        XCTAssertEqual(ActionItemRules.snapOwner("piotr kowalsky", known: known), "Piotr Kowalski")
        XCTAssertEqual(ActionItemRules.snapOwner("Lukasz Zurek", known: known), "Łukasz Żurek")
        XCTAssertEqual(ActionItemRules.snapOwner("Tomasz", known: known), "Tomasz Lis")
        XCTAssertEqual(ActionItemRules.snapOwner("Gustavo", known: known), "Gustavo", "unknown people stay as given")
        XCTAssertEqual(ActionItemRules.snapOwner("Speaker 2", known: known), "Speaker 2")
        XCTAssertEqual(ActionItemRules.snapOwner("Anna", known: known + ["Anna Kowalczyk"]), "Anna", "an ambiguous first name stays")
    }

    func testSimilarity() {
        XCTAssertGreaterThan(ActionItemRules.similarity("Fix the export bug.", "fix the export bug"), 0.95)
        XCTAssertGreaterThan(ActionItemRules.similarity("Send the report to the client", "Send report to the client"), 0.8)
        XCTAssertLessThan(ActionItemRules.similarity("Fix the export bug", "Review the VPN setup"), 0.5)
    }

    func testRefineUnassignsSpeakerLabelsSnapsDedupesAndDropsUnsure() {
        let items = [
            SummaryActionItem(action: "Fix the export bug", owner: "Mipiotr", sourceQuote: "you take the export bug", confidence: 0.9),
            SummaryActionItem(action: "Fix the export bug.", owner: "Piotr Kowalski", deadline: "Friday", confidence: 0.8),
            SummaryActionItem(action: "Check prod", owner: "Speaker 2", confidence: 0.7),
            SummaryActionItem(action: "Review the deck", owner: "Others"),
            SummaryActionItem(action: "Maybe look at logs", owner: "Anna", confidence: 0.2),
            SummaryActionItem(action: "None", owner: "Anna"),
        ]
        let refined = ActionItemRules.refine(items, meeting: meeting(), knownPeople: [])
        XCTAssertEqual(refined.map(\.owner), ["Piotr Kowalski", "Unassigned", "Unassigned"])
        XCTAssertEqual(refined[0].deadline, "Friday", "a duplicate's deadline is kept")
        XCTAssertEqual(refined[0].sourceQuote, "you take the export bug")
    }

    func testShortCallsHaveNoActionItems() {
        let items = [SummaryActionItem(action: "Fix it", owner: "Anna")]
        XCTAssertTrue(ActionItemRules.refine(items, meeting: meeting(seconds: 40), knownPeople: []).isEmpty)
        XCTAssertEqual(ActionItemRules.refine(items, meeting: meeting(seconds: 61), knownPeople: []).count, 1)
        let markdown = "## Summary\nHi.\n\n## Action items\n- [ ] Anna: fix it\n- [ ] Bob: test"
        XCTAssertEqual(ActionItemRules.clearingActionItems(markdown), "## Summary\nHi.\n\n## Action items\n- None recorded")
    }

    func testClaudeNotesKeepSpeakerOwnersAndDropDuplicateNextSteps() {
        let notes = ClaudeNotes(
            tldr: "Sync.",
            people: [.init(name: "Anna Nowak", status: ["Export"], nextSteps: ["Fix the export bug", "Plan the sprint review"])],
            decisions: [],
            actionItems: [.init(owner: "Anna Nowak", task: "Fix the export bug"), .init(owner: "Speaker 2", task: "Check prod")])
        let markdown = notes.markdown(language: "en")
        XCTAssertFalse(markdown.contains("**Next:** Fix the export bug"))
        XCTAssertTrue(markdown.contains("**Next:** Plan the sprint review"))
        XCTAssertEqual(ActionItem.parse(markdown).map(\.text), ["Anna Nowak: Fix the export bug", "Speaker 2: Check prod"])
    }

    func testClaudeActionItemDecodesNewAndOldShapes() throws {
        let new = #"{"action":"Send the deck","owner":"Anna","deadline":"Friday","source_quote":"I'll send it Friday","confidence":0.8,"tickets":[]}"#
        let item = try JSONDecoder().decode(ClaudeNotes.ActionItem.self, from: Data(new.utf8))
        XCTAssertEqual(item.task, "Send the deck")
        XCTAssertEqual(item.due, "Friday")
        XCTAssertEqual(item.sourceQuote, "I'll send it Friday")
        XCTAssertEqual(item.confidence, 0.8)
        let old = #"{"task":"Send the deck","owner":"Anna","due":"Friday","tickets":[]}"#
        XCTAssertEqual(try JSONDecoder().decode(ClaudeNotes.ActionItem.self, from: Data(old.utf8)).task, "Send the deck")
        XCTAssertTrue(ClaudeNotes.schemaJSON.contains("source_quote"))
        XCTAssertTrue(ClaudeNotes.schemaJSON.contains("confidence"))
    }

    func testStoredSummariesWithoutStructuredItemsStillDecode() throws {
        let old = ###"{"markdown":"## Action items\n- [ ] Anna: x","model":"gemma3:4b","createdAt":0}"###
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(old.utf8))
        XCTAssertNil(summary.actionItems)
        var withItems = summary
        withItems.actionItems = [SummaryActionItem(action: "x", owner: "Anna", sourceQuote: "q", confidence: 0.9)]
        let round = try JSONDecoder().decode(MeetingSummary.self, from: JSONEncoder().encode(withItems))
        XCTAssertEqual(round.actionItems, withItems.actionItems)
    }

    func testNamingASpeakerRenamesStructuredOwners() throws {
        var meeting = meeting()
        meeting.status = .done
        meeting.segments.append(TranscriptSegment(start: 120, end: 130, speaker: .remote("Speaker 2"), text: "I'll check prod."))
        meeting.summary = MeetingSummary(markdown: "## Action items\n- [ ] Speaker 2: Check prod", model: "claude")
        meeting.summary?.actionItems = [SummaryActionItem(action: "Check prod", owner: "Speaker 2")]
        _ = try MeetingEdit.assignSpeaker(speaker: "Speaker 2", name: "Anna Nowak").apply(to: &meeting)
        XCTAssertEqual(meeting.summary?.markdown, "## Action items\n- [ ] Anna Nowak: Check prod")
        XCTAssertEqual(meeting.summary?.actionItems?.first?.owner, "Anna Nowak")
    }

    func testClaudeSummarizerStoresRefinedItems() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-items-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reply = """
        {"type":"result","is_error":false,"structured_output":{"tldr":"Sync.","people":[],"decisions":[],
         "action_items":[{"action":"Fix the export bug","owner":"Mipiotr","source_quote":"you take the export bug","confidence":0.9,"tickets":[]},
                         {"action":"Fix the export bug","owner":"Piotr Kowalski","source_quote":"","confidence":0.9,"tickets":[]}]}}
        """
        try reply.write(to: folder.appendingPathComponent("reply.json"), atomically: true, encoding: .utf8)
        let fake = folder.appendingPathComponent("claude")
        try "#!/bin/sh\ncat > /dev/null\ncat \"$(dirname \"$0\")/reply.json\"\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        var claude = ClaudeSummarizer(executable: fake, workingDirectory: folder)
        claude.knownPeople = ["Piotr Kowalski"]
        let summary = try await claude.summarize(meeting())
        XCTAssertEqual(ActionItem.parse(summary.markdown).map(\.text), ["Piotr Kowalski: Fix the export bug"])
        XCTAssertEqual(summary.actionItems?.map(\.sourceQuote), ["you take the export bug"])
    }
}
