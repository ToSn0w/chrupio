import XCTest
@testable import ChrupioCore

final class TicketKeyTests: XCTestCase {
    func testTicketKeysAreFoundInEveryWayTheyAreSaid() {
        XCTAssertEqual(MeetingContext.ticketKeys(in: "wrócę do tego PRJ2,366 i PRJ 4815, potem prj-2041", prefix: "PRJ"),
                       ["PRJ-2366", "PRJ-4815", "PRJ-2041"])
        XCTAssertEqual(MeetingContext.ticketKeys(in: "przepisać ticket 2419, z zadania 2041 i task nr 123", prefix: "PRJ"),
                       ["PRJ-2419", "PRJ-2041", "PRJ-123"])
        XCTAssertEqual(MeetingContext.ticketKeys(in: "spelled out: P.R.J. 2366", prefix: "PRJ"), ["PRJ-2366"])
    }

    func testABareNumberCountsOnlyWhenItIsAKnownTicket() {
        let text = "we moved 2366 and 4815 to done, budget 2025"
        XCTAssertEqual(MeetingContext.ticketKeys(in: text, prefix: "PRJ"), [])
        XCTAssertEqual(MeetingContext.ticketKeys(in: text, prefix: "PRJ", known: ["PRJ-2366", "PRJ-4815"]), ["PRJ-2366", "PRJ-4815"])
        XCTAssertEqual(MeetingContext.ticketKeys(in: "standup at 10:4500", prefix: "PRJ", known: ["PRJ-4500"]), [])
        XCTAssertEqual(MeetingContext.ticketKeys(in: "we closed 4,815 today", prefix: "PRJ", known: ["PRJ-4815"]), ["PRJ-4815"])
    }

    func testEachKeyIsListedOnce() {
        XCTAssertEqual(MeetingContext.ticketKeys(in: "PRJ-2366, ticket 2366 and PRJ 2,366", prefix: "PRJ"), ["PRJ-2366"])
    }

    func testWithoutAPrefixNoTicketsAreFound() {
        XCTAssertEqual(MeetingContext.ticketKeys(in: "ticket 2419 and ABC-2366", prefix: nil), [])
    }

    func testThePrefixIsNormalizedOrRejected() {
        XCTAssertEqual(MeetingContext.normalizedTicketPrefix(" prj- "), "PRJ")
        XCTAssertEqual(MeetingContext.normalizedTicketPrefix("ABC2"), "ABC2")
        XCTAssertNil(MeetingContext.normalizedTicketPrefix(""))
        XCTAssertNil(MeetingContext.normalizedTicketPrefix("A"))
        XCTAssertNil(MeetingContext.normalizedTicketPrefix("2AB"))
        XCTAssertNil(MeetingContext.normalizedTicketPrefix("TOOLONGPREFIX"))
        XCTAssertNil(MeetingContext.normalizedTicketPrefix("A B"))
    }

    func testTheContextFileCarriesThePrefix() throws {
        let json = #"{"ticketPrefix": "prj"}"#
        let context = try JSONDecoder().decode(MeetingContext.self, from: Data(json.utf8))
        XCTAssertEqual(context.ticketPrefix, "prj")
        XCTAssertEqual(context.resolvedTicketPrefix, "PRJ")
        XCTAssertNil(MeetingContext().resolvedTicketPrefix)
    }
}

