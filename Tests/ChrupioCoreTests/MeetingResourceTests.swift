@testable import ChrupioCore
import XCTest

final class MeetingResourceTests: XCTestCase {
    var root: URL!
    var store: MeetingStore!
    var server: MCPServer!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-res-\(UUID())", isDirectory: true)
        let store = MeetingStore(root: root)
        self.store = store
        // Edits go straight to the temporary store; nothing reaches a running app.
        server = MCPServer(store: store) { id, edit in try store.edit(id, edit).message }
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func makeMeeting(_ title: String, hoursAgo: Double, status: MeetingStatus = .done) -> Meeting {
        let start = Date().addingTimeInterval(-hoursAgo * 3_600)
        return Meeting(
            title: title, platform: .zoom, startedAt: start, endedAt: start + 1_800,
            attendees: ["Sam"], selfName: "Lukasz", url: nil,
            segments: (0..<10).map { TranscriptSegment(start: Double($0) * 10, end: Double($0) * 10 + 5, speaker: .me, text: "Line \($0)") },
            summary: MeetingSummary(markdown: "## Decisions\n- Ship it", model: "claude-haiku-4-5"),
            status: status
        )
    }

    private func request(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let line = try XCTUnwrap(server.handle(line: String(decoding: data, as: UTF8.self)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func readText(_ uri: String) throws -> String {
        let result = try XCTUnwrap(try request("resources/read", ["uri": uri])["result"] as? [String: Any])
        return try XCTUnwrap((result["contents"] as? [[String: Any]])?.first?["text"] as? String)
    }

    func testMentionUsesClaudeCodeResourceSyntax() throws {
        let id = try XCTUnwrap(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        XCTAssertEqual(MeetingResource.uri(for: id), "chrupio://meetings/6F9619FF-8B86-D011-B42D-00C04FC964FF")
        XCTAssertEqual(MeetingResource.transcriptURI(for: id), "chrupio://meetings/6F9619FF-8B86-D011-B42D-00C04FC964FF/transcript")
        XCTAssertEqual(MeetingResource.mention(for: id), "@chrupio:chrupio://meetings/6F9619FF-8B86-D011-B42D-00C04FC964FF")
    }

    func testParse() {
        XCTAssertEqual(MeetingResource.parse("chrupio://meetings/abcd1234")?.key, "abcd1234")
        XCTAssertEqual(MeetingResource.parse("chrupio://meetings/abcd1234")?.transcript, false)
        XCTAssertEqual(MeetingResource.parse("chrupio://meetings/abcd1234/transcript")?.transcript, true)
        XCTAssertNil(MeetingResource.parse("chrupio://meetings/"))
        XCTAssertNil(MeetingResource.parse("chrupio://meetings/a/b"))
        XCTAssertNil(MeetingResource.parse("chrupio://action-items"))
    }

    func testInitializeAdvertisesResources() throws {
        let result = try XCTUnwrap(try request("initialize", ["protocolVersion": "2025-06-18"])["result"] as? [String: Any])
        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(capabilities["resources"] as? [String: Any])
    }

    func testListsEveryFinishedMeetingPastTheOldFiftyCap() throws {
        for index in 0..<60 { try store.save(makeMeeting("Call \(index)", hoursAgo: Double(index + 1))) }
        try store.save(makeMeeting("Live", hoursAgo: 0, status: .recording))
        let resources = try XCTUnwrap((try request("resources/list")["result"] as? [String: Any])?["resources"] as? [[String: Any]])
        let uris = resources.compactMap { $0["uri"] as? String }
        XCTAssertEqual(uris.count, 61, "action items plus 60 finished meetings; the live one is left out")
        XCTAssertTrue(uris.allSatisfy { $0 == "chrupio://action-items" || MeetingResource.parse($0) != nil })
    }

    func testMeetingResourceLeavesTheTranscriptOut() throws {
        let meeting = makeMeeting("Pricing review", hoursAgo: 2)
        try store.save(meeting)
        let text = try readText(MeetingResource.uri(for: meeting.id))
        XCTAssertTrue(text.contains("Pricing review"))
        XCTAssertTrue(text.contains("Ship it"))
        XCTAssertFalse(text.contains("Line 9"))
        XCTAssertTrue(text.contains("transcript lines not shown; read chrupio://meetings/\(meeting.id.uuidString)/transcript for them"))
        XCTAssertFalse(text.contains("get_meeting again"))
    }

    func testTranscriptResourceReturnsTheTranscriptByPrefix() throws {
        let meeting = makeMeeting("Pricing review", hoursAgo: 2)
        try store.save(meeting)
        let prefix = String(meeting.id.uuidString.prefix(8))
        let text = try readText("chrupio://meetings/\(prefix)/transcript")
        XCTAssertTrue(text.contains("Line 0"))
        XCTAssertTrue(text.contains("Line 9"))
    }

    func testTemplatesListMeetingAndTranscript() throws {
        let templates = try XCTUnwrap((try request("resources/templates/list")["result"] as? [String: Any])?["resourceTemplates"] as? [[String: Any]])
        XCTAssertEqual(templates.compactMap { $0["uriTemplate"] as? String },
                       ["chrupio://meetings/{id}", "chrupio://meetings/{id}/transcript"])
    }

    /// Malformed URIs, unknown ids and path tricks come back as MCP errors and never read a file by path.
    func testBadURIsReturnErrors() throws {
        let meeting = makeMeeting("Pricing review", hoursAgo: 2)
        try store.save(meeting)
        // A file one level above the meetings folder, which a path-built read would reach.
        let outside = root.deletingLastPathComponent().appendingPathComponent("mcp-res-secret-\(UUID()).md")
        try "SECRET".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        let id = meeting.id.uuidString
        // Not found: -32002.
        let notFound = [
            "chrupio://meetings/",
            "chrupio://meetings/transcript",
            "chrupio://meetings//transcript",
            "chrupio://meetings/\(UUID().uuidString)",
            "chrupio://meetings/\(UUID().uuidString)/transcript",
            "chrupio://meetings/../\(outside.lastPathComponent)",
            "chrupio://meetings/..%2F\(outside.lastPathComponent)",
            "chrupio://meetings/..%2f..%2fetc%2fpasswd",
            "chrupio://meetings/\(id)/../\(id)",
            "chrupio://meetings/\(id)%2Ftranscript",
            "chrupio://meetings/\(id)/transcript/transcript",
            "chrupio://meetings/\(id)/summary",
            "chrupio://meetings/\(id)?x=1",
            "chrupio://other/\(id)",
            "file:///etc/passwd",
            "",
        ]
        // Ids too short to match safely: -32602.
        let invalid = ["chrupio://meetings/abc", "chrupio://meetings/.."]
        for (uris, code) in [(notFound, -32002), (invalid, -32602)] {
            for uri in uris {
                let response = try request("resources/read", ["uri": uri])
                XCTAssertNil(response["result"], "\(uri) should not be readable")
                let error = try XCTUnwrap(response["error"] as? [String: Any], uri)
                XCTAssertEqual(error["code"] as? Int, code, uri)
                XCTAssertEqual((error["data"] as? [String: Any])?["uri"] as? String, uri, uri)
                XCTAssertFalse((error["message"] as? String ?? "").contains("SECRET"), uri)
            }
        }
        let missing = try request("resources/read")
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testAmbiguousPrefixIsInvalidParams() throws {
        let first = try XCTUnwrap(UUID(uuidString: "ABCDEF01-0000-0000-0000-000000000001"))
        let second = try XCTUnwrap(UUID(uuidString: "ABCDEF01-0000-0000-0000-000000000002"))
        for id in [first, second] {
            var meeting = makeMeeting("Twin", hoursAgo: 1)
            meeting = Meeting(id: id, title: meeting.title, platform: meeting.platform, startedAt: meeting.startedAt,
                              endedAt: meeting.endedAt, segments: meeting.segments, summary: meeting.summary, status: .done)
            try store.save(meeting)
        }
        let uri = "chrupio://meetings/abcdef01"
        let error = try XCTUnwrap(try request("resources/read", ["uri": uri])["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertEqual((error["data"] as? [String: Any])?["uri"] as? String, uri)
    }

    // MARK: Only finished meetings

    func testLatestResolvesToTheLatestFinishedMeeting() throws {
        try store.save(makeMeeting("Older finished", hoursAgo: 3))
        try store.save(makeMeeting("Live now", hoursAgo: 0, status: .recording))
        let text = try readText("chrupio://meetings/latest")
        XCTAssertTrue(text.contains("Older finished"))
        XCTAssertFalse(text.contains("Live now"))
    }

    func testLiveMeetingIsNotFound() throws {
        for status in [MeetingStatus.recording, .transcribing] {
            let live = makeMeeting("Live", hoursAgo: 0, status: status)
            try store.save(live)
            for uri in [MeetingResource.uri(for: live.id), MeetingResource.transcriptURI(for: live.id)] {
                let error = try XCTUnwrap(try request("resources/read", ["uri": uri])["error"] as? [String: Any], uri)
                XCTAssertEqual(error["code"] as? Int, -32002, uri)
            }
        }
    }

    // MARK: List size

    func testListEntriesCarryTitleAndShortDescription() throws {
        try store.save(makeMeeting("Pricing review", hoursAgo: 2))
        let resources = try listResources()
        let entry = try XCTUnwrap(resources.first { ($0["uri"] as? String)?.hasPrefix(MeetingResource.meetingsPrefix) == true })
        XCTAssertNotNil(entry["name"] as? String)
        XCTAssertEqual(entry["mimeType"] as? String, "text/markdown")
        XCTAssertTrue((entry["title"] as? String ?? "").contains("Pricing review"))
        let description = try XCTUnwrap(entry["description"] as? String)
        let parts = description.components(separatedBy: " · ")
        XCTAssertEqual(parts.count, 3, description)
        XCTAssertEqual(parts.dropFirst().first, "Zoom")
        XCTAssertFalse(description.contains("Sam"), "attendees stay out of the list")
    }

    func testListCapsAt500Meetings() throws {
        let start = Date().addingTimeInterval(-86_400 * 600)
        for index in 0..<(MCPServer.resourceLimit + 5) {
            try store.save(Meeting(title: "M\(index)", platform: .meet, startedAt: start + Double(index) * 3_600, status: .done))
        }
        let meetingURIs = try listResources().compactMap { $0["uri"] as? String }.filter { $0.hasPrefix(MeetingResource.meetingsPrefix) }
        XCTAssertEqual(meetingURIs.count, 500)
    }

    private func listResources() throws -> [[String: Any]] {
        try XCTUnwrap((try request("resources/list")["result"] as? [String: Any])?["resources"] as? [[String: Any]])
    }

    // MARK: list_changed notifications

    func testInitializeAdvertisesListChanged() throws {
        let result = try XCTUnwrap(try request("initialize", ["protocolVersion": "2025-06-18"])["result"] as? [String: Any])
        let resources = try XCTUnwrap((result["capabilities"] as? [String: Any])?["resources"] as? [String: Any])
        XCTAssertEqual(resources["listChanged"] as? Bool, true)
    }

    func testNotificationIsAValidJSONRPCNotification() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(MCPServer.resourceListChangedNotification.utf8)) as? [String: Any])
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(object["method"] as? String, "notifications/resources/list_changed")
        XCTAssertNil(object["id"])
        XCTAssertFalse(MCPServer.resourceListChangedNotification.contains("\n"))
    }

    private func line(_ method: String, id: Int? = 1, _ params: [String: Any] = [:]) throws -> String {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { message["id"] = id }
        return String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
    }

    func testSessionNotifiesOnlyAfterInitializeAndOnlyOnChange() throws {
        let output = Output()
        let session = MCPStdioSession(server: server) { output.append($0) }
        try store.save(makeMeeting("First", hoursAgo: 3))
        // Before initialize: a change is never announced.
        session.checkForChanges()
        try store.save(makeMeeting("Second", hoursAgo: 2))
        session.checkForChanges()
        XCTAssertTrue(output.lines.isEmpty)

        session.receive(try line("initialize", ["protocolVersion": "2025-06-18"]))
        XCTAssertEqual(output.lines.count, 1, "only the initialize response")
        try store.save(makeMeeting("Third", hoursAgo: 1))
        session.checkForChanges()
        XCTAssertEqual(output.lines.count, 1, "nothing before notifications/initialized")

        session.receive(try line("notifications/initialized", id: nil))
        XCTAssertEqual(output.lines.last, MCPServer.resourceListChangedNotification, "the change made while initializing")
        let count = output.lines.count
        session.checkForChanges()
        session.receive(try line("ping", id: 2))
        XCTAssertEqual(output.lines.count, count + 1, "ping response only; nothing changed")

        // A live meeting isn't a resource; it shows up when it finishes.
        var live = makeMeeting("Live", hoursAgo: 0, status: .recording)
        try store.save(live)
        session.checkForChanges()
        XCTAssertEqual(output.lines.count, count + 1)
        live.status = .done
        try store.save(live)
        session.receive(try line("ping", id: 3))
        XCTAssertEqual(output.lines.suffix(2).last, MCPServer.resourceListChangedNotification, "checked after each request")
        XCTAssertTrue(output.lines.suffix(2).first?.contains("\"id\":3") == true, "response first, then the notification")

        try store.delete(live.id)
        session.checkForChanges()
        XCTAssertEqual(output.lines.last, MCPServer.resourceListChangedNotification, "removals count too")
    }

    func testTimerChecksWithoutRequests() throws {
        let output = Output()
        let session = MCPStdioSession(server: server) { output.append($0) }
        session.receive(try line("initialize", ["protocolVersion": "2025-06-18"]))
        session.receive(try line("notifications/initialized", id: nil))
        let timer = session.startWatching(every: 0.05)
        defer { timer.cancel() }
        try store.save(makeMeeting("New", hoursAgo: 1))
        let deadline = Date().addingTimeInterval(5)
        while !output.lines.contains(MCPServer.resourceListChangedNotification), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(output.lines.contains(MCPServer.resourceListChangedNotification))
    }

    /// Responses and notifications written from two threads never share a line.
    func testWritesAreSerialized() throws {
        let output = Output()
        let session = MCPStdioSession(server: server) { output.append($0) }
        session.receive(try line("initialize", ["protocolVersion": "2025-06-18"]))
        session.receive(try line("notifications/initialized", id: nil))
        let ping = try line("ping", id: 9)
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            if index % 2 == 0 {
                session.receive(ping)
            } else {
                try? store.save(makeMeeting("M\(index)", hoursAgo: Double(index)))
                session.checkForChanges()
            }
        }
        for line in output.lines {
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], line)
        }
    }
}

private final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    /// Fails the test if two writes overlap.
    private var writing = false

    func append(_ line: String) {
        lock.lock()
        XCTAssertFalse(writing, "overlapping writes")
        writing = true
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.001)
        lock.lock()
        stored.append(line)
        writing = false
        lock.unlock()
    }

    var lines: [String] { lock.withLock { stored } }
}
