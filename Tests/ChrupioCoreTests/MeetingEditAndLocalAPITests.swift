import Foundation
@testable import ChrupioCore
import XCTest

private func meeting(
    _ title: String = "Pricing review",
    startedAt: Date = Date(timeIntervalSince1970: 1_790_000_000),
    status: MeetingStatus = .done,
    summary: String? = "## Action items\n- [ ] Sam: send the contract\n- [x] Anna: book the room\n- [ ] You: update the deck",
    transcript: String = "Let's talk about pricing."
) -> Meeting {
    Meeting(
        title: title, platform: .meet, startedAt: startedAt, endedAt: startedAt + 1_800,
        attendees: ["Sam", "Anna"], selfName: "Lukasz", url: nil,
        segments: [TranscriptSegment(start: 0, end: 4, speaker: .me, text: transcript)],
        summary: summary.map { MeetingSummary(markdown: $0, model: "llama3.2:3b") },
        status: status
    )
}

final class MeetingEditTests: XCTestCase {
    func testActionItemsParseNumberAndFind() throws {
        let markdown = "x\n- [ ] A: one\n  * [X] B: two\n- [ ] \n- plain\n+ [ ] C: three"
        let items = ActionItem.parse(markdown)
        XCTAssertEqual(items.map(\.number), [1, 2, 3])
        XCTAssertEqual(items.map(\.text), ["A: one", "B: two", "C: three"])
        XCTAssertEqual(items.map(\.done), [false, true, false])
        XCTAssertEqual(try ActionItem.find("2", in: markdown).text, "B: two")
        XCTAssertEqual(try ActionItem.find("three", in: markdown).number, 3)
        XCTAssertThrowsError(try ActionItem.find("9", in: markdown))
        XCTAssertThrowsError(try ActionItem.find(":", in: markdown), "ambiguous text must name a number")
        XCTAssertThrowsError(try ActionItem.find("1", in: "no items"))
    }

    func testSetActionItemChangesOnlyThatCheckbox() throws {
        var m = meeting()
        let message = try MeetingEdit.setActionItem(item: "contract", done: true).apply(to: &m)
        XCTAssertTrue(message.contains("item 1 done"), message)
        XCTAssertEqual(m.summary?.markdown, "## Action items\n- [x] Sam: send the contract\n- [x] Anna: book the room\n- [ ] You: update the deck")
        _ = try MeetingEdit.setActionItem(item: "2", done: false).apply(to: &m)
        XCTAssertEqual(ActionItem.parse(m.summary!.markdown).map(\.done), [true, false, false])
        var bare = meeting(summary: nil)
        XCTAssertThrowsError(try MeetingEdit.setActionItem(item: "1", done: true).apply(to: &bare))
    }

    func testNotesRenameAndSummaryRules() throws {
        var m = meeting()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try MeetingEdit.addNote(text: "  Follow up in #pricing  ", author: "").apply(to: &m, now: now)
        XCTAssertEqual(m.notes?.first?.text, "Follow up in #pricing")
        XCTAssertEqual(m.notes?.first?.author, "Claude Code")
        XCTAssertEqual(m.notes?.first?.createdAt, now)
        XCTAssertThrowsError(try MeetingEdit.addNote(text: "  ", author: "x").apply(to: &m))
        XCTAssertThrowsError(try MeetingEdit.addNote(text: String(repeating: "a", count: 10_001), author: "x").apply(to: &m))

        _ = try MeetingEdit.rename(title: "Pricing\nfinal").apply(to: &m)
        XCTAssertEqual(m.title, "Pricing final")
        XCTAssertThrowsError(try MeetingEdit.rename(title: " ").apply(to: &m))

        _ = try MeetingEdit.setSummary(markdown: "## Overview\nShorter.").apply(to: &m, now: now)
        XCTAssertEqual(m.summary?.model, "llama3.2:3b, edited")
        _ = try MeetingEdit.setSummary(markdown: "Again").apply(to: &m, now: now)
        XCTAssertEqual(m.summary?.model, "llama3.2:3b, edited")
        var live = meeting(status: .summarizing)
        XCTAssertThrowsError(try MeetingEdit.setSummary(markdown: "x").apply(to: &live))

        // No saved model: "Claude Code, edited"; the error the failed summary left goes with it.
        var failed = meeting(status: .done)
        failed.summary = MeetingSummary(markdown: "old", model: "")
        failed.error = "Update Claude Code."
        failed.summaryError = "Update Claude Code."
        _ = try MeetingEdit.setSummary(markdown: "By hand").apply(to: &failed, now: now)
        XCTAssertEqual(failed.summary?.model, "Claude Code, edited")
        XCTAssertNil(failed.error)
        XCTAssertNil(failed.summaryError)

        // A retry's reason left as the error, without a summaryError, goes too; another warning stays.
        var retrying = meeting(status: .done)
        retrying.error = "Claude Code hit its usage limit: resets at 5pm"
        retrying.summaryPending = SummaryPending(reason: "Claude Code hit its usage limit: resets at 5pm", attempts: 1, nextAttempt: now)
        _ = try MeetingEdit.setSummary(markdown: "By hand").apply(to: &retrying, now: now)
        XCTAssertNil(retrying.error)
        XCTAssertNil(retrying.summaryPending)
        var warned = meeting(status: .done)
        warned.error = "Part of the audio couldn't be transcribed."
        warned.summaryPending = SummaryPending(reason: "Claude Code took too long to write the summary.", attempts: 1, nextAttempt: now)
        _ = try MeetingEdit.setSummary(markdown: "By hand").apply(to: &warned, now: now)
        XCTAssertEqual(warned.error, "Part of the audio couldn't be transcribed.")

        // A failure saved before summaryError existed is only in `error`; it goes too, as the scheduler clears it.
        var legacy = meeting(status: .done)
        legacy.error = "Claude Code could not write the summary: API error 529 overloaded"
        _ = try MeetingEdit.setSummary(markdown: "By hand").apply(to: &legacy, now: now)
        XCTAssertNil(legacy.error)
    }