final class ClaudeSummaryPromptTests: XCTestCase {
    let context: MeetingContext = {
        let json = """
        {"version": 1,
         "ticketPrefix": "PRJ",
         "brief": "Acme is a booking platform for fitness studios.\\nModules: Customer Messaging, Usage reporting.\\nThird line.",
         "vocabulary": ["Acme"],
         "corrections": {"usage report in": "Usage reporting"},
         "people": [{"name": "Marek Wróbel", "aliases": ["Marek"], "role": "PM"}, {"name": "Tomasz Lis", "role": "dev"}],
         "profiles": [{"name": "Core standup", "match": ["team-acme-core"], "attendees": ["Tomasz Lis"],
                       "topics": ["Elasticsearch costs"], "about": "Daily standup of the core team."}],
         "tickets": [
           {"key": "PRJ-2366", "title": "Delivery changes", "assignee": "Marek Wróbel", "status": "In Progress"},
           {"key": "PRJ-2041", "title": "Unify metrics", "assignee": "Tomasz Lis", "status": "To Do"},
           {"key": "PRJ-4000", "title": "Old work", "assignee": "Tomasz Lis", "status": "Done"},
           {"key": "PRJ-4999", "title": "Someone else", "assignee": "Oliver Grant", "status": "To Do"}],
         "workStreams": [{"stream": "Reporting", "area": "BE", "owner": "Tomasz Lis"}],
         "recentDecisions": [{"date": "2026-10-01", "decision": "Ship X"}, {"date": "2026-10-02", "decision": "PRJ-2366 goes first"}],
         "contacts": [{"name": "Kuba", "role": "client", "notes": "private"}]}
        """
        return try! JSONDecoder().decode(MeetingContext.self, from: Data(json.utf8))
    }()

    func meeting() -> Meeting {
        var meeting = Meeting(title: "Huddle in team-acme-core", platform: .slack, selfName: "Łukasz Żurek")
        meeting.language = "pl"
        meeting.segments = [
            TranscriptSegment(start: 0, end: 5, speaker: .me, text: "Marek, wracamy do PRJ2,366?"),
            TranscriptSegment(start: 5, end: 9, speaker: .remote("Speaker 1"), text: "Tak, i jeszcze ticket 5123."),
        ]
        return meeting
    }

    func testPromptPutsTheMeetingAndItsTicketsFirst() throws {
        let meeting = meeting()
        let prompt = context.summaryPrompt(for: meeting, transcript: TranscriptFormatter.plainText(meeting.segments))
        let order = ["## Project brief", "## This meeting", "## Tickets said in this meeting", "## Open tickets of the people in this meeting",
                     "## Other recent tickets", "## People", "## Work streams", "## Recent project decisions", "## Other contacts",
                     "## Correct spellings", "## Known speech-recognition mistakes"]
        let positions = try order.map { try XCTUnwrap(prompt.range(of: $0)?.lowerBound, $0) }
        XCTAssertEqual(positions, positions.sorted())

        XCTAssertTrue(prompt.contains("- PRJ-2366 [In Progress, Marek Wróbel] Delivery changes"))
        XCTAssertTrue(prompt.contains("- PRJ-5123 (not in the ticket list; title unknown)"))
        // Tomasz is a usual attendee of the channel; his open ticket is listed, his done one is not his "open" work.
        let open = try XCTUnwrap(prompt.components(separatedBy: "## Open tickets of the people in this meeting\n").last?
            .components(separatedBy: "\n\n").first)
        XCTAssertEqual(open, "- PRJ-2041 [To Do, Tomasz Lis] Unify metrics")
        XCTAssertTrue(prompt.contains("Daily standup of the core team."))
        XCTAssertTrue(prompt.contains("background only"))
        XCTAssertTrue(prompt.contains("Recorded by Łukasz Żurek"))
        // The decision about a ticket said in the meeting comes first.
        XCTAssertLessThan(try XCTUnwrap(prompt.range(of: "PRJ-2366 goes first")).lowerBound, try XCTUnwrap(prompt.range(of: "Ship X")).lowerBound)
        XCTAssertFalse(prompt.contains("private"))
    }

    func testLocalGuidanceIsShortAndHasNoTopics() throws {
        let meeting = meeting()
        let guidance = try XCTUnwrap(context.localSummaryGuidance(for: meeting, transcript: TranscriptFormatter.plainText(meeting.segments)))
        XCTAssertFalse(guidance.contains("Elasticsearch costs"))
        XCTAssertFalse(guidance.contains("Third line"))
        XCTAssertTrue(guidance.contains("About the project: Acme is a booking platform for fitness studios."))
        XCTAssertTrue(guidance.contains("PRJ-2366"))
        XCTAssertFalse(try XCTUnwrap(context.summaryGuidance(for: meeting)).contains("Usual topics"))
    }

