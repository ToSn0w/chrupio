import XCTest
@testable import ChrupioCore

/// Bag of word stems (first 4 letters) hashed into 64 buckets: "umowa", "umowy" and "umowie" land together,
/// unrelated words don't. Counts calls so tests can see when nothing is re-embedded.
final class FakeEmbedder: TextEmbedder, @unchecked Sendable {
    let identifier: String
    var unavailable: EmbeddingUnavailable?
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    init(identifier: String = "fake/1", unavailable: EmbeddingUnavailable? = nil) {
        self.identifier = identifier
        self.unavailable = unavailable
    }

    func embed(_ text: String) throws -> [Float] {
        if let unavailable { throw unavailable }
        lock.withLock { _calls += 1 }
        var vector = [Float](repeating: 0, count: 64)
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) where word.count > 2 {
            let stem = String(word.prefix(4))
            let bucket = stem.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % 64
            vector[Int(bucket)] += 1
        }
        return vector
    }
}

final class SemanticSearchTests: XCTestCase {
    var root: URL!
    var store: MeetingStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-\(UUID())")
        store = MeetingStore(root: root.appendingPathComponent("meetings"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func index(_ embedder: FakeEmbedder = FakeEmbedder()) -> SemanticIndex {
        SemanticIndex(directory: root.appendingPathComponent("semantic-index"), embedder: embedder)
    }

    func meeting(_ title: String, lines: [String], summary: String? = nil, daysAgo: Double = 0,
                 status: MeetingStatus = .done) -> Meeting {
        let segments = lines.enumerated().map { index, text in
            TranscriptSegment(start: Double(index) * 10, end: Double(index) * 10 + 5,
                              speaker: index % 2 == 0 ? .me : .remote("Anna"), text: text)
        }
        return Meeting(title: title, platform: .meet, startedAt: Date(timeIntervalSince1970: 1_790_000_000 - daysAgo * 86_400),
                       endedAt: Date(timeIntervalSince1970: 1_790_000_600 - daysAgo * 86_400), segments: segments,
                       summary: summary.map { MeetingSummary(markdown: $0, model: "test") }, status: status)
    }

    // MARK: Passages

    func testTranscriptIsCutIntoOverlappingWindowsAndSummaryLeadsWithTheTitle() {
        let lines = (0..<20).map { "line number \($0)" }
        let passages = SemanticIndex.passages(for: meeting("Budżet", lines: lines, summary: "## Overview\nWe agreed."))
        XCTAssertEqual(passages[0].text, "Budżet\n## Overview\nWe agreed.")
        XCTAssertNil(passages[0].start)
        let transcript = Array(passages.dropFirst())
        XCTAssertEqual(transcript.map(\.start), [0, 60, 120])
        XCTAssertEqual(transcript[0].text.split(separator: "\n").count, 8)
        // The last two lines of one window open the next.
        XCTAssertTrue(transcript[1].text.hasPrefix("[01:00] You: line number 6"))
        XCTAssertTrue(transcript.last!.text.hasSuffix("line number 19"))
    }

    func testLongLinesAreSplitSoTheModelDoesNotCutThem() {
        let long = Array(repeating: "słowo", count: 400).joined(separator: " ")
        let passages = SemanticIndex.passages(for: meeting("Long", lines: [long]))
        XCTAssertGreaterThan(passages.count, 1)
        XCTAssertTrue(passages.allSatisfy { $0.text.count <= SemanticIndex.maxPassageCharacters })
        XCTAssertEqual(passages.map(\.text).joined(separator: " ").split(separator: " ").filter { $0 == "słowo" }.count, 400)
    }

    func testSplitPartsAreEvenWithNoStrayLastWord() {
        // 1 330 characters: two even parts, never a part holding only "elementów.".
        let text = Array(repeating: "abcdefghij", count: 120).joined(separator: " ") + " elementów."
        let parts = SemanticIndex.split(text)
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts.allSatisfy { $0.count > 300 && $0.count <= SemanticIndex.maxPassageCharacters })
        XCTAssertEqual(parts.joined(separator: " "), text)
    }

    func testSummaryHeadingIsNotAPassageOfItsOwn() {
        let long = Array(repeating: "zdanie", count: 110).joined(separator: " ")
        let passages = SemanticIndex.passages(for: meeting("Sync", lines: [], summary: "## Summary\n\(long)"))
        XCTAssertTrue(passages[0].text.hasPrefix("Sync\n## Summary\nzdanie"))
        XCTAssertFalse(passages.contains { SemanticIndex.isHeadingsOnly($0.text, title: "Sync") })
    }

    func testKeywordTermsMatchWordFormsAndSkipStopWords() {
        XCTAssertEqual(SemanticIndex.terms("Umowa z klientem dla Azure"), ["umow", "klient", "azur"])
        XCTAssertEqual(SemanticIndex.keywordScore(SemanticIndex.terms("umowa z klientem"), in: "Podpisaliśmy umowę z klientami."), 1)
        XCTAssertEqual(SemanticIndex.keywordScore(SemanticIndex.terms("proxy dla Azure"), in: "Ustawiamy proxy."), 0.5)
        XCTAssertEqual(SemanticIndex.keywordScore([], in: "anything"), 0)
    }

    // MARK: Building

    func testUpdateIsIncrementalAndRebuildsWhenTextOrModelChanges() throws {
        let embedder = FakeEmbedder()
        let semantic = index(embedder)
        var item = meeting("Sync", lines: ["hello there"], summary: "Overview")
        XCTAssertFalse(semantic.isCurrent(item))
        XCTAssertTrue(try semantic.update(item))
        XCTAssertTrue(semantic.isCurrent(item))
        let calls = embedder.calls
        XCTAssertFalse(try semantic.update(item))
        XCTAssertEqual(embedder.calls, calls, "an unchanged meeting is not embedded again")

        item.summary = MeetingSummary(markdown: "New overview", model: "test")
        XCTAssertFalse(semantic.isCurrent(item))
        XCTAssertTrue(try semantic.update(item))

        let otherModel = SemanticIndex(directory: semantic.directory, embedder: FakeEmbedder(identifier: "fake/2"))
        XCTAssertFalse(otherModel.isCurrent(item))
    }

    func testMeetingsStillRecordingAreNotIndexed() throws {
        let semantic = index()
        XCTAssertFalse(try semantic.update(meeting("Live", lines: ["hello"], status: .recording)))
        XCTAssertFalse(try semantic.update(meeting("Live", lines: ["hello"], status: .transcribing)))
    }

    func testFileRoundTrips() throws {
        let entry = SemanticIndex.Entry(model: "m", fingerprint: "f",
                                        passages: [.init(text: "a", start: nil), .init(text: "b", start: 12.5)],
                                        vectors: [[1, 0, -0.5], [0.25, 2, 3]])
        let decoded = try XCTUnwrap(SemanticIndex.decode(try SemanticIndex.encode(entry)))
        XCTAssertEqual(decoded.passages, entry.passages)
        XCTAssertEqual(decoded.vectors, entry.vectors)
        XCTAssertEqual(decoded.fingerprint, "f")
        XCTAssertNil(SemanticIndex.decode(Data("junk".utf8)))
    }

    // MARK: Searching

    func testSearchMatchesPolishWordFormsAndReturnsTheBestPassage() throws {
        let semantic = index()
        let contract = meeting("Klient", lines: ["dzień dobry", "omówmy pogodę", "podpisaliśmy umowę z klientem", "super"])
        let other = meeting("Deploy", lines: ["pipeline is broken", "rollback the release"])
        try semantic.update(contract)
        try semantic.update(other)
        let hits = try semantic.search("umowy klienta", in: [contract, other], limit: 5)
        XCTAssertEqual(hits.first?.meetingID, contract.id)
        XCTAssertTrue(hits.first?.passage.text.contains("umowę") ?? false)
        XCTAssertEqual(hits.count, 2, "one hit per meeting")
        XCTAssertGreaterThan(hits[0].score, hits[1].score)
        XCTAssertEqual(try semantic.search("umowy", in: [contract, other], limit: 1).count, 1)
    }

    // MARK: Background indexer

    func testIndexerBackfillsFinishedMeetingsAndPausesWhileTheModelIsUnavailable() throws {
        let semantic = index()
        let indexer = SemanticIndexer(index: semantic)
        let done = meeting("Done", lines: ["a b c"])
        let live = meeting("Live", lines: ["a b c"], status: .recording)
        indexer.enqueue([done, live])
        indexer.waitUntilIdle()
        XCTAssertTrue(semantic.isCurrent(done))
        XCTAssertNil(semantic.entry(live.id))

        let blocked = SemanticIndex(directory: semantic.directory, embedder: FakeEmbedder(unavailable: .init("downloading")))
        let paused = SemanticIndexer(index: blocked)
        paused.enqueue(meeting("Other", lines: ["x y z"]))
        paused.waitUntilIdle()
        XCTAssertFalse(blocked.isCurrent(meeting("Other", lines: ["x y z"])))
    }

    // MARK: MCP tool

    func call(_ server: MCPServer, _ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": "semantic_search", "arguments": arguments]]
        let line = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(server.handle(line: line)).utf8)) as? [String: Any])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (content[0]["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    func testToolIndexesOnDemandAndReturnsIdTitleDatePassageAndScore() throws {
        let contract = meeting("Klient", lines: ["podpisaliśmy umowę z klientem"], daysAgo: 0)
        let old = meeting("Stara umowa", lines: ["umowa z klientem sprzed roku"], daysAgo: 400)
        try store.save(contract)
        try store.save(old)
        let jsonDate = try store.directory(for: contract.id).appendingPathComponent("meeting.json")
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let server = MCPServer(store: store, editor: { _, _ in "" }, semantic: index())

        let result = try call(server, ["query": "umowy klientów", "limit": 5])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains(contract.id.uuidString))
        XCTAssertTrue(result.text.contains("Klient"))
        XCTAssertTrue(result.text.contains(MCPServer.day(contract.startedAt, time: true)))
        XCTAssertTrue(result.text.contains("> [00:00] You: podpisaliśmy umowę z klientem"))
        XCTAssertTrue(result.text.contains("score "))
        XCTAssertTrue(result.text.contains("transcript at 00:00"))

        let recent = try call(server, ["query": "umowy", "since": MCPServer.day(contract.startedAt.addingTimeInterval(-86_400))])
        XCTAssertFalse(recent.text.contains(old.id.uuidString), "since filters by date")
        let older = try call(server, ["query": "umowy", "until": MCPServer.day(old.startedAt)])
        XCTAssertTrue(older.text.contains(old.id.uuidString))
        XCTAssertFalse(older.text.contains(contract.id.uuidString), "until filters by date")
        XCTAssertTrue(try call(server, [:]).isError)

        let after = try store.directory(for: contract.id).appendingPathComponent("meeting.json")
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(after, jsonDate, "indexing only reads meeting.json")
    }

    func testToolFallsBackToKeywordSearchWhenTheModelIsUnavailable() throws {
        try store.save(meeting("Klient", lines: ["podpisaliśmy umowę z klientem"]))
        let server = MCPServer(store: store, editor: { _, _ in "" },
                               semantic: index(FakeEmbedder(unavailable: .init("The model is downloading."))))
        let result = try call(server, ["query": "umowę"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.hasPrefix("Semantic search is unavailable: The model is downloading. Keyword results"))
        XCTAssertTrue(result.text.contains("Klient"))
    }
}