    func testEditRoundTripsAsJSON() throws {
        let edits: [MeetingEdit] = [.setActionItem(item: "1", done: true), .addNote(text: "n", author: "a"), .rename(title: "t"), .setSummary(markdown: "s")]
        for edit in edits {
            let request = LocalAPI.EditRequest(id: UUID(), edit: edit)
            XCTAssertEqual(try JSONDecoder().decode(LocalAPI.EditRequest.self, from: JSONEncoder().encode(request)), request)
        }
    }

    func testOldMeetingFilesWithoutNotesStillLoad() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(meeting())) as? [String: Any])
        object["notes"] = nil
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNil(try decoder.decode(Meeting.self, from: JSONSerialization.data(withJSONObject: object)).notes)
    }

    func testMarkdownExportHasNotesSection() {
        var m = meeting()
        m.notes = [MeetingNote(createdAt: Date(), author: "Claude Code", text: "Ticket filed.")]
        let text = TranscriptFormatter.markdown(m)
        let notes = try! XCTUnwrap(text.range(of: "## Notes"))
        XCTAssertLessThan(notes.lowerBound, text.range(of: "## Transcript")!.lowerBound)
        XCTAssertTrue(text.contains("Ticket filed."))
    }
}

final class MeetingStoreEditTests: XCTestCase {
    var root: URL!
    var store: MeetingStore!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("edit-\(UUID())")
        store = MeetingStore(root: root)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testEditPersistsAndChangesModificationDate() throws {
        let m = meeting()
        try store.save(m)
        let before = try XCTUnwrap(store.modificationDate(m.id))
        Thread.sleep(forTimeInterval: 0.02)
        let result = try store.edit(m.id, .addNote(text: "hi", author: "Claude Code"))
        XCTAssertTrue(result.message.contains("Added a note"))
        XCTAssertEqual(try store.load(m.id).notes?.count, 1)
        XCTAssertNotEqual(store.modificationDates()[m.id], before)
        XCTAssertThrowsError(try store.edit(UUID(), .rename(title: "x")))
    }

    func testConcurrentEditsAreNotLost() throws {
        let m = meeting()
        try store.save(m)
        let store = self.store!
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            _ = try? store.edit(m.id, .addNote(text: "note \(index)", author: "t"))
        }
        XCTAssertEqual(try store.load(m.id).notes?.count, 20)
    }
}

final class ProjectContextTests: XCTestCase {
    var root: URL!

    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("proj-\(UUID())") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testNamesFromRemoteRootAndFolder() throws {
        let repo = root.appendingPathComponent("open-acme")
        let sub = repo.appendingPathComponent("src/billing-api")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:me/Acme-Pricing.git\n"
            .write(to: repo.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        let context = try XCTUnwrap(ProjectContext.from(cwd: sub.path))
        XCTAssertEqual(context.name, "Acme-Pricing")
        XCTAssertEqual(context.terms, ["acme-pricing", "acme pricing", "open-acme", "open acme", "billing-api", "billing api"])
    }

    func testGenericFoldersGiveNoProject() throws {
        let generic = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: generic, withIntermediateDirectories: true)
        XCTAssertNil(ProjectContext.from(cwd: generic.path))
        XCTAssertNil(ProjectContext.from(cwd: nil))
        XCTAssertNil(ProjectContext.from(cwd: FileManager.default.homeDirectoryForCurrentUser.path))
    }

    func testMatchesWholeWordsAnywhere() {
        let context = ProjectContext(name: "acme", terms: ["acme"])
        XCTAssertTrue(context.matches(meeting("The Acme launch")))
        XCTAssertFalse(context.matches(meeting("Make it acmeville.")))
        // The transcript is not searched: the hooks only read index.json.
        XCTAssertFalse(context.matches(meeting(transcript: "The Acme launch slipped.")))
        var noted = meeting(transcript: "nothing")
        noted.notes = [MeetingNote(createdAt: Date(), author: "a", text: "see acme repo")]
        XCTAssertTrue(context.matches(noted))
    }
}

final class PromptUpdatesTests: XCTestCase {
    let since = Date(timeIntervalSince1970: 1_790_000_000)

