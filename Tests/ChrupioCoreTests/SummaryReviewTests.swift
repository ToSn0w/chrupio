import XCTest
@testable import ChrupioCore

/// Summary fixes from the 20 Oct critical review.
final class SummaryReviewTests: XCTestCase {
    func testDropsOwnerTheModelRepeatedInTheTask() throws {
        let json = """
        {"summary":"Sync.","key_points":[],"decisions":[],
         "action_items":[{"owner":"Gustavo","task":"Gustavo: send the report","due":"no due date specified"},
                         {"owner":"Anna","task":"anna: Anna: book the room","due":"None - ongoing"},
                         {"owner":"Marek","task":"fix the build","due":"brak terminu"},
                         {"owner":"Ola","task":"ship it","due":"Friday"}]}
        """
        let markdown = try XCTUnwrap(StructuredSummary.decode(json)).markdown
        XCTAssertTrue(markdown.hasSuffix("""
        ## Action items
        - [ ] Gustavo: send the report
        - [ ] Anna: book the room
        - [ ] Marek: fix the build
        - [ ] Ola: ship it (Friday)
        """), markdown)
    }

    func testRecognisesNoDueDatePhrases() {
        for text in ["no due date specified", "Not specified", "none - ongoing", "None.", "N/A", "TBD", "no deadline",
                     "brak terminu", "Brak", "bez terminu", "nie określono", "nieokreślony", ""] {
            XCTAssertTrue(Summarizer.isNoDueDate(text), text)
        }
        for text in ["Friday", "no later than Friday", "next week", "niedziela", "20 Oct", "end of sprint"] {
            XCTAssertFalse(Summarizer.isNoDueDate(text), text)
        }
    }

    func testFixesStoredAndFreeTextChecklistLines() {
        let stored = """
        ## Summary
        Sync.

        ## Action items
        - [ ] Gustavo: Gustavo: send the report (no due date specified)
        - [x] Anna: book the room (not specified)
        - [ ] Marek: fix the build (Friday)
        - [ ] send the deck (brak terminu)
        """
        let fixed = """
        ## Summary
        Sync.

        ## Action items
        - [ ] Gustavo: send the report
        - [x] Anna: book the room
        - [ ] Marek: fix the build (Friday)
        - [ ] send the deck (brak terminu)
        """
        XCTAssertEqual(MeetingSummary.tidied(stored), fixed)
        XCTAssertEqual(Summarizer.tidy(stored), fixed)
        XCTAssertEqual(MeetingSummary.tidied(fixed), fixed)
    }

    func testPromptsGiveOneOwnerRule() {
        for prompt in [Prompts.structuredSystem(language: "pl"), Prompts.summarySystem(language: nil)] {
            XCTAssertTrue(prompt.contains("someone addresses them by name"), prompt)
            XCTAssertTrue(prompt.contains("Otherwise the owner is \"Unassigned\""), prompt)
            XCTAssertTrue(prompt.contains("the owner is that label"), "an unnamed voice keeps its label, renamed once the voice is named")
            XCTAssertFalse(prompt.contains("Use \"Unassigned\" only when"), "the old rule contradicted the speaker rule")
        }
    }

    func testUnknownSpeakerKeepsItsLabelAndOthersIsNeverAnOwner() throws {
        let json = """
        {"summary":"Sync.","key_points":[],"decisions":[],
         "action_items":[{"owner":"Speaker 2","task":"create the test folder"},{"owner":"others","task":"review"},
                         {"owner":"Anna","task":"send it"}]}
        """
        XCTAssertTrue(try XCTUnwrap(StructuredSummary.decode(json)).markdown.hasSuffix("""
        - [ ] Speaker 2: create the test folder
        - [ ] Unassigned: review
        - [ ] Anna: send it
        """))
        XCTAssertEqual(Summarizer.tidy("- [ ] Speaker 3: fix it\n- [ ] Others: plan"), "- [ ] Speaker 3: fix it\n- [ ] Unassigned: plan")
    }

