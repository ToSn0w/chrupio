import XCTest
@testable import ChrupioCore

final class SummaryTemplateTests: XCTestCase {
    var folder: URL!
    var fake: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-template-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fake = folder.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        dir="$(dirname "$0")"
        for arg in "$@"; do printf '%s\\n<<END>>\\n' "$arg"; done > "$dir/argv.txt"
        cat > "$dir/stdin.txt"
        cat "$dir/reply.json"
        """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func summarizer(_ template: SummaryTemplate = .standard) -> ClaudeSummarizer {
        var summarizer = ClaudeSummarizer(executable: fake, model: "claude-test", home: "/Users/someone",
                                          workingDirectory: folder.appendingPathComponent("cwd", isDirectory: true))
        summarizer.template = template
        return summarizer
    }

    func reply(_ output: String) throws {
        try #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":\#(output)}"#
            .write(to: folder.appendingPathComponent("reply.json"), atomically: true, encoding: .utf8)
    }

    func argument(_ flag: String) throws -> String? {
        let argv = try String(contentsOf: folder.appendingPathComponent("argv.txt"), encoding: .utf8).components(separatedBy: "\n<<END>>\n")
        return argv.firstIndex(of: flag).map { argv[$0 + 1] }
    }

    func meeting(title: String, language: String = "pl") -> Meeting {
        var meeting = Meeting(title: title, platform: .other, selfName: "Łukasz")
        meeting.language = language
        meeting.segments = [TranscriptSegment(start: 0, end: 70, speaker: .me, text: "Zrobię raport do piątku.")]
        return meeting
    }

    func testAutoPickIsConservative() {
        XCTAssertEqual(SummaryTemplate.auto(title: "Daily standup"), .standup)
        XCTAssertEqual(SummaryTemplate.auto(title: "PRJ Stand-up"), .standup)
        XCTAssertEqual(SummaryTemplate.auto(title: "1:1 Anna / Łukasz"), .oneOnOne)
        XCTAssertEqual(SummaryTemplate.auto(title: "Łukasz 1on1"), .oneOnOne)
        XCTAssertEqual(SummaryTemplate.auto(title: "Interview – backend dev"), .interview)
        XCTAssertEqual(SummaryTemplate.auto(title: "Rozmowa rekrutacyjna"), .interview)
        for title in ["Slack Huddle", "Browser call", "Acme weekly sync", "Release 1.10", "Q1 planning", "Sprint 11 review"] {
            XCTAssertEqual(SummaryTemplate.auto(title: title), .standard, title)
        }
        var meeting = meeting(title: "Daily standup")
        XCTAssertEqual(SummaryTemplate.resolved(for: meeting), .standup)
        meeting.summaryTemplate = SummaryTemplate.clientCall.rawValue
        XCTAssertEqual(SummaryTemplate.resolved(for: meeting), .clientCall, "a hand-picked template wins")
    }

    func testPolishHeadingsAreAllPolish() {
        let notes = ClaudeNotes(tldr: "Krótko.", people: [.init(name: "Anna", status: ["Raport"])], decisions: ["Wydanie w piątek"],
                                actionItems: [.init(owner: "Anna", task: "Wysłać raport")])
        let markdown = notes.markdown(language: "pl")
        XCTAssertTrue(markdown.hasPrefix("## Podsumowanie\nKrótko.\n\n## Kto co robi"))
        XCTAssertTrue(markdown.contains("## Decyzje\n- Wydanie w piątek"))
        XCTAssertTrue(markdown.contains("## Zadania\n- [ ] Anna: Wysłać raport"))
        for english in ["Summary", "Decisions", "Action items", "By person"] { XCTAssertFalse(markdown.contains("## " + english), english) }
        XCTAssertEqual(ActionItem.parse(markdown).map(\.text), ["Anna: Wysłać raport"])
        // A short call's checklist is still found under the Polish heading.
        XCTAssertTrue(ActionItemRules.clearingActionItems(markdown).hasSuffix("## Zadania\n- None recorded"))
        XCTAssertTrue(notes.markdown(language: "pl", template: .standup).contains("## Aktualizacje\n"))
        XCTAssertTrue(notes.markdown(language: "en", template: .oneOnOne).contains("## Topics\n"))
        XCTAssertTrue(notes.markdown(language: "en").contains("## Decisions\n"))
    }

    func testPolishSummaryParagraphIsTidied() {
        let stored = "## Podsumowanie\nKrótko. ## Decyzje - x\n\n## Kto co robi\n- None recorded"
        XCTAssertEqual(MeetingSummary.tidied(stored), "## Podsumowanie\nKrótko.\n\n## Kto co robi\n- None recorded")
    }

    func testTemplateGuidanceGoesIntoTheSystemPrompt() async throws {
        try reply(#"{"tldr":"Status.","people":[],"decisions":[],"action_items":[]}"#)
        let summary = try await summarizer(.clientCall).summarize(meeting(title: "Acme"))
        XCTAssertTrue(try argument("--system-prompt")?.contains("call with a client") == true)
        XCTAssertEqual(try argument("--json-schema"), ClaudeNotes.schemaJSON, "a real title asks for no title")
        XCTAssertEqual(summary.template, "client-call")
        XCTAssertNil(summary.suggestedTitle)
        XCTAssertTrue(summary.markdown.contains("## Kto co mówił"))
    }

    func testGenericTitleAsksForATitle() async throws {
        try reply(#"{"tldr":"Plan.","people":[],"decisions":[],"action_items":[],"title":"\"Planowanie sprintu raportów.\""}"#)
        let summary = try await summarizer().summarize(meeting(title: "Browser call"))
        XCTAssertEqual(try argument("--json-schema"), ClaudeNotes.schemaWithTitleJSON)
        XCTAssertTrue(ClaudeNotes.schemaWithTitleJSON.contains(#""title""#))
        XCTAssertTrue(try argument("--system-prompt")?.contains("generic placeholder") == true)
        XCTAssertEqual(summary.suggestedTitle, "Planowanie sprintu raportów")
        XCTAssertNil(summary.template)
    }

    func testFollowUpDraftUsesTheSummaryAndLanguage() async throws {
        try #"{"type":"result","subtype":"success","is_error":false,"result":"Dzięki za spotkanie!\n- Anna wysyła raport\n"}"#
            .write(to: folder.appendingPathComponent("reply.json"), atomically: true, encoding: .utf8)
        var meeting = meeting(title: "Planowanie")
        meeting.summary = MeetingSummary(markdown: "## Podsumowanie\nRaport w piątek.", model: "m")
        let text = try await summarizer().draftFollowUp(meeting)
        XCTAssertEqual(text, "Dzięki za spotkanie!\n- Anna wysyła raport")
        XCTAssertTrue(try argument("--system-prompt")?.contains("Write it in Polish") == true)
        XCTAssertNil(try argument("--json-schema"), "free text")
        let stdin = try String(contentsOf: folder.appendingPathComponent("stdin.txt"), encoding: .utf8)
        XCTAssertNotNil(stdin.range(of: "<notes-[0-9a-f]{8}>\n## Podsumowanie\nRaport w piątek.", options: .regularExpression), stdin)
    }
}