    func testReportsEachFinishedMeetingOnce() {
        let state = HookSessionState(since: since)
        let old = meeting("Old", startedAt: since - 86_400)
        let fresh = meeting("Fresh", startedAt: since + 600,
                            summary: "chrupio sync\n- [ ] Sam: send the contract\n- [x] Anna: book the room\n- [ ] You: update the deck")
        let noSummary = meeting("Bare", startedAt: since + 900, summary: nil)
        let project = ProjectContext(name: "chrupio", terms: ["chrupio"])
        let first = PromptUpdates.lines([old, fresh, noSummary], state: state, project: project)
        XCTAssertEqual(first.lines.count, 4, first.lines.joined(separator: "\n"))
        XCTAssertEqual(first.lines[0], UntrustedText.notice)
        XCTAssertTrue(first.lines[1].contains("\"Fresh\""))
        XCTAssertTrue(first.lines[1].contains("2 open action item(s)"))
        XCTAssertTrue(first.lines[1].contains("mentions chrupio"))
        XCTAssertTrue(first.lines[2].contains("no summary"))
        XCTAssertTrue(first.lines[3].hasPrefix("Use the chrupio MCP tools"))
        XCTAssertFalse(first.lines.joined().contains("\"Old\""))

        let second = PromptUpdates.lines([old, fresh, noSummary], state: first.state, project: project)
        XCTAssertTrue(second.lines.isEmpty, "silent when nothing is new")
    }

    func testLiveMeetingAnnouncedOnceAndCapped() {
        let live = meeting("Standup", startedAt: since + 60, status: .recording)
        let finished = (0..<5).map { meeting("M\($0)", startedAt: since + Double($0) * 100) }
        let result = PromptUpdates.lines(finished + [live], state: HookSessionState(since: since), project: nil)
        XCTAssertEqual(result.lines.filter { $0.contains("meeting finished") }.count, 3)
        XCTAssertTrue(result.lines.contains { $0.contains("2 more meeting(s)") })
        XCTAssertTrue(result.lines.contains { $0.contains("recording now: \"Standup\"") })
        XCTAssertTrue(PromptUpdates.lines(finished + [live], state: result.state, project: nil).lines.isEmpty)
    }

    func testSessionStateRoundTripsAndRejectsUnsafeIDs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = HookSessionState(since: since, announced: [UUID()], announcedLive: [UUID()])
        state.save("abc-123", in: dir)
        XCTAssertEqual(HookSessionState.load("abc-123", in: dir), state)
        XCTAssertNil(HookSessionState.file(for: "../..", in: dir).flatMap { $0.lastPathComponent == ".json" ? nil : $0 }?.path.contains(".."))
        XCTAssertNil(HookSessionState.load("missing", in: dir))
    }

    func testDigestListsProjectMeetingsFirst() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let related = meeting("Roadmap", startedAt: now - 20 * 86_400, summary: "chrupio needs a prompt hook\n- [ ] You: write it")
        let recent = meeting("Hiring", startedAt: now - 86_400)
        let text = MeetingDigest.text([related, recent], now: now, project: ProjectContext(name: "chrupio", terms: ["chrupio"]))
        let mention = try! XCTUnwrap(text.range(of: "mention chrupio"))
        XCTAssertLessThan(mention.lowerBound, text.range(of: "Recent meetings:")!.lowerBound)
        XCTAssertTrue(text.contains("Roadmap"))
        XCTAssertTrue(text.contains("item 1"), text)
    }
}

final class LocalAPITests: XCTestCase {
    func server(token: String = String(repeating: "a", count: 64)) -> ExtensionServer {
        ExtensionServer(port: 47811, apiToken: token, onEdit: { request in
            (200, LocalAPI.EditResponse(ok: true, message: "applied \(request.id.uuidString.prefix(4))"))
        }, onEvent: { _ in })
    }

    func request(headers: [String: String], method: String = "POST", body: Data? = nil) -> HTTPRequest {
        let edit = LocalAPI.EditRequest(id: UUID(), edit: .rename(title: "x"))
        return HTTPRequest(method: method, path: LocalAPI.editPath, headers: headers, body: body ?? (try! JSONEncoder().encode(edit)))
    }

    func status(_ response: Data) -> Int {
        Int(String(decoding: response, as: UTF8.self).split(separator: " ")[1]) ?? 0
    }

    func testEditNeedsTokenLoopbackHostAndNoOrigin() async {
        let token = String(repeating: "a", count: 64)
        let good = ["host": "127.0.0.1:47811", "authorization": "Bearer \(token)"]
        let ok = await server().respondToEdit(request(headers: good))
        XCTAssertEqual(status(ok), 200)
        XCTAssertTrue(String(decoding: ok, as: UTF8.self).contains("applied"))

        var withOrigin = good
        withOrigin["origin"] = "https://evil.example"
        let refusedOrigin = await server().respondToEdit(request(headers: withOrigin))
        XCTAssertEqual(status(refusedOrigin), 403)
        var rebinding = good
        rebinding["host"] = "evil.example:47811"
        let refusedHost = await server().respondToEdit(request(headers: rebinding))
        XCTAssertEqual(status(refusedHost), 403)
        var wrongToken = good
        wrongToken["authorization"] = "Bearer " + String(repeating: "b", count: 64)
        let refusedToken = await server().respondToEdit(request(headers: wrongToken))
        XCTAssertEqual(status(refusedToken), 401)
        let missingToken = await server().respondToEdit(request(headers: ["host": "localhost:47811"]))
        XCTAssertEqual(status(missingToken), 401)
        let get = await server().respondToEdit(request(headers: good, method: "GET"))
        XCTAssertEqual(status(get), 405)
        let garbage = await server().respondToEdit(request(headers: good, body: Data("{}".utf8)))
        XCTAssertEqual(status(garbage), 400)
        let noHandler = await ExtensionServer(port: 47811, onEvent: { _ in }).respondToEdit(request(headers: good))
        XCTAssertEqual(status(noHandler), 401)
    }

