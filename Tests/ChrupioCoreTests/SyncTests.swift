import Foundation
@testable import ChrupioCore
import XCTest

private func sampleMeeting(
    title: String = "Pricing review",
    startedAt: Date = Date(timeIntervalSince1970: 1_790_000_000),
    status: MeetingStatus = .done,
    summary: String? = "## Overview\nAgreed on the new price.\n\n## Action items\n- [ ] Sam: send the contract (Monday)\n- [ ] You: update the deck"
) -> Meeting {
    Meeting(
        title: title, platform: .meet, startedAt: startedAt, endedAt: startedAt + 1_800,
        attendees: ["Sam Lee", "Anna"], selfName: "Lukasz", url: "https://meet.google.com/abc-defg-hij",
        segments: [
            TranscriptSegment(start: 0, end: 4, speaker: .me, text: "Can we talk about pricing?"),
            TranscriptSegment(start: 5, end: 9, speaker: .remote("Sam Lee"), text: "Yes, the contract goes out Monday."),
        ],
        summary: summary.map { MeetingSummary(markdown: $0, model: "llama3.2:3b") },
        status: status
    )
}

final class MeetingExporterTests: XCTestCase {
    var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID())")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testExportWritesFrontmatterAndBody() throws {
        let meeting = sampleMeeting(title: "Q3: plan / \"draft\"")
        let url = try XCTUnwrap(MeetingExporter(folder: folder).export(meeting))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int, 0o700,
                       "a folder Chrupio creates is private")
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        XCTAssertFalse(url.lastPathComponent.contains(":"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(" [\(meeting.id.uuidString.prefix(8).lowercased())].md"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\nid: \(meeting.id.uuidString)\n"))
        XCTAssertTrue(text.contains(#"title: "Q3: plan / \"draft\"""#))
        XCTAssertTrue(text.contains(#"attendees: ["Sam Lee", "Anna"]"#))
        XCTAssertTrue(text.contains("duration_minutes: 30"))
        XCTAssertTrue(text.contains("- [ ] Sam: send the contract (Monday)"))
        XCTAssertTrue(text.contains("**Sam Lee** [00:05]: Yes, the contract goes out Monday."))
    }

    func testRenameReplacesOldFileAndRemoveDeletesIt() throws {
        let exporter = MeetingExporter(folder: folder)
        var meeting = sampleMeeting()
        let first = try XCTUnwrap(exporter.export(meeting))
        meeting.title = "Renamed"
        let second = try XCTUnwrap(exporter.export(meeting))
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        exporter.remove(meeting.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testSkipsLiveMeetings() throws {
        let exporter = MeetingExporter(folder: folder)
        XCTAssertNil(try exporter.export(sampleMeeting(status: .recording)))
        XCTAssertNil(try exporter.export(sampleMeeting(status: .transcribing)))
        XCTAssertEqual(exporter.exportAll([sampleMeeting(), sampleMeeting(status: .recording)]).written, 1)
    }
}

final class MCPServerTests: XCTestCase {
    var root: URL!
    var server: MCPServer!
    var older: Meeting!
    var newer: Meeting!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID())")
        let store = MeetingStore(root: root)
        older = sampleMeeting(title: "Pricing review")
        newer = sampleMeeting(title: "Hiring sync", startedAt: older.startedAt + 86_400 * 3, summary: nil)
        try store.save(older)
        try store.save(newer)
        try store.save(sampleMeeting(title: "Live call", startedAt: older.startedAt + 86_400 * 9, status: .recording))
        // Never reach a running app from tests: edits go straight to the temporary store.
        server = MCPServer(store: store) { id, edit in try store.edit(id, edit).message }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func send(_ request: [String: Any]) throws -> [String: Any] {
        var message = request
        message["jsonrpc"] = "2.0"
        let line = String(data: try JSONSerialization.data(withJSONObject: message), encoding: .utf8)!
        let response = try XCTUnwrap(server.handle(line: line))
        XCTAssertFalse(response.contains("\n"), "stdio messages must be one line")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    func callTool(_ name: String, _ arguments: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let response = try send(["id": 9, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (content[0]["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    func testInitializeNegotiatesVersion() throws {
        let response = try send(["id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        let unknown = try send(["id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
        XCTAssertEqual((unknown["result"] as? [String: Any])?["protocolVersion"] as? String, MCPServer.supportedProtocolVersions[0])
    }

    func testNotificationsGetNoResponseAndErrorsAreReported() throws {
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(server.handle(line: "  "))
        XCTAssertTrue(server.handle(line: "{nope")!.contains("-32700"))
        let missing = try send(["id": 3, "method": "sampling/createMessage"])
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual(try send(["id": "abc", "method": "ping"])["id"] as? String, "abc")
    }

    func testToolsListMarksReadOnlyAndWriteTools() throws {
        let tools = try XCTUnwrap((try send(["id": 1, "method": "tools/list"])["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let readOnly = Set(["list_meetings", "search_meetings", "semantic_search", "get_meeting", "list_action_items"])
        let writes = Set(["set_action_item_done", "add_meeting_note", "rename_meeting", "update_summary", "assign_speaker"])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), readOnly.union(writes))
        for tool in tools {
            let name = tool["name"] as? String ?? ""
            let annotations = tool["annotations"] as? [String: Any]
            XCTAssertEqual(annotations?["readOnlyHint"] as? Bool, readOnly.contains(name), name)
            XCTAssertEqual(annotations?["destructiveHint"] as? Bool ?? false, name == "update_summary", name)
        }
    }

    func testListMeetingsShowsLiveAndFilters() throws {
        let all = try callTool("list_meetings").text
        XCTAssertTrue(all.hasPrefix("3 meeting(s)"), all)
        XCTAssertTrue(all.contains("Live call"))
        XCTAssertTrue(all.contains("LIVE, recording now"))
        XCTAssertLessThan(all.range(of: "Hiring sync")!.lowerBound, all.range(of: "Pricing review")!.lowerBound)
        let since = MCPServer.day(newer.startedAt)
        XCTAssertFalse(try callTool("list_meetings", ["since": since]).text.contains("Pricing review"))
        XCTAssertTrue(try callTool("list_meetings", ["platform": "zoom"]).text.contains("No meetings"))
        XCTAssertTrue(try callTool("list_meetings", ["since": "yesterday"]).isError)
    }

    func testSearchMatchesTranscriptWithSnippet() throws {
        let result = try callTool("search_meetings", ["query": "NEW price"]).text
        XCTAssertTrue(result.contains("Pricing review"))
        XCTAssertTrue(result.contains("> "))
        XCTAssertFalse(result.contains("Hiring sync"))
        XCTAssertTrue(try callTool("search_meetings", ["query": "zebra"]).text.hasPrefix("No meetings"))
        XCTAssertTrue(try callTool("search_meetings").isError)
    }

    func testGetMeetingByIdPrefixAndLatest() throws {
        // Default: metadata, attendees, summary and action items, no transcript.
        let short = try callTool("get_meeting", ["id": older.id.uuidString.prefix(8).lowercased()]).text
        XCTAssertTrue(short.contains("# Pricing review"))
        XCTAssertFalse(short.contains("**Sam Lee** [00:05]"))
        XCTAssertTrue(short.contains("Sam: send the contract"))
        XCTAssertTrue(short.contains("transcript lines not shown; call get_meeting again with transcript true"))
        XCTAssertTrue(short.contains(older.id.uuidString), "front matter carries the id")
        for args: [String: Any] in [["transcript": true], ["include_transcript": true], ["transcript_offset": 0]] {
            let full = try callTool("get_meeting", args.merging(["id": older.id.uuidString]) { a, _ in a }).text
            XCTAssertTrue(full.contains("**Sam Lee** [00:05]"), "\(args)")
            XCTAssertTrue(full.contains("Sam: send the contract"))
        }
        XCTAssertFalse(try callTool("get_meeting", ["id": older.id.uuidString, "transcript": false, "transcript_offset": 0]).text
            .contains("**Sam Lee** [00:05]"))
        let latest = try callTool("get_meeting", ["id": "latest"]).text
        XCTAssertTrue(latest.contains("# Live call"))
        XCTAssertTrue(latest.contains("LIVE: this meeting is being recorded now"))
        let hiring = try callTool("get_meeting", ["id": newer.id.uuidString]).text
        XCTAssertTrue(hiring.contains("No summary yet"))
        XCTAssertTrue(try callTool("get_meeting", ["id": UUID().uuidString]).isError)
    }

    func testActionItems() throws {
        XCTAssertEqual(MCPServer.actionItems(in: "x\n- [ ] A: one\n  * [x] B: two\n- [ ] \n- plain"), ["A: one", "B: two"])
        let all = try callTool("list_action_items").text
        XCTAssertTrue(all.contains("[ ] Sam: send the contract (Monday)"), all)
        XCTAssertTrue(all.contains(older.id.uuidString))
        let mine = try callTool("list_action_items", ["owner": "you"]).text
        XCTAssertTrue(mine.contains("You: update the deck"))
        XCTAssertFalse(mine.contains("Sam:"))
    }

    func testUnknownToolIsProtocolError() throws {
        let response = try send(["id": 1, "method": "tools/call", "params": ["name": "delete_meeting"]])
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602)
    }
}