    func testStoredSummaryIsFixedWhenRead() throws {
        let stored = MeetingSummary(markdown: "## Action items\n- [ ] Gustavo: Gustavo: send it", model: "gemma3:4b")
        let decoded = try JSONDecoder().decode(MeetingSummary.self, from: JSONEncoder().encode(stored))
        XCTAssertEqual(decoded.markdown, "## Action items\n- [ ] Gustavo: send it")
    }
}

/// Stands in for the model: `reply` gets each call and returns the reply text, or throws to fail it.
final class FakeChat: @unchecked Sendable {
    struct Call { let system: String; let user: String; let schema: String? }
    private let lock = NSLock()
    private var stored: [Call] = []
    let reply: (Call) throws -> String
    var calls: [Call] { lock.withLock { stored } }

    init(_ reply: @escaping (Call) throws -> String) { self.reply = reply }

    func summarizer(chunkCharacters: Int = 8_000) -> Summarizer {
        Summarizer(model: "fake", chunkCharacters: chunkCharacters) { system, user, schema in
            let call = Call(system: system, user: user, schema: schema)
            self.lock.withLock { self.stored.append(call) }
            return try self.reply(call)
        }
    }
}

final class SummarizerRequestTests: XCTestCase {
    func meeting(lines: Int, language: String? = "pl") -> Meeting {
        var meeting = Meeting(title: "Sync", platform: .meet, attendees: ["Anna"], status: .done, language: language)
        meeting.segments = (0..<lines).map { index in
            TranscriptSegment(start: TimeInterval(index * 10), end: TimeInterval(index * 10 + 5), speaker: index.isMultiple(of: 2) ? .me : .remote("Anna"),
                              text: "Line \(index) about the release plan and the billing page.")
        }
        return meeting
    }