    func testTokenFileIsPrivateAndStable() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("token-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        let token = try XCTUnwrap(LocalAPI.ensureToken(at: file))
        XCTAssertEqual(token.count, 64)
        XCTAssertEqual(LocalAPI.ensureToken(at: file), token)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertTrue(LocalAPI.tokensMatch(token, token))
        XCTAssertFalse(LocalAPI.tokensMatch(token, String(token.dropLast())))
    }
}

final class LocalAPITokenTests: XCTestCase {
    private var folder: URL!
    private var tokenFile: URL { folder.appendingPathComponent("local-api-token") }
    private var endpointFile: URL { folder.appendingPathComponent("local-api-endpoint") }
    private let chrupioPath = "/Applications/Chrupio.app/Contents/MacOS/Chrupio"
    private var chrupio: @Sendable (Int32) -> LocalAPI.ProcessIdentity? { running(chrupioPath) }

    /// Pid 4242 runs `path` under `uid` (this account by default); no other pid exists.
    private func running(_ path: String, uid: uid_t = getuid()) -> @Sendable (Int32) -> LocalAPI.ProcessIdentity? {
        { $0 == 4242 ? LocalAPI.ProcessIdentity(path: path, uid: uid) : nil }
    }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("api-\(UUID().uuidString)", isDirectory: true)
        try FilePermissions.ensurePrivateDirectory(folder)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func send(process: @escaping (Int32) -> LocalAPI.ProcessIdentity?) -> LocalAPI.SendOutcome {
        LocalAPI.send(LocalAPI.EditRequest(id: UUID(), edit: .rename(title: "x")), tokenFile: tokenFile,
                      endpointFile: endpointFile, process: process, timeout: 0.5)
    }

    func testTokenIsRandomAndPrivate() throws {
        let token = try XCTUnwrap(LocalAPI.ensureToken(at: tokenFile))
        XCTAssertEqual(token.count, 64)
        XCTAssertNotEqual(token, String(repeating: "0", count: 64))
        XCTAssertEqual(try mode(tokenFile), 0o600)
        XCTAssertEqual(LocalAPI.ensureToken(at: tokenFile), token, "kept across launches")
        XCTAssertNotEqual(LocalAPI.ensureToken(at: folder.appendingPathComponent("other")), token)
    }

    func testNoTokenWhenRandomBytesFail() {
        XCTAssertNil(LocalAPI.ensureToken(at: tokenFile, random: { _ in errSecAllocate }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenFile.path))
    }