    func testInputWrapsContextAndTranscript() {
        let summarizer = ClaudeSummarizer(executable: URL(fileURLWithPath: "/bin/true"), context: "CTX")
        let input = summarizer.input(for: meeting(), fence: "4f9a1c2e")
        XCTAssertTrue(input.hasPrefix("<project_context-4f9a1c2e>\nCTX\n</project_context-4f9a1c2e>\n\n<transcript-4f9a1c2e>\n"))
        XCTAssertTrue(input.contains("Spoken language: Polish"))
        XCTAssertTrue(input.contains("wracamy do PRJ2,366"), "the transcript itself is not corrected")
        XCTAssertTrue(input.hasSuffix("</transcript-4f9a1c2e>\n\nWrite the notes for this meeting."))
    }

    func testSystemPromptSaysWhatToDoWithoutAProjectContext() {
        XCTAssertTrue(ClaudePrompts.system.contains("Without a project context, fix only what is obvious from the transcript itself."))
    }
}

final class ClaudeSummarizerTests: XCTestCase {
    func testTheTicketRuleIsAddedOnlyWithAPrefix() {
        var claude = ClaudeSummarizer(executable: URL(fileURLWithPath: "/nonexistent"))
        let meeting = Meeting(title: "Weekly sync", platform: .zoom)
        XCTAssertFalse(claude.system(for: meeting).contains("ticket keys look like"))
        claude.ticketPrefix = "PRJ"
        XCTAssertTrue(claude.system(for: meeting).contains("this project's ticket keys look like PRJ-1234"))
    }