    func testTimeoutIsThrownWithoutAFreeTextRerun() async {
        let fake = FakeChat { _ in throw ClaudeSummarizerError.timedOut }
        do {
            _ = try await fake.summarizer().summarize(meeting(lines: 3))
            XCTFail("expected a timeout")
        } catch ClaudeSummarizerError.timedOut {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(fake.calls.count, 1)
    }

    func testUnparseableStructuredReplyFallsBackToFreeText() async throws {
        let fake = FakeChat { call in
            call.schema == nil ? "## Summary\nShort sync.\n\n## Action items\n- [ ] Anna: send it" : "not json"
        }
        let summary = try await fake.summarizer().summarize(meeting(lines: 13))
        XCTAssertEqual(fake.calls.count, 2)
        XCTAssertEqual(summary.markdown, "## Summary\nShort sync.\n\n## Action items\n- [ ] Anna: send it")
        // Under a minute of speech, the free-text checklist is emptied too.
        let short = try await fake.summarizer().summarize(meeting(lines: 3))
        XCTAssertEqual(short.markdown, "## Summary\nShort sync.\n\n## Action items\n- None recorded")
    }

    /// Parts reply as gemma3:4b did for F60F97BF before the fix would have lost: part 2's tasks, in Polish.
    static func partReply(_ call: FakeChat.Call) -> String {
        if call.user.contains("Part 1 of") {
            return #"{"topics":["Plan wydania"],"decisions":[],"action_items":[{"owner":"Anna","task":"Anna: wysłać raport","due":"brak terminu"}]}"#
        }
        return #"{"topics":["Strona płatności"],"decisions":["Wydanie w piątek"],"action_items":[{"owner":"Speaker 2","task":"wysłać raport"},{"owner":"You","task":"naprawić build","due":"piątek"}]}"#
    }

    func testLongMeetingKeepsEveryPartsTasksInItsLanguage() async throws {
        let fake = FakeChat { call in
            let (system, user) = (call.system, call.user)
            if user.contains("of the transcript:") {
                XCTAssertTrue(system.contains("Write all values in Polish"), "each part names the meeting's language")
                XCTAssertTrue(user.contains("Attendees: Anna"), "each part knows who is in the meeting")
                XCTAssertTrue(call.schema?.contains("action_items") == true)
                return Self.partReply(call)
            }
            XCTAssertTrue(user.contains("Topics:\n- Strona płatności\nDecisions:\n- Wydanie w piątek"), user)
            XCTAssertFalse(user.contains("wysłać raport"), "tasks are merged in code, not by the final call")
            XCTAssertFalse(system.contains("\"action_items\""))
            XCTAssertFalse(call.schema?.contains("action_items") ?? true)
            return #"{"summary":"Planowanie wydania.","key_points":["Strona płatności"],"decisions":["Wydanie w piątek"]}"#
        }
        let summary = try await fake.summarizer(chunkCharacters: 400).summarize(meeting(lines: 12))
        XCTAssertEqual(fake.calls.count, 3, "two parts and the final call")
        XCTAssertEqual(summary.markdown, """
        ## Podsumowanie
        Planowanie wydania.

        ## Najważniejsze punkty
        - Strona płatności

        ## Decyzje
        - Wydanie w piątek

        ## Zadania
        - [ ] Anna: wysłać raport
        - [ ] You: naprawić build (piątek)
        """)
    }

    func testLongMeetingFreeTextFallbackUsesMergedTasks() async throws {
        let fake = FakeChat { call in
            if call.user.contains("of the transcript:") { return Self.partReply(call) }
            XCTAssertFalse(call.system.contains("## Action items"))
            return call.schema == nil ? "## Summary\nPlanowanie.\n\n## Decisions\n- None recorded\n\n## Action items\n- [ ] Ktoś: coś" : "not json"
        }
        let summary = try await fake.summarizer(chunkCharacters: 400).summarize(meeting(lines: 12))
        XCTAssertEqual(summary.markdown, """
        ## Summary
        Planowanie.

        ## Decisions
        - None recorded

        ## Action items
        - [ ] Anna: wysłać raport
        - [ ] You: naprawić build (piątek)
        """)
    }

    func testPartPromptWithoutKnownLanguageKeepsTheTranscriptsLanguage() {
        XCTAssertTrue(Prompts.partSystem(language: nil).contains("language most of the transcript is in; never translate"))
        XCTAssertTrue(Prompts.partSystem(language: "pl").contains("Polish"))
        XCTAssertTrue(Prompts.condenseSystem(language: "pl").contains("Write in Polish"))
    }

    func testMergesTasksRepeatedAcrossParts() {
        typealias Item = StructuredSummary.ActionItem
        let merged = StructuredSummary.merged([
            Item(owner: "Unassigned", task: "Send the report.", due: nil),
            Item(owner: "Anna", task: "send the report", due: "Friday"),
            Item(owner: "Marek", task: "fix the build", due: nil),
            Item(owner: "Marek", task: "fix the build on the CI server", due: nil),
            Item(owner: "Ola", task: "fix the build", due: nil),
            Item(owner: "You", task: "call", due: nil),
            Item(owner: "You", task: "call the bank", due: nil),
            Item(owner: "Sam", task: "none", due: nil),
        ])
        XCTAssertEqual(merged, [
            Item(owner: "Anna", task: "Send the report.", due: "Friday"),
            Item(owner: "Marek", task: "fix the build on the CI server", due: nil),
            Item(owner: "Ola", task: "fix the build", due: nil),
            Item(owner: "You", task: "call", due: nil),
            Item(owner: "You", task: "call the bank", due: nil),
        ])
    }
}

final class SummaryBudgetTests: XCTestCase {
    static let finalReply = #"{"summary":"Plan.","key_points":["Release"],"decisions":[]}"#

    func meeting() -> Meeting {
        SummarizerRequestTests().meeting(lines: 12)
    }