    func testExistingTokenFileIsMadePrivate() throws {
        let token = String(repeating: "ab", count: 32)
        FileManager.default.createFile(atPath: tokenFile.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o644])
        XCTAssertEqual(LocalAPI.ensureToken(at: tokenFile), token)
        XCTAssertEqual(try mode(tokenFile), 0o600)
    }

    func testTokenLinkIsReplacedAndItsTargetLeftAlone() throws {
        let target = folder.appendingPathComponent("planted")
        let planted = String(repeating: "cd", count: 32)
        FileManager.default.createFile(atPath: target.path, contents: Data(planted.utf8), attributes: [.posixPermissions: 0o644])
        try FileManager.default.createSymbolicLink(at: tokenFile, withDestinationURL: target)

        let token = try XCTUnwrap(LocalAPI.ensureToken(at: tokenFile))
        XCTAssertNotEqual(token, planted, "a planted link's token is never used")
        let kind = try FileManager.default.attributesOfItem(atPath: tokenFile.path)[.type] as? FileAttributeType
        XCTAssertEqual(kind, .typeRegular)
        XCTAssertEqual(try mode(tokenFile), 0o600)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), planted)
        XCTAssertEqual(try mode(target), 0o644)
    }

    func testReadersRefuseALinkedOrReadableToken() throws {
        let target = folder.appendingPathComponent("planted")
        try FilePermissions.writePrivately(Data(String(repeating: "cd", count: 32).utf8), to: target)
        try FileManager.default.createSymbolicLink(at: tokenFile, withDestinationURL: target)
        XCTAssertThrowsError(try LocalAPI.readToken(at: tokenFile))

        try FileManager.default.removeItem(at: tokenFile)
        _ = LocalAPI.ensureToken(at: tokenFile)
        XCTAssertNotNil(try LocalAPI.readToken(at: tokenFile))
        XCTAssertThrowsError(try LocalAPI.readToken(at: tokenFile, owner: getuid() + 1))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tokenFile.path)
        XCTAssertThrowsError(try LocalAPI.readToken(at: tokenFile))
    }

    func testEndpointIsTrustedOnlyForALiveChrupioOfThisAccount() throws {
        XCTAssertNil(try LocalAPI.endpoint(at: endpointFile, process: chrupio), "no file: the app isn't listening")

        let port = try freeTestPort()
        try LocalAPI.recordEndpoint(port: port, pid: 4242, at: endpointFile)
        XCTAssertEqual(try mode(endpointFile), 0o600)
        XCTAssertEqual(try LocalAPI.endpoint(at: endpointFile, process: chrupio), port)
        XCTAssertNil(try LocalAPI.endpoint(at: endpointFile, process: running("/usr/bin/nc")), "another program")
        XCTAssertNil(try LocalAPI.endpoint(at: endpointFile, process: running("/tmp/NotChrupio")), "a name that only ends like it")
        XCTAssertNil(try LocalAPI.endpoint(at: endpointFile, process: { _ in nil }), "the pid is gone")
        XCTAssertNil(try LocalAPI.endpoint(at: endpointFile, process: running(chrupioPath, uid: getuid() + 1)),
                     "a Chrupio another account runs")

        LocalAPI.clearEndpoint(at: endpointFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpointFile.path))
        try FilePermissions.writePrivately(Data("junk".utf8), to: endpointFile)
        XCTAssertNil(try LocalAPI.endpoint(at: endpointFile, process: chrupio))
    }

    func testProcessIdentityReadsTheOwner() throws {
        let me = try XCTUnwrap(LocalAPI.identify(getpid()))
        XCTAssertEqual(me.uid, getuid())
        XCTAssertFalse(me.path.isEmpty)
        XCTAssertNil(LocalAPI.identify(0))
    }

    func testLaunchKeepsTheEndpointOfAnotherRunningChrupio() throws {
        let port = try freeTestPort()
        try LocalAPI.recordEndpoint(port: port, pid: 4242, at: endpointFile)
        XCTAssertFalse(LocalAPI.clearStaleEndpoint(at: endpointFile, ownPid: 999, process: chrupio),
                       "a second copy leaves the running app's file alone")
        XCTAssertEqual(try LocalAPI.endpoint(at: endpointFile, process: chrupio), port)

        XCTAssertTrue(LocalAPI.clearStaleEndpoint(at: endpointFile, ownPid: 999, process: { _ in nil }), "left by a crash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpointFile.path))

        try LocalAPI.recordEndpoint(port: port, pid: 4242, at: endpointFile)
        XCTAssertTrue(LocalAPI.clearStaleEndpoint(at: endpointFile, ownPid: 999, process: running(chrupioPath, uid: getuid() + 1)))
        try LocalAPI.recordEndpoint(port: port, pid: 4242, at: endpointFile)
        XCTAssertTrue(LocalAPI.clearStaleEndpoint(at: endpointFile, ownPid: 999, process: running("/usr/bin/nc")))
        try FilePermissions.writePrivately(Data("junk".utf8), to: endpointFile)
        XCTAssertTrue(LocalAPI.clearStaleEndpoint(at: endpointFile, ownPid: 999, process: chrupio))
    }

    func testQuitClearsOnlyItsOwnEndpoint() throws {
        let port = try freeTestPort()
        try LocalAPI.recordEndpoint(port: port, pid: 4242, at: endpointFile)
        XCTAssertFalse(LocalAPI.clearOwnEndpoint(pid: 999, at: endpointFile), "another copy's file stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: endpointFile.path))
        XCTAssertTrue(LocalAPI.clearOwnEndpoint(pid: 4242, at: endpointFile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpointFile.path))
        XCTAssertFalse(LocalAPI.clearOwnEndpoint(pid: 4242, at: endpointFile), "nothing to clear")
    }

    func testEndpointReaderRefusesALinkedOrReadableFile() throws {
        let port = try freeTestPort()
        let target = folder.appendingPathComponent("planted")
        try LocalAPI.recordEndpoint(port: port, pid: 4242, at: target)
        try FileManager.default.createSymbolicLink(at: endpointFile, withDestinationURL: target)
        XCTAssertThrowsError(try LocalAPI.endpoint(at: endpointFile, process: chrupio))
        LocalAPI.clearEndpoint(at: endpointFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "clearing removes the link, not its target")

        try LocalAPI.recordEndpoint(port: port, pid: 4242, at: endpointFile)
        XCTAssertThrowsError(try LocalAPI.endpoint(at: endpointFile, process: chrupio, owner: getuid() + 1))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: endpointFile.path)
        XCTAssertThrowsError(try LocalAPI.endpoint(at: endpointFile, process: chrupio))
    }

    func testWritersSurviveAFolderInPlaceOfTheirFile() throws {
        try FileManager.default.createDirectory(at: tokenFile, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: endpointFile, withIntermediateDirectories: false)
        XCTAssertNil(LocalAPI.ensureToken(at: tokenFile), "the edit API stays off")
        XCTAssertThrowsError(try LocalAPI.recordEndpoint(port: try freeTestPort(), pid: 4242, at: endpointFile))
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tokenFile.path, isDirectory: &isFolder) && isFolder.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: endpointFile.path, isDirectory: &isFolder) && isFolder.boolValue)
    }

    func testSendWithoutATrustedEndpointNeverConnects() throws {
        _ = LocalAPI.ensureToken(at: tokenFile)
        XCTAssertEqual(send(process: { _ in nil }), .appNotRunning)
        try LocalAPI.recordEndpoint(port: try freeTestPort(), pid: 4242, at: endpointFile)
        XCTAssertEqual(send(process: running("/usr/bin/nc")), .appNotRunning)
        XCTAssertEqual(send(process: running(chrupioPath, uid: getuid() + 1)), .appNotRunning)
    }

    func testSendRefusesUnsafeFilesWithAPlainMessage() throws {
        try LocalAPI.recordEndpoint(port: try freeTestPort(), pid: 4242, at: endpointFile)
        _ = LocalAPI.ensureToken(at: tokenFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tokenFile.path)
        XCTAssertEqual(send(process: chrupio), .failed(
            "Chrupio didn't send the edit to the app: local-api-token can be read by other accounts. Quit and reopen Chrupio to fix it."))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: endpointFile.path)
        XCTAssertEqual(send(process: chrupio), .failed(
            "Chrupio didn't send the edit to the app: local-api-endpoint can be read by other accounts. Quit and reopen Chrupio to fix it."))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: endpointFile.path)
        let target = folder.appendingPathComponent("planted")
        try FileManager.default.moveItem(at: tokenFile, to: target)
        try FileManager.default.createSymbolicLink(at: tokenFile, withDestinationURL: target)
        XCTAssertEqual(send(process: chrupio), .failed(
            "Chrupio didn't send the edit to the app: local-api-token is a link to another file. Quit and reopen Chrupio to fix it."))

        try FileManager.default.removeItem(at: tokenFile)
        try FileManager.default.createDirectory(at: tokenFile, withIntermediateDirectories: false)
        XCTAssertEqual(send(process: chrupio), .failed(
            "Chrupio didn't send the edit to the app: \(tokenFile.path) is a folder. Delete it, then quit and reopen Chrupio."))
    }

    func testSendReachesTheRecordedPort() async throws {
        let token = try XCTUnwrap(LocalAPI.ensureToken(at: tokenFile))
        let server = ExtensionServer(port: 0, apiToken: token, onEdit: { _ in
            (200, LocalAPI.EditResponse(ok: true, message: "renamed"))
        }, onEvent: { _ in })
        let ready = expectation(description: "listening")
        let bound = LockedBox<UInt16>(0)
        try server.start(onReady: { port in bound.value = port; ready.fulfill() })
        defer { server.stop() }
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertNotEqual(bound.value, 0)
        XCTAssertNotEqual(bound.value, ExtensionServer.defaultPort)
        try LocalAPI.recordEndpoint(port: bound.value, pid: 4242, at: endpointFile)
        let tokenFile = tokenFile, endpointFile = endpointFile, chrupio = chrupio
        let outcome = await Task.detached {
            LocalAPI.send(LocalAPI.EditRequest(id: UUID(), edit: .rename(title: "x")), tokenFile: tokenFile,
                          endpointFile: endpointFile, process: chrupio)
        }.value
        XCTAssertEqual(outcome, .applied("renamed"))
    }
}