    var folder: URL!
    var fake: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fake = folder.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        dir="$(dirname "$0")"
        for arg in "$@"; do printf '%s\\n<<END>>\\n' "$arg"; done > "$dir/argv.txt"
        cat > "$dir/stdin.txt"
        env > "$dir/env.txt"
        echo call >> "$dir/calls.txt"
        pwd > "$dir/pwd.txt"
        case "$(cat "$dir/mode")" in
          ok) cat "$dir/reply.json" ;;
          off) touch "$dir/off"; cat "$dir/reply.json" ;;
          login) echo '{"type":"result","is_error":true,"result":"Not logged in. Please run /login"}'; exit 1 ;;
          fail) echo "API error 529 overloaded" >&2; exit 2 ;;
          slow) sleep 10 ;;
          offslow) touch "$dir/off"; sleep 10 ;;
          model) echo '{"type":"result","is_error":true,"result":"There is an issue with the selected model (haiku). It may not exist or you may not have access to it."}'; exit 1 ;;
          old) echo "error: unknown option '--safe-mode'" >&2; exit 1 ;;
        esac
        """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func meeting() -> Meeting {
        var meeting = Meeting(title: "Standup", platform: .meet, selfName: "Łukasz")
        meeting.language = "en"
        meeting.segments = [TranscriptSegment(start: 0, end: 70, speaker: .me, text: "I will fix PRJ-2366 today.")]
        return meeting
    }

    func summarizer(timeout: TimeInterval = 30) -> ClaudeSummarizer {
        var claude = ClaudeSummarizer(executable: fake, model: "claude-test", configDir: "~/.claude-personal", context: "CONTEXT", timeout: timeout,
                                      home: "/Users/someone", workingDirectory: folder.appendingPathComponent("cwd", isDirectory: true))
        claude.ticketPrefix = "PRJ"
        return claude
    }

    func setMode(_ mode: String, reply: String = "") throws {
        try mode.write(to: folder.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        try reply.write(to: folder.appendingPathComponent("reply.json"), atomically: true, encoding: .utf8)
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    static let reply = """
    {"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{
      "tldr":"Łukasz fixes the delivery bug.",
      "people":[{"name":"Łukasz","status":["Working on PRJ-2366"],"blockers":[],"next_steps":["Fix it today"]}],
      "decisions":[],
      "action_items":[{"owner":"Łukasz","task":"Fix the delivery bug","tickets":["PRJ2366"],"due":"today"},
                      {"owner":"Speaker 2","task":"Check prod","tickets":[]}]}}
    """

    func testDefaultModelIsTheHaikuAlias() {
        XCTAssertEqual(ClaudeSummarizer.defaultModel, "haiku")
        XCTAssertTrue(ClaudeSummarizer(executable: fake).arguments.contains("haiku"))
    }

    func testUnavailableModelAndOldCLIAreTheirOwnErrors() async throws {
        try setMode("model")
        do {
            _ = try await summarizer().summarize(meeting())
            XCTFail("expected an error")
        } catch let error as ClaudeSummarizerError {
            guard case .modelUnavailable(let message) = error else { return XCTFail("got \(error)") }
            XCTAssertTrue(message.contains("issue with the selected model"))
            XCTAssertEqual(error.reason, "model unavailable")
        }
        try setMode("old")
        do {
            _ = try await summarizer().summarize(meeting())
            XCTFail("expected an error")
        } catch let error as ClaudeSummarizerError {
            guard case .outdated = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(error.reason, "update Claude Code")
            XCTAssertEqual(error.localizedDescription, "Claude Code is too old for Chrupio's summaries. Run claude update, then try again.")
        }
    }

    func testParseRecognisesModelAndFlagErrors() {
        XCTAssertThrowsError(try ClaudeSummarizer.parse(stdout: #"{"is_error":true,"result":"API Error: 404 {\"type\":\"error\",\"error\":{\"type\":\"not_found_error\",\"message\":\"model: claude-old\"}}"}"#, stderr: "", status: 1)) {
            guard case .modelUnavailable = $0 as? ClaudeSummarizerError else { return XCTFail("got \($0)") }
        }
        XCTAssertThrowsError(try ClaudeSummarizer.parse(stdout: "", stderr: "error: unrecognized option '--tools'", status: 1)) {
            guard case .outdated = $0 as? ClaudeSummarizerError else { return XCTFail("got \($0)") }
        }
        // Other failures keep their old errors.
        XCTAssertThrowsError(try ClaudeSummarizer.parse(stdout: "", stderr: "API error 529 overloaded", status: 2)) {
            XCTAssertEqual($0 as? ClaudeSummarizerError, .failed("API error 529 overloaded"))
        }
    }

    func testModelDisplayName() {
        XCTAssertEqual(ClaudeSummarizer.displayName(model: "haiku"), "Claude Haiku")
        XCTAssertEqual(ClaudeSummarizer.displayName(model: "haiku, edited"), "Claude Haiku, edited")
        XCTAssertEqual(ClaudeSummarizer.displayName(model: "claude-haiku-5-5"), "claude-haiku-5-5")
        XCTAssertEqual(ClaudeSummarizer.displayName(model: "local"), "local")
        XCTAssertTrue(ClaudeSummarizer.isClaudeModel("haiku"))
        XCTAssertTrue(ClaudeSummarizer.isClaudeModel("haiku, edited"))
        XCTAssertTrue(ClaudeSummarizer.isClaudeModel("claude-haiku-5-5, edited"))
        XCTAssertFalse(ClaudeSummarizer.isClaudeModel("qwen3:8b"))
        XCTAssertTrue(ClaudeSummarizer.isClaudeModel("Haiku"))
        XCTAssertTrue(ClaudeSummarizer.isClaudeModel("Claude-Haiku-5-5"))
        XCTAssertTrue(ClaudeSummarizer.isClaudeModel("Claude Code, edited"))
        XCTAssertEqual(ClaudeSummarizer.displayName(model: "Haiku"), "Claude Haiku")
    }

    func testSummaryAttribution() {
        XCTAssertEqual(ClaudeSummarizer.attribution(model: "haiku"), "Claude Haiku via Claude Code")
        XCTAssertEqual(ClaudeSummarizer.attribution(model: "haiku, edited"), "Claude Haiku, edited via Claude Code")
        XCTAssertEqual(ClaudeSummarizer.attribution(model: "Claude-Haiku-5-5"), "Claude-Haiku-5-5 via Claude Code")
        XCTAssertEqual(ClaudeSummarizer.attribution(model: "qwen3:8b"), "qwen3:8b on this Mac")
        // An edit through Claude Code of a meeting with no summary, or a summary saved without a model.
        XCTAssertEqual(ClaudeSummarizer.attribution(model: "Claude Code, edited"), "Claude Code, edited")
        XCTAssertEqual(ClaudeSummarizer.attribution(model: "Claude Code"), "Claude Code")
        XCTAssertEqual(ClaudeSummarizer.attribution(model: ""), "Claude Code")
        XCTAssertEqual(ClaudeSummarizer.attribution(model: " "), "Claude Code")
        XCTAssertEqual(ClaudeSummarizer.attribution(model: ", edited"), "Claude Code, edited")
    }

    func testModelUnavailableNeedsASpecificMessage() {
        XCTAssertTrue(ClaudeSummarizerError.isModelUnavailable("There is an issue with the selected model (haiku)."))
        XCTAssertTrue(ClaudeSummarizerError.isModelUnavailable(#"{"type":"not_found_error","message":"model: claude-old"}"#))
        XCTAssertTrue(ClaudeSummarizerError.isModelUnavailable("model claude-old not found"))
        XCTAssertTrue(ClaudeSummarizerError.isModelUnavailable("The model claude-old does not exist"))
        XCTAssertTrue(ClaudeSummarizerError.isModelUnavailable("Invalid model name"))
        XCTAssertFalse(ClaudeSummarizerError.isModelUnavailable("The model is temporarily not available, try again later"))
    }

    func testSuccessfulReplyMentioningLoginIsNotALoginError() async throws {
        let notes = """
        {"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{
          "tldr":"Users who are not logged in land on the /login page.","people":[],"decisions":[],"action_items":[]}}
        """
        try setMode("ok", reply: notes)
        let summary = try await summarizer().summarize(meeting())
        XCTAssertTrue(summary.markdown.contains("the /login page"))

        let text = #"{"type":"result","subtype":"success","is_error":false,"result":"Thanks! Fix the /login page for people who are not logged in."}"#
        try setMode("ok", reply: text)
        let draft = try await summarizer().draftFollowUp(meeting())
        XCTAssertEqual(draft, "Thanks! Fix the /login page for people who are not logged in.")
    }

    func testSuccessfulCallIsIsolatedAndRendersTheChecklist() async throws {
        try setMode("ok", reply: Self.reply)
        let summary = try await summarizer().summarize(meeting())
        XCTAssertEqual(summary.model, "claude-test")

        let argv = try read("argv.txt").components(separatedBy: "\n<<END>>\n").dropLast()
        for flag in ["-p", "--safe-mode", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence"] {
            XCTAssertTrue(argv.contains(flag), flag)
        }
        func value(_ flag: String) -> String? { argv.firstIndex(of: flag).map { argv[argv.index(after: $0)] } }
        XCTAssertEqual(value("--output-format"), "json")
        XCTAssertEqual(value("--model"), "claude-test")
        XCTAssertEqual(value("--tools"), "")
        XCTAssertEqual(value("--setting-sources"), "")
        XCTAssertEqual(value("--settings"), #"{"disableAllHooks":true}"#)
        XCTAssertEqual(value("--mcp-config"), #"{"mcpServers":{}}"#)
        XCTAssertEqual(value("--json-schema"), ClaudeNotes.schemaJSON)
        XCTAssertTrue(value("--system-prompt")?.contains("Report only what was said in this meeting") == true)

        let stdin = try read("stdin.txt")
        XCTAssertNotNil(stdin.range(of: "^<project_context-[0-9a-f]{8}>\nCONTEXT\n", options: .regularExpression), stdin)
        XCTAssertTrue(stdin.contains("I will fix PRJ-2366 today."))

        let env = try read("env.txt")
        XCTAssertTrue(env.contains("HOME=/Users/someone\n"))
        XCTAssertTrue(env.contains("CLAUDE_CONFIG_DIR=" + ("~/.claude-personal" as NSString).expandingTildeInPath + "\n"))
        XCTAssertFalse(env.contains("CLAUDECODE="), "the app's own environment is not passed on")
        XCTAssertTrue(try read("pwd.txt").contains("cwd"))

        let items = ActionItem.parse(summary.markdown)
        XCTAssertEqual(items.map(\.text), ["Łukasz: Fix the delivery bug (PRJ-2366; today)", "Unassigned: Check prod"])
        XCTAssertTrue(summary.markdown.hasPrefix("## Summary\nŁukasz fixes the delivery bug.\n\n## By person\n\n### Łukasz\n- Working on PRJ-2366\n- **Next:** Fix it today"))
        XCTAssertTrue(summary.markdown.contains("## Decisions\n- None recorded"))
    }

    func calls() -> Int {
        ((try? read("calls.txt")) ?? "").split(separator: "\n").count
    }

    func testNothingIsSentWhileSummariesAreOff() async throws {
        try setMode("ok", reply: Self.reply)
        var claude = summarizer()
        claude.isEnabled = { false }
        do {
            _ = try await claude.summarize(meeting())
            XCTFail("expected ClaudeSummariesOff")
        } catch is ClaudeSummariesOff {}
        do {
            _ = try await claude.draftFollowUp(meeting())
            XCTFail("expected ClaudeSummariesOff")
        } catch is ClaudeSummariesOff {}
        XCTAssertEqual(calls(), 0)
    }

    func testTurningSummariesOffStopsALongSummaryBeforeItsNextCall() async throws {
        try setMode("ok", reply: Self.reply)
        var long = meeting()
        long.segments = (0..<6).map { TranscriptSegment(start: Double($0) * 10, end: Double($0) * 10 + 5, speaker: .me, text: "Line \($0) " + String(repeating: "x", count: 40)) }
        var claude = summarizer()
        claude.singleCallCharacters = 100
        claude.partCharacters = 120
        // On for the first call only: the switch goes off while part 1 is written.
        let checks = CallCounter()
        claude.isEnabled = { checks.next() == 1 }
        do {
            _ = try await claude.summarize(long)
            XCTFail("expected ClaudeSummariesOff")
        } catch is ClaudeSummariesOff {}
        XCTAssertEqual(calls(), 1)
        XCTAssertEqual(checks.value, 2)
    }

    func testTurningSummariesOffDuringASingleCallDropsItsResult() async throws {
        // The fake claude turns the switch off while it answers, as the user would mid-call.
        try setMode("off", reply: Self.reply)
        var claude = summarizer()
        let off = folder.appendingPathComponent("off")
        claude.isEnabled = { !FileManager.default.fileExists(atPath: off.path) }
        do {
            _ = try await claude.summarize(meeting())
            XCTFail("expected ClaudeSummariesOff")
        } catch is ClaudeSummariesOff {}
        XCTAssertEqual(calls(), 1)
    }

    func testTurningSummariesOffBeforeATimeoutIsAStopNotATimeout() async throws {
        // Switched off while Claude is still answering, then the call times out: a stop, not a failure to retry.
        try setMode("offslow")
        var claude = summarizer(timeout: 1)
        let off = folder.appendingPathComponent("off")
        claude.isEnabled = { !FileManager.default.fileExists(atPath: off.path) }
        do {
            _ = try await claude.summarize(meeting())
            XCTFail("expected ClaudeSummariesOff")
        } catch is ClaudeSummariesOff {}
    }

    func testNotLoggedIn() async throws {
        try setMode("login")
        do {
            _ = try await summarizer().summarize(meeting())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ClaudeSummarizerError, .notLoggedIn)
        }
    }

    func testFailureCarriesTheMessage() async throws {
        try setMode("fail")
        do {
            _ = try await summarizer().summarize(meeting())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ClaudeSummarizerError, .failed("API error 529 overloaded"))
        }
    }

    func testTimeout() async throws {
        try setMode("slow")
        do {
            _ = try await summarizer(timeout: 1).summarize(meeting())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ClaudeSummarizerError, .timedOut)
        }
    }

    func testMissingExecutable() async throws {
        var summarizer = summarizer()
        summarizer.executable = folder.appendingPathComponent("nothing")
        do {
            _ = try await summarizer.summarize(meeting())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ClaudeSummarizerError, .notInstalled)
        }
    }

    func testEmptyTranscriptIsNotSent() async throws {
        try setMode("ok", reply: Self.reply)
        do {
            _ = try await summarizer().summarize(Meeting(title: "x", platform: .meet))
            XCTFail("expected an error")
        } catch SummarizerError.emptyTranscript {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("argv.txt").path))
    }

    func testFindExecutable() {
        let found = ClaudeSummarizer.findExecutable(home: "/Users/x") { $0 == "/opt/homebrew/bin/claude" || $0 == "/Users/x/.claude/local/claude" }
        XCTAssertEqual(found?.path, "/opt/homebrew/bin/claude")
        XCTAssertEqual(ClaudeSummarizer.findExecutable(home: "/Users/x") { $0 == "/Users/x/.local/bin/claude" }?.path, "/Users/x/.local/bin/claude")
        XCTAssertNil(ClaudeSummarizer.findExecutable(home: "/Users/x") { _ in false })
    }
}

final class ClaudeNotesTests: XCTestCase {
    func testParseReadsResultTextWhenThereIsNoStructuredOutput() throws {
        let notes = #"{\"tldr\":\"Short.\",\"people\":[],\"decisions\":[\"Ship it\"],\"action_items\":[]}"#
        let stdout = #"{"type":"result","is_error":false,"result":"```json\n"# + notes + #"\n```"}"#
        let parsed = try ClaudeSummarizer.parse(stdout: stdout, stderr: "", status: 0)
        XCTAssertEqual(parsed.tldr, "Short.")
        XCTAssertEqual(parsed.decisions, ["Ship it"])
    }

    func testParseRejectsErrorsAndEmptyReplies() {
        XCTAssertThrowsError(try ClaudeSummarizer.parse(stdout: #"{"is_error":true,"result":"Credit balance is too low"}"#, stderr: "", status: 1)) {
            XCTAssertEqual($0 as? ClaudeSummarizerError, .failed("Credit balance is too low"))
        }
        XCTAssertThrowsError(try ClaudeSummarizer.parse(stdout: #"{"is_error":false,"subtype":"error_max_turns"}"#, stderr: "", status: 0)) {
            XCTAssertEqual($0 as? ClaudeSummarizerError, .failed("the reply had no notes (error_max_turns)"))
        }
        XCTAssertThrowsError(try ClaudeSummarizer.parse(stdout: "", stderr: "Invalid API key · Please run /login", status: 1)) {
            XCTAssertEqual($0 as? ClaudeSummarizerError, .notLoggedIn)
        }
    }

    func testPolishMarkdownAndActionItemSuffixes() {
        let notes = ClaudeNotes(
            tldr: "Krótko.",
            people: [.init(name: "Tomasz Lis", status: ["Kolumny discount"], blockers: ["Brak danych"], nextSteps: []),
                     .init(name: "Speaker 3", status: ["None"], blockers: [], nextSteps: [])],
            decisions: ["Elasticsearch na osobnym klastrze"],
            actionItems: [.init(owner: "Tomasz Lis", task: "Tomasz Lis: Dodać kolumny discount", tickets: ["PRJ-2041", "prj 2041"], due: "(do piątku)"),
                          .init(owner: "Others", task: "Sprawdzić VPN")])
        let markdown = notes.markdown(language: "pl", ticketPrefix: "PRJ")
        XCTAssertTrue(markdown.contains("## Kto co robi\n\n### Tomasz Lis\n- Kolumny discount\n- **Bloker:** Brak danych\n\n## Decyzje"))
        XCTAssertFalse(markdown.contains("Speaker 3"))
        XCTAssertEqual(ActionItem.parse(markdown).map(\.text),
                       ["Tomasz Lis: Dodać kolumny discount (PRJ-2041; do piątku)", "Unassigned: Sprawdzić VPN"])
    }
}

/// Counts calls from a `@Sendable` closure.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func next() -> Int { lock.withLock { count += 1; return count } }
}
