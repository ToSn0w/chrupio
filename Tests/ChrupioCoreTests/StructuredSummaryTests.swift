import XCTest
@testable import ChrupioCore

final class MeetingPolicyTests: XCTestCase {
    func testLanguagePinnedOnlyAfterThreeAgreeingMoments() {
        var vote = LanguageVote()
        XCTAssertNil(vote.record("en", speechCount: 3, at: 0), "one moment is not enough")
        XCTAssertNil(vote.record("en", speechCount: 3, at: 0.4), "the other track of the same moment doesn't count again")
        XCTAssertNil(vote.record("en", speechCount: 3, at: 30))
        XCTAssertNil(vote.record("pl", speechCount: 3, at: 60), "a disagreeing moment resets the streak")
        XCTAssertNil(vote.record("pl", speechCount: 1, at: 90), "too little speech doesn't count")
        XCTAssertNil(vote.record(nil, speechCount: 5, at: 120))
        XCTAssertNil(vote.record("pl", speechCount: 2, at: 150))
        XCTAssertEqual(vote.record("pl", speechCount: 2, at: 180), "pl")
    }
}

final class StructuredSummaryTests: XCTestCase {
    func testClaudeMarkdownShowsTheDeadlineDateAndStillParses() throws {
        let notes = ClaudeNotes(tldr: "Sync.", people: [], decisions: [],
                                actionItems: [.init(owner: "Anna Nowak", task: "Send the deck", tickets: ["PRJ-12"], due: "do piątku", dueDate: "2026-11-13")])
        let markdown = notes.markdown(language: "en", ticketPrefix: "PRJ")
        XCTAssertTrue(markdown.contains("- [ ] Anna Nowak: Send the deck (PRJ-12; do piątku, 2026-11-13)"), markdown)
        XCTAssertEqual(ActionItem.parse(markdown).map(\.text), ["Anna Nowak: Send the deck (PRJ-12; do piątku, 2026-11-13)"])
        let json = #"{"action":"Send the deck","owner":"Anna Nowak","deadline_date":"2026-11-13","source_quote":"q","confidence":0.9,"tickets":[]}"#
        XCTAssertEqual(try JSONDecoder().decode(ClaudeNotes.ActionItem.self, from: Data(json.utf8)).structured.deadlineDate, "2026-11-13")
        XCTAssertTrue(ClaudeNotes.schemaJSON.contains("deadline_date"))
        XCTAssertFalse(ClaudeNotes.schemaJSON.contains(#""required":["action","owner","source_quote","confidence","tickets","deadline_date"#))
    }

    func testADeadlineDateEqualToTheSpokenDeadlineIsShownOnce() {
        let notes = ClaudeNotes(tldr: "Sync.", people: [], decisions: [],
                                actionItems: [.init(owner: "Anna Nowak", task: "Send the deck", tickets: [], due: " 2026-11-13", dueDate: "2026-11-13")])
        let markdown = notes.markdown(language: "en")
        XCTAssertTrue(markdown.contains("- [ ] Anna Nowak: Send the deck (2026-11-13)"), markdown)
        XCTAssertFalse(markdown.contains("2026-11-13, 2026-11-13"), markdown)
    }

    func testLongMeetingPartKeepsTheDeadlineDate() async throws {
        let fake = FakeChat { call in
            if call.user.contains("of the transcript:") {
                return #"{"topics":["Release"],"decisions":[],"action_items":[{"owner":"Anna Nowak","task":"Send the deck","due":"Friday","deadline_date":"2026-11-13"}]}"#
            }
            return #"{"summary":"Release.","key_points":["Release"],"decisions":[]}"#
        }
        var meeting = SummarizerRequestTests().meeting(lines: 12, language: "en")
        meeting.attendees = ["Anna Nowak"]
        meeting.startedAt = ISO8601DateFormatter().date(from: "2026-11-12T10:00:00Z")!
        let summary = try await fake.summarizer(chunkCharacters: 400).summarize(meeting)
        XCTAssertEqual(summary.actionItems?.first?.deadlineDate, "2026-11-13")
    }

    func testRendersSameMarkdownAsFreeText() throws {
        let json = """
        {"summary":"Launch planning.","key_points":["Billing page ships Friday"],"decisions":[],
         "action_items":[{"owner":"Anna","task":"write release notes by Thursday","due":"Thursday"},
                         {"owner":"Others","task":"fix rounding bug","due":"none"},{"owner":"Sam","task":"None"}]}
        """
        let summary = try XCTUnwrap(StructuredSummary.decode(json))
        XCTAssertEqual(summary.markdown, """
        ## Summary
        Launch planning.

        ## Key points
        - Billing page ships Friday

        ## Decisions
        - None recorded

        ## Action items
        - [ ] Anna: write release notes (Thursday)
        - [ ] Unassigned: fix rounding bug
        """)
        XCTAssertEqual(MCPServer.actionItems(in: summary.markdown, openOnly: true).count, 2)
    }

    /// qwen2.5:7b put the whole Markdown on one line in "summary" and bulleted its own list items.
    func testDropsMarkdownStuffedIntoSummaryAndDoubledBullets() throws {
        let json = """
        {"summary":"# Key points - FTP access problems. ## Decisions Release moves to Monday. ## Action items - Speaker 2: create test folder",
         "key_points":["- FTP access problems","* Release moves to Monday"],"decisions":["1. Release moves to Monday"],
         "action_items":[{"owner":"Speaker 2","task":"- [ ] create test folder"}]}
        """
        let summary = try XCTUnwrap(StructuredSummary.decode(json))
        XCTAssertEqual(summary.markdown, """
        ## Summary
        FTP access problems. Release moves to Monday.

        ## Key points
        - FTP access problems
        - Release moves to Monday

        ## Decisions
        - Release moves to Monday

        ## Action items
        - [ ] Speaker 2: create test folder
        """)
    }

    func testKeepsProseBeforeAnInlineHeadingAndHashesInWords() throws {
        let json = #"{"summary":"We ported the C# client. ## Key points - x","key_points":[],"decisions":[],"action_items":[]}"#
        XCTAssertTrue(try XCTUnwrap(StructuredSummary.decode(json)).markdown.hasPrefix("## Summary\nWe ported the C# client.\n\n"))
        let headed = ###"{"summary":"## Summary Short call. ## Decisions None","key_points":[],"decisions":[],"action_items":[]}"###
        XCTAssertTrue(try XCTUnwrap(StructuredSummary.decode(headed)).markdown.hasPrefix("## Summary\nShort call.\n\n"))
    }

    func testRejectsUnusableReplies() {
        XCTAssertNil(StructuredSummary.decode("## Summary\nNot JSON"))
        XCTAssertNil(StructuredSummary.decode(#"{"summary":" ","key_points":[],"decisions":[],"action_items":[]}"#))
        XCTAssertNotNil(StructuredSummary.decode("```json\n{\"summary\":\"Ok\",\"key_points\":[],\"decisions\":[],\"action_items\":[]}\n```"))
    }
}

final class ExtensionPackageTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(UUID())", isDirectory: true)
        let source = base.appendingPathComponent("source/lib", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"version":"0.2.0"}"#.utf8).write(to: base.appendingPathComponent("source/manifest.json"))
        try Data("a".utf8).write(to: source.appendingPathComponent("common.js"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    func testInstallCopiesOnlyWhenChangedAndReplacesStaleFiles() throws {
        let source = base.appendingPathComponent("source"), destination = base.appendingPathComponent("Desktop/Chrupio Chrome Extension")
        XCTAssertTrue(try ExtensionPackage.install(from: source, to: destination))
        XCTAssertEqual(ExtensionPackage.version(in: destination), "0.2.0")
        XCTAssertFalse(try ExtensionPackage.install(from: source, to: destination), "unchanged copy is left alone")

        try Data("stale".utf8).write(to: destination.appendingPathComponent("old.js"))
        try Data("b".utf8).write(to: source.appendingPathComponent("lib/common.js"))
        XCTAssertTrue(try ExtensionPackage.install(from: source, to: destination))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("lib/common.js"), encoding: .utf8), "b")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("old.js").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["Chrupio Chrome Extension"], "no staging folders left behind")
    }

    func testInstallGoesToApplicationSupportAndLeavesDesktopCopyAlone() throws {
        let source = base.appendingPathComponent("source")
        let support = base.appendingPathComponent("Support/Chrupio", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        XCTAssertEqual(ExtensionPackage.installedFolder(support: support).path, support.appendingPathComponent("ChromeExtension").path)
        XCTAssertFalse(ExtensionPackage.hasLegacyDesktopCopy(home: home))

        let desktop = ExtensionPackage.legacyDesktopFolder(home: home)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        try Data(#"{"version":"0.1.0"}"#.utf8).write(to: desktop.appendingPathComponent("manifest.json"))
        XCTAssertTrue(ExtensionPackage.hasLegacyDesktopCopy(home: home))

        let installed = try ExtensionPackage.install(from: source, support: support)
        XCTAssertEqual(installed, ExtensionPackage.installedFolder(support: support))
        XCTAssertEqual(ExtensionPackage.version(in: installed), "0.2.0")
        XCTAssertEqual(ExtensionPackage.version(in: desktop), "0.1.0", "old Desktop copy untouched")

        XCTAssertFalse(ExtensionPackage.needsRefresh(from: source, support: support))
        try Data(#"{"version":"0.3.0"}"#.utf8).write(to: source.appendingPathComponent("manifest.json"))
        XCTAssertTrue(ExtensionPackage.needsRefresh(from: source, support: support), "app update brings a new version")
        try ExtensionPackage.install(from: source, support: support)
        XCTAssertEqual(ExtensionPackage.version(in: installed), "0.3.0")
    }

    func testLaunchInstallsForFreshUserAndRefreshesOnlyWhenChanged() throws {
        let source = base.appendingPathComponent("source")
        let support = base.appendingPathComponent("Support/Chrupio", isDirectory: true)
        XCTAssertTrue(try ExtensionPackage.installIfNeeded(from: source, support: support), "fresh user gets the folder")
        XCTAssertEqual(ExtensionPackage.version(in: ExtensionPackage.installedFolder(support: support)), "0.2.0")
        XCTAssertFalse(try ExtensionPackage.installIfNeeded(from: source, support: support), "unchanged copy is left alone")
        try Data(#"{"version":"0.3.0"}"#.utf8).write(to: source.appendingPathComponent("manifest.json"))
        XCTAssertTrue(try ExtensionPackage.installIfNeeded(from: source, support: support))
    }

    func testFailedCopyLeavesNoStagingFolder() throws {
        let source = base.appendingPathComponent("source")
        let locked = source.appendingPathComponent("lib/locked.js")
        try Data("x".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let parent = base.appendingPathComponent("Support", isDirectory: true)
        XCTAssertThrowsError(try ExtensionPackage.install(from: source, to: parent.appendingPathComponent("ChromeExtension")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [], "staging folder removed")
    }

    func testVersionComparison() {
        XCTAssertTrue(ExtensionPackage.isOlder("0.1.0", than: "0.2.0"))
        XCTAssertTrue(ExtensionPackage.isOlder("0.9.1", than: "0.10.0"))
        XCTAssertFalse(ExtensionPackage.isOlder("0.2", than: "0.2.0"))
        XCTAssertFalse(ExtensionPackage.isOlder("1.0.0", than: "0.9.9"))
    }

    func testEventDecodesWithAndWithoutExtensionVersion() throws {
        let new = try JSONDecoder().decode(ExtensionEvent.self, from: Data(#"{"type":"meeting","platform":"meet","tabId":1,"extensionVersion":"0.2.0"}"#.utf8))
        XCTAssertEqual(new.extensionVersion, "0.2.0")
        let old = try JSONDecoder().decode(ExtensionEvent.self, from: Data(#"{"type":"meeting","platform":"meet","tabId":1}"#.utf8))
        XCTAssertNil(old.extensionVersion)
    }
}

final class StoredSummaryTests: XCTestCase {
    /// A summary saved before the cleanup existed: the summary paragraph repeated every section on one line.
    func testStuffedSummaryIsCleanedWhenRead() throws {
        let stored = "## Summary\n## Key points - VM cleanup. - Manifest names.  ## Action items - Łukasz: rename manifests\n\n"
            + "## Key points\n- VM cleanup\n- Manifest names.\n\n## Decisions\n- None recorded\n\n## Action items\n- [ ] Łukasz: rename manifests"
        let json = try JSONEncoder().encode(["markdown": stored, "model": "qwen2.5:7b", "createdAt": "2026-10-20T07:43:00Z"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(MeetingSummary.self, from: json)
        XCTAssertEqual(summary.markdown, "## Summary\nVM cleanup. Manifest names.\n\n"
            + "## Key points\n- VM cleanup\n- Manifest names.\n\n## Decisions\n- None recorded\n\n## Action items\n- [ ] Łukasz: rename manifests")
    }

    func testCleanSummaryIsUnchanged() {
        let clean = "## Summary\nWe ported the C# client.\n\n## Key points\n- x"
        XCTAssertEqual(MeetingSummary.tidied(clean), clean)
        XCTAssertEqual(MeetingSummary.tidied("Free text without headings"), "Free text without headings")
        XCTAssertEqual(MeetingSummary.tidied("## Summary\n\n\n## Key points\n- - Backup plan\n- 2. Costs\n\n## Action items\n- [ ] - Ann: test"),
                       "## Summary\nBackup plan. Costs.\n\n## Key points\n- Backup plan\n- Costs\n\n## Action items\n- [ ] Ann: test")
    }

    func testActionItemTicketsAreShownOnlyWithAPrefix() {
        let notes = ClaudeNotes(tldr: "Done.", people: [], decisions: [],
                                actionItems: [.init(owner: "Anna Nowak", task: "Ship the export", tickets: ["prj 2366"])])
        XCTAssertTrue(notes.markdown(language: "en", ticketPrefix: "PRJ").contains("Ship the export (PRJ-2366)"))
        let plain = notes.markdown(language: "en", ticketPrefix: nil)
        XCTAssertTrue(plain.contains("Ship the export"))
        XCTAssertFalse(plain.contains("PRJ-2366"))
    }
}