/// Binds a TCP socket on 127.0.0.1. `sharing` turns address and port reuse on, the way a squatter would bind to
/// invite a second listener. Port 0 picks a free port; the default port 47811 is never used.
private func bindLoopback(port: UInt16 = 0, sharing: Bool = false, listening: Bool = true) throws -> (socket: Int32, port: UInt16) {
    precondition(port != ExtensionServer.defaultPort, "tests never touch the app's port")
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    if sharing {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    var failure: Int32 = 0
    let ok = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            let done = Darwin.bind(fd, $0, length) == 0 && (!listening || Darwin.listen(fd, 1) == 0) && getsockname(fd, $0, &length) == 0
            if !done { failure = errno }
            return done
        }
    }
    guard ok else { close(fd); throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
    let bound = UInt16(bigEndian: address.sin_port)
    guard bound != ExtensionServer.defaultPort else { close(fd); throw POSIXError(.EADDRINUSE) }
    return (fd, bound)
}

/// A free loopback port other than 47811 that nothing listens on (bound and closed with no connection, so no TIME_WAIT).
func freeTestPort() throws -> UInt16 {
    let held = try bindLoopback(listening: false)
    close(held.socket)
    return held.port
}

/// The server never shares its port: a program already holding it keeps it, and a quick restart waits for it.
final class ExtensionServerBindTests: XCTestCase {
    func testNeverSharesAPortAnotherProgramHolds() async throws {
        for sharing in [false, true] {
            let held = try bindLoopback(sharing: sharing)
            defer { close(held.socket) }
            let server = ExtensionServer(port: held.port) { _ in }
            let failed = expectation(description: "gives up")
            let ready = expectation(description: "listening")
            ready.isInverted = true
            let failure = LockedBox<ExtensionServer.Failure?>(nil)
            try server.start(retryDelays: [0.1, 0.1], onReady: { _ in ready.fulfill() },
                             onFailure: { failure.value = $0; failed.fulfill() })
            defer { server.stop() }
            await fulfillment(of: [failed, ready], timeout: 3)
            guard case .couldNotListen(let message) = failure.value else { return XCTFail("sharing \(sharing): \(String(describing: failure.value))") }
            XCTAssertTrue(message.contains("in use"), "sharing \(sharing): \(message)")
        }
    }