    /// Long notes per part: 100 topics of about 50 characters.
    static func partNotes() -> String {
        let topics = (1...100).map { "\"Note \($0) about the release plan and billing page\"" }.joined(separator: ",")
        return #"{"topics":["# + topics + #"],"decisions":[],"action_items":[]}"#
    }

    /// The notes in a final or condensing call, without their fence lines (`<notes-…>` … `</notes-…>`).
    static func notes(in user: String) -> String {
        let fenced = user.components(separatedBy: "consecutive parts of the meeting:\n").last ?? ""
        return unfenced(fenced)
    }

    /// What a condensing call asks to shorten: its user message without the first line and the fence.
    static func condenseNotes(_ user: String) -> String {
        unfenced(String(user.split(separator: "\n", maxSplits: 1).last ?? ""))
    }

    static func unfenced(_ block: String) -> String {
        var lines = block.components(separatedBy: "\n")
        if lines.first?.range(of: "^<notes-[0-9a-f]{8}>$", options: .regularExpression) != nil { lines.removeFirst() }
        if lines.last?.range(of: "^</notes-[0-9a-f]{8}>$", options: .regularExpression) != nil { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    static func condenseCalls(_ calls: [FakeChat.Call]) -> [FakeChat.Call] {
        calls.filter { $0.system.contains("Shorten these meeting notes") }
    }

    /// The final call's notes fit beside its instructions and header.
    static func assertFits(_ call: FakeChat.Call, budget: Int, file: StaticString = #filePath, line: UInt = #line) {
        let notes = notes(in: call.user)
        let overhead = Summarizer.estimatedTokens(call.system) + Summarizer.estimatedTokens(call.user.replacingOccurrences(of: notes, with: ""))
        XCTAssertLessThanOrEqual(notes.count, Summarizer.notesCharacters(budget: budget, overhead: overhead), file: file, line: line)
    }

    func testCondensesManyLevelsUntilTheNotesFitAndEveryPartReachesACall() async throws {
        let fake = FakeChat { call in
            if call.user.contains("of the transcript:") { return Self.partNotes() }
            if call.system.contains("Shorten these meeting notes") {
                // Each condensing keeps three quarters of a group's lines.
                let lines = Self.condenseNotes(call.user).split(separator: "\n")
                return lines.prefix(max(1, lines.count * 3 / 4)).joined(separator: "\n")
            }
            return Self.finalReply
        }
        var summarizer = fake.summarizer(chunkCharacters: 400)
        summarizer.tokenBudget = 1_500
        _ = try await summarizer.summarize(meeting())
        let condense = Self.condenseCalls(fake.calls)
        // Every part's notes went into a condensing call of the first level.
        let parts = fake.calls.filter { $0.user.contains("of the transcript:") }.count
        let condensed = condense.map(\.user).joined(separator: "\n")
        for part in 1...parts { XCTAssertTrue(condensed.contains("Part \(part):"), "part \(part) reached a call") }
        for note in 1...100 { XCTAssertTrue(condensed.contains("Note \(note) about the"), "note \(note) reached a call") }
        // Many levels: a later call condenses what an earlier call wrote, several times over.
        XCTAssertGreaterThan(condense.count, parts * 3)
        let final = try XCTUnwrap(fake.calls.last)
        XCTAssertEqual(final.schema, StructuredSummary.notesSchemaJSON)
        XCTAssertFalse(fake.calls.contains { $0.user.contains("cut to fit") || $0.user.contains("characters of notes;") })
        Self.assertFits(final, budget: 1_500)
    }

    func testAGroupThatDoesntShrinkIsSplitNotCut() async throws {
        // The model shrinks only short groups; long groups come back unchanged and must be split smaller.
        let fake = FakeChat { call in
            if call.user.contains("of the transcript:") { return Self.partNotes() }
            if call.system.contains("Shorten these meeting notes") {
                let notes = Self.condenseNotes(call.user)
                return notes.count > 150 ? notes : String(notes.prefix(notes.count / 2))
            }
            return Self.finalReply
        }
        var summarizer = fake.summarizer(chunkCharacters: 400)
        summarizer.tokenBudget = 1_500
        let summary = try await summarizer.summarize(meeting())
        XCTAssertNil(summary.warnings)
        let condense = Self.condenseCalls(fake.calls)
        XCTAssertTrue(condense.contains { $0.user.count < 250 }, "unshrunk groups were split")
        Self.assertFits(try XCTUnwrap(fake.calls.last), budget: 1_500)
    }

    func testNotesThatNeverShrinkThrowInsteadOfBeingCut() async throws {
        let fake = FakeChat { call in
            if call.user.contains("of the transcript:") { return Self.partNotes() }
            if call.system.contains("Shorten these meeting notes") { return Self.condenseNotes(call.user) }
            return Self.finalReply
        }
        var summarizer = fake.summarizer(chunkCharacters: 400)
        summarizer.tokenBudget = 1_500
        do {
            _ = try await summarizer.summarize(meeting())
            XCTFail("expected notesWontShrink")
        } catch SummarizerError.notesWontShrink {}
        XCTAssertNotEqual(fake.calls.last?.schema, StructuredSummary.notesSchemaJSON, "no final call with cut notes")
    }

    func testTypedNotesAreNeverCut() async throws {
        let fake = FakeChat { call in
            if call.user.contains("of the transcript:") { return Self.partNotes() }
            if call.system.contains("Shorten these meeting notes") { return "Topics:\n- short" }
            return Self.finalReply
        }
        var summarizer = fake.summarizer(chunkCharacters: 400)
        summarizer.tokenBudget = 1_500
        var meeting = meeting()
        let typed = (1...300).map { "- my point \($0)" }.joined(separator: "\n")
        meeting.typedNotes = typed
        _ = try await summarizer.summarize(meeting)
        XCTAssertTrue(try XCTUnwrap(fake.calls.last).user.contains(typed))
    }

    func testSplitLosesNothingAtBoundaries() {
        let texts = [
            (1...200).map { "line \($0) " + String(repeating: "x", count: $0 % 37) }.joined(separator: "\n"),
            "a\n\n\nb\n\n" + String(repeating: "y", count: 500) + "\n\nc\n",
            "\n\nżółć ąę\n" + String(repeating: "ł", count: 333),
        ]
        for text in texts {
            for size in [1, 7, 50, 90, 400] {
                let parts = Summarizer.split(text, maxCharacters: size)
                XCTAssertEqual(parts.joined(), text, "size \(size)")
                XCTAssertTrue(parts.allSatisfy { !$0.isEmpty && $0.count <= size })
            }
        }
    }

    func testBudgetCountsThreeCharactersATokenAndLeavesTheNotesAQuarter() {
        XCTAssertEqual(Summarizer.estimatedTokens(String(repeating: "a", count: 300)), 100)
        XCTAssertEqual(Summarizer.estimatedTokens("ab"), 1)
        XCTAssertEqual(Summarizer.notesCharacters(budget: 1_000, overhead: 200), 2_400)
        XCTAssertEqual(Summarizer.notesCharacters(budget: 1_000, overhead: 5_000), 750)
    }
}

final class PartRetryTests: XCTestCase {
    static let finalReply = #"{"summary":"Plan.","key_points":["Release"],"decisions":[]}"#

    func testUnusableJSONPartIsAskedAgainAsPlainListsAndKeepsItsTasks() async throws {
        let fake = FakeChat { call in
            guard call.user.contains("of the transcript:") else { return Self.finalReply }
            if call.user.contains("Part 1 of") { return SummarizerRequestTests.partReply(call) }
            if call.schema != nil { return "Sorry, here are the notes: topics were billing" }
            XCTAssertTrue(call.system.contains("Action items:\n- [ ] Owner: task"))
            return "Topics:\n- Strona płatności\nDecisions:\n- none\nAction items:\n- [ ] You: naprawić build (piątek)\n- [ ] Unassigned: none"
        }
        let summary = try await fake.summarizer(chunkCharacters: 400).summarize(SummarizerRequestTests().meeting(lines: 12))
        XCTAssertEqual(fake.calls.filter { $0.user.contains("Part 2 of") }.count, 2, "one retry for the broken part")
        XCTAssertEqual(fake.calls.filter { $0.user.contains("Part 1 of") }.count, 1)
        XCTAssertTrue(summary.markdown.contains("- [ ] You: naprawić build (piątek)"), summary.markdown)
        XCTAssertTrue(summary.markdown.contains("- [ ] Anna: wysłać raport"))
        XCTAssertNil(summary.warnings)
        let final = try XCTUnwrap(fake.calls.last)
        XCTAssertTrue(final.user.contains("Part 2:\nTopics:\n- Strona płatności\nDecisions:\n- none"), final.user)
    }

    func testPartThatFailsTwiceLeavesAWarning() async throws {
        let fake = FakeChat { call in
            guard call.user.contains("of the transcript:") else { return Self.finalReply }
            if call.user.contains("Part 1 of") { return SummarizerRequestTests.partReply(call) }
            return "I could not take notes for this part."
        }
        let summary = try await fake.summarizer(chunkCharacters: 400).summarize(SummarizerRequestTests().meeting(lines: 12))
        XCTAssertEqual(summary.warnings, ["Part 2 of 2: the notes couldn't be read, so its action items may be missing."])
        XCTAssertTrue(summary.markdown.contains("- [ ] Anna: wysłać raport"), "other parts' tasks stay")

        let round = try JSONDecoder().decode(MeetingSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(round.warnings, summary.warnings)
        XCTAssertNil(try JSONDecoder().decode(MeetingSummary.self, from: Data(#"{"markdown":"x","model":"m","createdAt":0}"#.utf8)).warnings)
    }

    func testParsesPlainListNotes() throws {
        let notes = try XCTUnwrap(PartNotes.parseFreeText("""
        **Topics:**
        - Billing page
        * Release plan
        ## Decisions
        - Ship on Friday
        Action items:
        - [ ] Anna: send the report (Thursday)
        - [ ] fix the VPN
        - [ ] Marek: none
        """))
        XCTAssertEqual(notes.topics, ["Billing page", "Release plan"])
        XCTAssertEqual(notes.decisions, ["Ship on Friday"])
        XCTAssertEqual(notes.actionItems, [
            StructuredSummary.ActionItem(owner: "Anna", task: "send the report", due: "Thursday"),
            StructuredSummary.ActionItem(owner: "Unassigned", task: "fix the VPN", due: nil),
        ])
        XCTAssertNil(PartNotes.parseFreeText("Topics:\n- Billing"), "no task list, no notes")
        XCTAssertEqual(PartNotes.parseFreeText("Topics:\n- Billing\nAction items:\n- none")?.actionItems, [])
    }
}

final class TypedNotesTests: XCTestCase {
    func meeting(notes: String?) -> Meeting {
        var meeting = SummarizerRequestTests().meeting(lines: 12)
        meeting.typedNotes = notes
        return meeting
    }

    func testNotesAreKeptInMeetingJSON() throws {
        let meeting = meeting(notes: "- billing page\n- release date")
        let round = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        XCTAssertEqual(round.typedNotes, "- billing page\n- release date")
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any])
        old["typedNotes"] = nil
        XCTAssertNil(try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: old)).typedNotes)
    }

    func testClaudeGetsTheNotesAsTheOutline() {
        let claude = ClaudeSummarizer(executable: URL(fileURLWithPath: "/bin/true"), context: "brief")
        let input = claude.input(for: meeting(notes: "  - billing page\n- release date \n"), fence: "4f9a1c2e")
        XCTAssertTrue(input.contains("<user_notes-4f9a1c2e>\n- billing page\n- release date\n</user_notes-4f9a1c2e>\n\n<transcript-4f9a1c2e>"), input)
        XCTAssertTrue(ClaudePrompts.system.contains("<user_notes-…>"))
        XCTAssertTrue(ClaudePrompts.system.contains("Treat them as the outline"))
        XCTAssertFalse(claude.input(for: meeting(notes: " \n ")).contains("<user_notes"), "blank notes are no notes")
        XCTAssertFalse(claude.input(for: meeting(notes: nil)).contains("<user_notes"))
    }

    func testPartsSummaryFollowsTheNotesInItsFinalCall() async throws {
        let fake = FakeChat { call in
            if call.user.contains("of the transcript:") {
                XCTAssertFalse(call.user.contains("The user's notes"), "parts take notes from the transcript only")
                return SummarizerRequestTests.partReply(call)
            }
            return #"{"summary":"Plan.","key_points":["Release"],"decisions":[]}"#
        }
        _ = try await fake.summarizer(chunkCharacters: 400).summarize(meeting(notes: "- billing page"))
        let final = try XCTUnwrap(fake.calls.last)
        XCTAssertTrue(final.user.contains("Treat them as the outline"))
        XCTAssertNotNil(final.user.range(of: "The user's notes:\n<user_notes-[0-9a-f]{8}>\n- billing page\n</user_notes-", options: .regularExpression), final.user)

        let single = FakeChat { _ in #"{"summary":"Plan.","key_points":[],"decisions":[],"action_items":[]}"# }
        _ = try await single.summarizer().summarize(meeting(notes: "- billing page"))
        XCTAssertNotNil(try XCTUnwrap(single.calls.first).user.range(of: "The user's notes:\n<user_notes-[0-9a-f]{8}>\n- billing page\n", options: .regularExpression))
    }
}

final class LongMeetingTitleTests: XCTestCase {
    func meeting(title: String) -> Meeting {
        var meeting = Meeting(title: title, platform: .meet, attendees: ["Anna"], status: .done, language: "en")
        meeting.segments = (0..<60).map { index in
            TranscriptSegment(start: TimeInterval(index * 10), end: TimeInterval(index * 10 + 5), speaker: index.isMultiple(of: 2) ? .me : .remote("Anna"),
                              text: "Line \(index) about the release plan and the billing page.")
        }
        return meeting
    }

    func fake() -> FakeChat {
        FakeChat { call in
            if call.schema == PartNotes.schemaJSON { return #"{"topics":["Release plan."],"decisions":[],"action_items":[]}"# }
            let title = call.schema?.contains("\"title\"") == true ? #","title":"Billing page release plan""# : ""
            return #"{"summary":"Planned the release.","key_points":[],"decisions":[]"# + title + "}"
        }
    }

    func testGenericTitleGetsOneFromTheFinalCall() async throws {
        let fake = fake()
        let summary = try await fake.summarizer(chunkCharacters: 500).summarize(meeting(title: "Browser call"))
        XCTAssertGreaterThan(fake.calls.count, 2)
        XCTAssertEqual(summary.suggestedTitle, "Billing page release plan")
        XCTAssertTrue(fake.calls.last?.system.contains(ClaudePrompts.titleRule) == true)
        // Parts are never asked for a title.
        XCTAssertFalse(fake.calls.dropLast().contains { $0.schema?.contains("\"title\"") == true })
    }

    func testRealTitleIsNotReplaced() async throws {
        let fake = fake()
        let summary = try await fake.summarizer(chunkCharacters: 500).summarize(meeting(title: "Sprint planning"))
        XCTAssertNil(summary.suggestedTitle)
        XCTAssertFalse(fake.calls.contains { $0.system.contains(ClaudePrompts.titleRule) })
    }
}