    func testASquatterCannotJoinThePortTheServerHolds() async throws {
        let server = ExtensionServer(port: 0) { _ in }
        let ready = expectation(description: "listening")
        let bound = LockedBox<UInt16>(0)
        try server.start(onReady: { bound.value = $0; ready.fulfill() })
        defer { server.stop() }
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertThrowsError(try bindLoopback(port: bound.value, sharing: true), "SO_REUSEADDR + SO_REUSEPORT") { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EADDRINUSE)
        }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(bound.value)/health")!)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"ok\":true"), "the server still answers")
    }

    func testRetriesUntilThePortIsFree() async throws {
        let held = try bindLoopback()
        let server = ExtensionServer(port: held.port) { _ in }
        let ready = expectation(description: "listening")
        let failed = expectation(description: "gives up")
        failed.isInverted = true
        let bound = LockedBox<UInt16>(0)
        try server.start(retryDelays: Array(repeating: 0.1, count: 40), onReady: { bound.value = $0; ready.fulfill() },
                         onFailure: { _ in failed.fulfill() })
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(400))
        close(held.socket)
        await fulfillment(of: [ready, failed], timeout: 5)
        XCTAssertEqual(bound.value, held.port)
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(held.port)/health")!)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"ok\":true"))
    }

    func testDefaultRetriesLastAMinuteFastThenSlow() {
        let delays = ExtensionServer.bindRetryDelays
        XCTAssertEqual(delays.prefix(10), ArraySlice(repeating: 0.5, count: 10), "0.5 s for the first 5 s")
        XCTAssertTrue(delays.dropFirst(10).allSatisfy { $0 == 2 }, "then every 2 s")
        XCTAssertEqual(delays.reduce(0, +), 60, accuracy: 1.5, "about a minute")
    }

    /// A quit leaves the connections the server closed in TIME_WAIT (2 x net.inet.tcp.msl, 30 s on macOS), and with
    /// address reuse off the port can't be bound until they expire. The default retries outlast that. The old copy is
    /// a plain socket: a closed connection of this process's own listener doesn't block it, one of another process's
    /// does, and a plain socket's blocks it the same way.
    func testReopensAfterTheOldCopysConnectionsExpire() async throws {
        let old = try bindLoopback()
        let port = old.port
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let client = socket(AF_INET, SOCK_STREAM, 0)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0)
        // The old copy answers and closes first, so its side of the connection waits out TIME_WAIT on the port.
        let accepted = accept(old.socket, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        _ = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".withCString { send(accepted, $0, strlen($0), 0) }
        close(accepted)
        var buffer = [UInt8](repeating: 0, count: 256)
        while recv(client, &buffer, buffer.count, 0) > 0 {}
        close(client)
        close(old.socket)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertThrowsError(try bindLoopback(port: port), "the closed connection holds the port") { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EADDRINUSE)
        }

        let started = Date()
        let reopened = ExtensionServer(port: port) { _ in }
        let settled = expectation(description: "reopened or gave up")
        let readyAfter = LockedBox<TimeInterval?>(nil)
        let failure = LockedBox<ExtensionServer.Failure?>(nil)
        try reopened.start(onReady: { _ in readyAfter.value = Date().timeIntervalSince(started); settled.fulfill() },
                           onFailure: { failure.value = $0; settled.fulfill() })
        defer { reopened.stop() }
        await fulfillment(of: [settled], timeout: 70) // past the 61 s retry window, so it always settles
        print("port \(port): ready after \(readyAfter.value.map { String(format: "%.1f s", $0) } ?? "never"), failure \(String(describing: failure.value))")
        XCTAssertNil(failure.value, "no banner while the old connections expire")
        let waited = try XCTUnwrap(readyAfter.value)
        XCTAssertGreaterThan(waited, 5, "the old retries (10 × 0.5 s) would have given up")
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"ok\":true"))
    }

    func testStopEndsTheRetries() async throws {
        let held = try bindLoopback()
        let server = ExtensionServer(port: held.port) { _ in }
        let reported = expectation(description: "anything after stop")
        reported.isInverted = true
        try server.start(retryDelays: Array(repeating: 0.1, count: 40), onReady: { _ in reported.fulfill() },
                         onFailure: { _ in reported.fulfill() })
        try await Task.sleep(for: .milliseconds(150))
        server.stop()
        close(held.socket)
        await fulfillment(of: [reported], timeout: 1)
    }
}

final class MCPWriteToolTests: XCTestCase {
    var root: URL!
    var server: MCPServer!
    var done: Meeting!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mcpw-\(UUID())")
        let store = MeetingStore(root: root)
        done = meeting()
        try store.save(done)
        server = MCPServer(store: store) { id, edit in try store.edit(id, edit).message }
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func call(_ name: String, _ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
        let message: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
        let line = String(data: try JSONSerialization.data(withJSONObject: message), encoding: .utf8)!
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(server.handle(line: line)).utf8)) as? [String: Any])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (content[0]["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    func testWriteToolsEditThroughTheEditor() throws {
        let id = String(done.id.uuidString.prefix(8))
        XCTAssertTrue(try call("set_action_item_done", ["id": id, "item": "1", "done": true]).text.contains("done"))
        XCTAssertTrue(try call("list_action_items", [:]).text.contains("1. [x] Sam: send the contract"))
        XCTAssertFalse(try call("add_meeting_note", ["id": id, "text": "Filed PRICE-12"]).isError)
        XCTAssertTrue(try call("get_meeting", ["id": id]).text.contains("Filed PRICE-12"))
        XCTAssertTrue(try call("search_meetings", ["query": "PRICE-12"]).text.contains("Pricing review"))
        XCTAssertFalse(try call("rename_meeting", ["id": id, "title": "Pricing v2"]).isError)
        XCTAssertFalse(try call("update_summary", ["id": id, "markdown": "## Overview\nDone."]).isError)
        XCTAssertTrue(try call("get_meeting", ["id": id]).text.contains("# Pricing v2"))
        XCTAssertEqual(try MeetingStore(root: root).load(done.id).summary?.model, "llama3.2:3b, edited")
    }

    func testWriteToolErrorsAreToolErrors() throws {
        let id = done.id.uuidString
        XCTAssertTrue(try call("set_action_item_done", ["id": id, "item": "42", "done": true]).isError)
        XCTAssertTrue(try call("add_meeting_note", ["id": id]).isError)
        XCTAssertTrue(try call("rename_meeting", ["id": UUID().uuidString, "title": "x"]).isError)
    }
}

final class Round4PolicyTests: XCTestCase {
    func testRecordingLimits() {
        let start = Date(timeIntervalSince1970: 0)
        let limits = RecordingLimits()
        XCTAssertNil(limits.stopReason(startedAt: start, lastAudible: start, detected: true, now: start + 14 * 60))
        XCTAssertNotNil(limits.stopReason(startedAt: start, lastAudible: start, detected: true, now: start + 15 * 60))
        XCTAssertNil(limits.stopReason(startedAt: start, lastAudible: start, detected: false, now: start + 3600), "manual recordings ignore silence")
        XCTAssertNotNil(limits.stopReason(startedAt: start, lastAudible: start + 4 * 3600, detected: false, now: start + 4 * 3600))
    }

    func testBackToBackCallsInOneTabAreSeparateCandidates() {
        var tracker = BrowserMeetingTracker()
        let now = Date()
        tracker.record(ExtensionEvent(type: .meeting, platform: .meet, tabId: 3, callId: 100, inMeeting: true, activeSpeakers: ["Ann"], ts: 1_000), now: now)
        XCTAssertEqual(tracker.candidates(now: now).map(\.key), ["chrome-tab:3#100"])
        XCTAssertEqual(tracker.state(forKey: "chrome-tab:3#100")?.activeSpeakers, ["Ann"])
        XCTAssertEqual(tracker.lastSeen(forKey: "chrome-tab:3#100"), now)
        tracker.record(ExtensionEvent(type: .meeting, platform: .meet, tabId: 3, callId: 200, inMeeting: true, ts: 2_000), now: now)
        XCTAssertEqual(tracker.candidates(now: now).map(\.key), ["chrome-tab:3#200"])
        XCTAssertNil(tracker.state(forKey: "chrome-tab:3#100"), "the old call's key no longer reads the new call")
    }

    func testHeartbeatOlderThanEndedIsIgnoredAndURLsMustBeHTTPS() {
        var tracker = BrowserMeetingTracker()
        let now = Date()
        tracker.record(ExtensionEvent(type: .ended, platform: .meet, tabId: 4, ts: 5_000), now: now)
        tracker.record(ExtensionEvent(type: .meeting, platform: .meet, tabId: 4, inMeeting: true, ts: 4_900), now: now)
        XCTAssertTrue(tracker.candidates(now: now).isEmpty)
        tracker.record(ExtensionEvent(type: .meeting, platform: .meet, tabId: 4, url: "javascript:alert(1)", inMeeting: true, ts: 5_100), now: now)
        XCTAssertEqual(tracker.candidates(now: now).count, 1)
        XCTAssertNil(tracker.candidates(now: now).first?.url)
        tracker.record(ExtensionEvent(type: .meeting, platform: .meet, tabId: 4, url: "https://meet.google.com/abc-defg-hij", inMeeting: true, ts: 5_200), now: now)
        XCTAssertEqual(tracker.candidates(now: now).first?.url, "https://meet.google.com/abc-defg-hij")
    }

    func testBothHooksInstallAndRemove() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let setup = ClaudeCodeSetup(serverBinary: URL(fileURLWithPath: "/x/chrupio-mcp"), home: home, environment: [:])
        let target = setup.targets()[0]
        try setup.installHook(target, .all)
        XCTAssertTrue(setup.hookInstalled(in: target.settingsFile, ClaudeCodeSetup.digestHook))
        XCTAssertTrue(setup.hookInstalled(in: target.settingsFile, ClaudeCodeSetup.promptHook))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: target.settingsFile)) as? [String: Any])
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["UserPromptSubmit"])
        XCTAssertTrue(String(data: try Data(contentsOf: target.settingsFile), encoding: .utf8)!.contains("prompt-hook"))
        try setup.installHook(target, .all)
        let again = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: target.settingsFile)) as? [String: Any])
        XCTAssertEqual(((again["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [Any])?.count, 1, "installing twice adds nothing")
        try setup.removeHook(target)
        XCTAssertFalse(setup.hookInstalled(in: target.settingsFile, ClaudeCodeSetup.promptHook))
        XCTAssertFalse(setup.hookInstalled(in: target.settingsFile, ClaudeCodeSetup.digestHook))
    }
}
