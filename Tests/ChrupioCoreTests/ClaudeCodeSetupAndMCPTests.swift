import XCTest
@testable import ChrupioCore

private func meeting(
    _ title: String, daysAgo: Double, now: Date, status: MeetingStatus = .done,
    summary: String? = "## Action items\n- [ ] Sam: send the contract\n- [x] Anna: book the room"
) -> Meeting {
    let start = now.addingTimeInterval(-daysAgo * 86_400)
    return Meeting(
        title: title, platform: .meet, startedAt: start, endedAt: start + 1_800,
        attendees: ["Sam", "Anna"], selfName: "Lukasz", url: nil,
        segments: (0..<10).map { TranscriptSegment(start: Double($0) * 10, end: Double($0) * 10 + 5, speaker: .me, text: "Line \($0)") },
        summary: summary.map { MeetingSummary(markdown: $0, model: "llama3.2:3b") },
        status: status
    )
}

final class ClaudeCodeSetupTests: XCTestCase {
    var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    func testTargetsCoverDefaultClaudeDirAndConfigDir() throws {
        let binary = URL(fileURLWithPath: "/Apps/Chrupio.app/Contents/MacOS/chrupio-mcp")
        XCTAssertEqual(ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:]).targets().count, 1)

        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude/.claude.json"))
        let withConfigDir = ClaudeCodeSetup(serverBinary: binary, home: home, environment: ["CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude").path])
        let targets = withConfigDir.targets()
        XCTAssertEqual(targets.count, 2, "the same config dir is listed once")
        XCTAssertEqual(targets[0].mcpConfigFile.lastPathComponent, ".claude.json")
        XCTAssertNil(targets[0].configDir)
        XCTAssertEqual(targets[1].settingsFile, home.appendingPathComponent(".claude/settings.json"))
    }

    func testTheSettingsConfigDirIsIncludedOnceAndOnlyWhenItHoldsAConfig() throws {
        let binary = URL(fileURLWithPath: "/x/chrupio-mcp")
        let custom = home.appendingPathComponent("custom-claude", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        func targets(extra: String?, env: [String: String] = [:]) -> [ClaudeCodeSetup.Target] {
            ClaudeCodeSetup(serverBinary: binary, home: home, environment: env, extraConfigDir: extra).targets()
        }
        XCTAssertEqual(targets(extra: custom.path).count, 1, "no .claude.json there yet")

        try Data("{}".utf8).write(to: custom.appendingPathComponent(".claude.json"))
        let found = targets(extra: custom.path)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[1].settingsFile, custom.appendingPathComponent("settings.json"))
        XCTAssertEqual(targets(extra: custom.path, env: ["CLAUDE_CONFIG_DIR": custom.path]).count, 2, "same dir as $CLAUDE_CONFIG_DIR is listed once")
        XCTAssertEqual(targets(extra: "").count, 1)
        XCTAssertEqual(targets(extra: nil).count, 1)

        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude/.claude.json"))
        XCTAssertEqual(targets(extra: home.appendingPathComponent(".claude").path).count, 2, "same dir as ~/.claude is listed once")
    }

    func testRegisteredCommandIsReadFromConfig() throws {
        let file = home.appendingPathComponent(".claude.json")
        try JSONSerialization.data(withJSONObject: ["mcpServers": ["chrupio": ["type": "stdio", "command": "/x/chrupio-mcp"]]]).write(to: file)
        XCTAssertEqual(ClaudeCodeSetup.registeredCommand(in: file), "/x/chrupio-mcp")
        XCTAssertNil(ClaudeCodeSetup.registeredCommand(in: home.appendingPathComponent("missing.json")))
    }

    func testHookIsAddedOnceAndRemovedWithoutTouchingOtherHooks() throws {
        let other: [String: Any] = ["hooks": [["type": "command", "command": "echo hi"]]]
        let settings: [String: Any] = ["model": "opus", "hooks": ["SessionStart": [other], "UserPromptSubmit": [other]]]
        let command = "'/Apps/Chrupio.app/Contents/MacOS/chrupio-mcp' digest"

        let added = ClaudeCodeSetup.addingHook(to: settings, command: command)
        XCTAssertEqual(ClaudeCodeSetup.sessionStartHooks(added).count, 2)
        let again = ClaudeCodeSetup.addingHook(to: added, command: command)
        XCTAssertEqual(ClaudeCodeSetup.sessionStartHooks(again).count, 2, "adding twice keeps one Chrupio hook")

        let removed = ClaudeCodeSetup.removingHook(from: again)
        XCTAssertEqual(ClaudeCodeSetup.sessionStartHooks(removed).count, 1)
        XCTAssertEqual(removed["model"] as? String, "opus")
        XCTAssertEqual(((removed["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [Any])?.count, 1)
    }

    func testInstallHookWritesBackupAndRefusesNonObject() throws {
        let setup = ClaudeCodeSetup(serverBinary: URL(fileURLWithPath: "/x/chrupio-mcp"), home: home, environment: [:])
        let target = setup.targets()[0]
        try Data(#"{"theme":"dark"}"#.utf8).write(to: target.settingsFile)
        try setup.installHook(target, .all)
        XCTAssertTrue(setup.hookInstalled(in: target.settingsFile))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.settingsFile.path + ".chrupio-backup"))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: target.settingsFile)) as? [String: Any])
        XCTAssertEqual(saved["theme"] as? String, "dark")
        try setup.removeHook(target)
        XCTAssertFalse(setup.hookInstalled(in: target.settingsFile))

        try Data("[1]".utf8).write(to: target.settingsFile)
        XCTAssertThrowsError(try setup.installHook(target, .all))
        XCTAssertEqual(try String(contentsOf: target.settingsFile, encoding: .utf8), "[1]")
    }

    func testLegacyRegistrationIsReadByName() throws {
        let file = home.appendingPathComponent(".claude.json")
        try JSONSerialization.data(withJSONObject: ["mcpServers": ["openkrisp": ["type": "stdio", "command": "/old/openkrisp-mcp"]]]).write(to: file)
        XCTAssertNil(ClaudeCodeSetup.registeredCommand(in: file))
        XCTAssertEqual(ClaudeCodeSetup.registeredCommand(in: file, name: ClaudeCodeSetup.legacyServerName), "/old/openkrisp-mcp")
    }

    func testAddingHookReplacesTheOpenKrispHook() throws {
        let legacy: [String: Any] = ["hooks": [["type": "command", "command": "'/Apps/OpenKrisp.app/Contents/MacOS/openkrisp-mcp' digest", "timeout": 10]]]
        let settings: [String: Any] = ["hooks": ["SessionStart": [legacy]]]
        let command = "'/Apps/Chrupio.app/Contents/MacOS/chrupio-mcp' digest"

        let added = ClaudeCodeSetup.addingHook(to: settings, command: command)
        let commands = ClaudeCodeSetup.sessionStartHooks(added).compactMap { $0["command"] as? String }
        XCTAssertEqual(commands, [command], "the OpenKrisp hook is replaced, not kept beside the new one")
        XCTAssertNil(ClaudeCodeSetup.removingHook(from: settings)["hooks"], "removing also deletes the OpenKrisp hook")
    }

    // MARK: Connect with a stub `claude` (never the real CLI or the real home)

    let binary = URL(fileURLWithPath: "/Apps/Chrupio.app/Contents/MacOS/chrupio-mcp")
    let legacyBinary = "/Apps/OpenKrisp.app/Contents/MacOS/openkrisp-mcp"

    /// A `claude` that logs `<CLAUDE_CONFIG_DIR or default> <argv>` and edits the config like `claude mcp` does.
    /// Without CLAUDE_CONFIG_DIR it edits the temporary home's .claude.json, never $HOME's.
    /// `mcp remove <name>` exits 1 while `fail-remove-<name>` exists next to it.
    func makeStubCLI() throws -> (cli: URL, log: URL) {
        let dir = home.appendingPathComponent("stub", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cli = dir.appendingPathComponent("claude")
        let log = dir.appendingPathComponent("argv.log")
        let script = """
        #!/bin/sh
        echo "${CLAUDE_CONFIG_DIR:-default} $*" >> '\(log.path)'
        config='\(home.appendingPathComponent(".claude.json").path)'
        [ -n "$CLAUDE_CONFIG_DIR" ] && config="$CLAUDE_CONFIG_DIR/.claude.json"
        if [ "$2" = remove ]; then
          [ -f '\(dir.path)'/fail-remove-"$5" ] && { echo "remove failed" >&2; exit 1; }
          /usr/bin/plutil -remove "mcpServers.$5" "$config" >/dev/null || exit 1
        elif [ "$2" = add ]; then
          /usr/bin/plutil -insert "mcpServers.$5" -json "{\\"type\\":\\"stdio\\",\\"command\\":\\"$7\\"}" "$config" >/dev/null || exit 1
        fi
        exit 0
        """
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return (cli, log)
    }

    func logLines(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func writeJSON(_ object: [String: Any], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: file)
    }

    func hookCommands(_ file: URL, _ event: String) throws -> [String] {
        ClaudeCodeSetup.entries(try ClaudeCodeSetup.readSettings(file), event).compactMap { $0["command"] as? String }
    }

    /// OpenKrisp as it was left: `openkrisp` registered, its digest hook sharing a group with another hook,
    /// and its prompt hook alone.
    func writeOpenKrispHome(config: URL, settings: URL) throws {
        try writeJSON(["numStartups": 3, "mcpServers": ["openkrisp": ["type": "stdio", "command": legacyBinary], "other": ["command": "/x/other"]]], to: config)
        try writeJSON(["theme": "dark", "hooks": [
            "SessionStart": [["hooks": [["type": "command", "command": "'\(legacyBinary)' digest", "timeout": 10],
                                        ["type": "command", "command": "echo keep"]]]],
            "UserPromptSubmit": [["hooks": [["type": "command", "command": "'\(legacyBinary)' prompt-hook", "timeout": 5]]]],
        ]], to: settings)
    }

    func testConnectReplacesOpenKrispInEveryHomeIncludingDiscoveredOnes() async throws {
        let work = home.appendingPathComponent(".claude-alt", isDirectory: true)
        try writeOpenKrispHome(config: home.appendingPathComponent(".claude.json"), settings: home.appendingPathComponent(".claude/settings.json"))
        try writeOpenKrispHome(config: work.appendingPathComponent(".claude.json"), settings: work.appendingPathComponent("settings.json"))
        try writeJSON(["mcpServers": ["other": ["command": "/x/other"]]], to: home.appendingPathComponent(".claude-unrelated/.claude.json"))
        let (cli, log) = try makeStubCLI()
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])

        XCTAssertEqual(setup.targets().map(\.configDir?.lastPathComponent), [nil, ".claude-alt"], "a home without OpenKrisp is left alone")
        XCTAssertEqual(ClaudeCodeSetup.connection(setup.status(), binary: binary.path, components: .all), .partial)

        let outcome = await setup.connect(cli: cli, components: .all)
        XCTAssertTrue(outcome.ok, outcome.lines.joined(separator: "\n"))
        XCTAssertEqual(logLines(log), [
            "default mcp remove --scope user openkrisp",
            "default mcp add --scope user chrupio -- \(binary.path)",
            "\(work.path) mcp remove --scope user openkrisp",
            "\(work.path) mcp add --scope user chrupio -- \(binary.path)",
        ])
        for (config, settings) in [(home.appendingPathComponent(".claude.json"), home.appendingPathComponent(".claude/settings.json")),
                                   (work.appendingPathComponent(".claude.json"), work.appendingPathComponent("settings.json"))] {
            XCTAssertEqual(ClaudeCodeSetup.registeredCommand(in: config), binary.path)
            XCTAssertNil(ClaudeCodeSetup.registeredCommand(in: config, name: ClaudeCodeSetup.legacyServerName))
            XCTAssertEqual(ClaudeCodeSetup.registeredCommand(in: config, name: "other"), "/x/other")
            XCTAssertEqual(try hookCommands(settings, "SessionStart"), [setup.command(for: ClaudeCodeSetup.digestHook), "echo keep"],
                           "the other hook in the mixed group stays, and ours takes OpenKrisp's place")
            XCTAssertEqual(try hookCommands(settings, "UserPromptSubmit"), [setup.command(for: ClaudeCodeSetup.promptHook)],
                           "the OpenKrisp prompt hook is replaced")
            XCTAssertEqual(try ClaudeCodeSetup.readSettings(settings)["theme"] as? String, "dark")
        }
        XCTAssertEqual(ClaudeCodeSetup.connection(setup.status(), binary: binary.path, components: .all), .connected)

        let settingsBefore = try Data(contentsOf: work.appendingPathComponent("settings.json"))
        let again = await setup.connect(cli: cli, components: .all)
        XCTAssertTrue(again.ok)
        XCTAssertEqual(logLines(log).count, 4, "connecting twice runs no more claude commands")
        XCTAssertEqual(try Data(contentsOf: work.appendingPathComponent("settings.json")), settingsBefore, "nor rewrites settings")

        let removed = await setup.disconnect(cli: cli)
        XCTAssertTrue(removed.ok, removed.lines.joined(separator: "\n"))
        XCTAssertNil(ClaudeCodeSetup.registeredCommand(in: work.appendingPathComponent(".claude.json")), "the discovered home is disconnected too")
        XCTAssertEqual(try hookCommands(work.appendingPathComponent("settings.json"), "SessionStart"), ["echo keep"])
    }

    func testChrupioIsRegisteredEvenWhenTheOpenKrispServerCannotBeRemoved() async throws {
        try writeOpenKrispHome(config: home.appendingPathComponent(".claude.json"), settings: home.appendingPathComponent(".claude/settings.json"))
        let (cli, log) = try makeStubCLI()
        try Data().write(to: cli.deletingLastPathComponent().appendingPathComponent("fail-remove-openkrisp"))
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])

        let outcome = await setup.connect(cli: cli, components: .all)
        XCTAssertEqual(logLines(log), ["default mcp remove --scope user openkrisp", "default mcp add --scope user chrupio -- \(binary.path)"])
        XCTAssertEqual(ClaudeCodeSetup.registeredCommand(in: home.appendingPathComponent(".claude.json")), binary.path)
        XCTAssertTrue(outcome.lines.contains { $0.hasPrefix("Warning: OpenKrisp server NOT removed") && $0.contains("remove failed") }, outcome.lines.joined(separator: "\n"))
        XCTAssertTrue(outcome.lines.contains("MCP server registered in \(setup.targets()[0].label)"))
        XCTAssertEqual(ClaudeCodeSetup.connection(setup.status(), binary: binary.path, components: .all), .partial, "the leftover keeps asking for Connect")
    }

    func testHookMatchingAcceptsOnlyItsOwnCommands() {
        func ours(_ command: String, _ hook: ClaudeCodeSetup.Hook = ClaudeCodeSetup.digestHook) -> Bool {
            ClaudeCodeSetup.isOurHook(["command": command], hook)
        }
        for path in ["/Apps/Chrupio.app/Contents/MacOS/chrupio-mcp", "/Users/a b/My Apps/Chrupio.app/Contents/MacOS/chrupio-mcp",
                     "/Users/o'neil/Chrupio.app/Contents/MacOS/chrupio-mcp", legacyBinary] {
            let setup = ClaudeCodeSetup(serverBinary: URL(fileURLWithPath: path), home: home, environment: [:])
            XCTAssertTrue(ours(setup.command(for: ClaudeCodeSetup.digestHook)), path)
            XCTAssertTrue(ours(setup.command(for: ClaudeCodeSetup.promptHook), ClaudeCodeSetup.promptHook), path)
            XCTAssertFalse(ours(setup.command(for: ClaudeCodeSetup.promptHook)), "the digest hook is not the prompt hook")
        }
        XCTAssertTrue(ours("\"/Users/a b/OpenKrisp.app/Contents/MacOS/openkrisp-mcp\" digest"))
        XCTAssertTrue(ours("/x/chrupio-mcp digest"))
        XCTAssertTrue(ClaudeCodeSetup.isLegacyHook(["command": "'\(legacyBinary)' digest"]))
        XCTAssertFalse(ClaudeCodeSetup.isLegacyHook(["command": "'/x/chrupio-mcp' digest"]))

        for lookalike in ["~/bin/chrupio-mcp-wrapper.sh digest", "cd ~/openkrisp-mcp-fork && make digest", "'/x/chrupio-mcp' digest --verbose",
                          "/x/chrupio-mcp digest; rm -rf /tmp/x", "echo chrupio-mcp digest", "'/x/chrupio-mcp digest", "/x/chrupio-mcp $(digest)"] {
            XCTAssertFalse(ours(lookalike), lookalike)
        }
        let settings: [String: Any] = ["hooks": ["SessionStart": [["hooks": [["type": "command", "command": "~/bin/chrupio-mcp-wrapper.sh digest"]]]]]]
        XCTAssertEqual(ClaudeCodeSetup.sessionStartHooks(ClaudeCodeSetup.removingHook(from: settings)).count, 1, "a lookalike is never removed")
    }

    func testOpenKrispLeftoversMakeStatusPartial() throws {
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])
        let target = setup.targets()[0]
        XCTAssertEqual(ClaudeCodeSetup.connection(setup.status(), binary: binary.path, components: .all), .notConnected)

        try writeJSON(["mcpServers": ["openkrisp": ["command": legacyBinary]]], to: target.mcpConfigFile)
        XCTAssertEqual(ClaudeCodeSetup.connection(setup.status(), binary: binary.path, components: .all), .partial, "only OpenKrisp is not 'not connected'")

        try writeJSON(["mcpServers": ["chrupio": ["command": binary.path]]], to: target.mcpConfigFile)
        try setup.installHook(target, .all)
        XCTAssertEqual(ClaudeCodeSetup.connection(setup.status(), binary: binary.path, components: .all), .connected)
        XCTAssertTrue(setup.isConnected(.all))

        try ClaudeCodeSetup.updateSettings(target.settingsFile) { settings in
            var settings = settings
            var hooks = settings["hooks"] as? [String: Any] ?? [:]
            hooks["UserPromptSubmit"] = (hooks["UserPromptSubmit"] as? [[String: Any]] ?? [])
                + [["hooks": [["type": "command", "command": "'\(legacyBinary)' prompt-hook"]]]]
            settings["hooks"] = hooks
            return settings
        }
        let status = try XCTUnwrap(setup.status().first)
        XCTAssertTrue(status.legacyHookInstalled)
        XCTAssertEqual(ClaudeCodeSetup.connection([status], binary: binary.path, components: .all), .partial, "a leftover OpenKrisp hook is not 'connected'")
        XCTAssertFalse(setup.isConnected(.all))
    }
}

final class MeetingDigestTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testEmptyWhenNothingRecent() {
        XCTAssertEqual(MeetingDigest.text([], now: now), "")
        XCTAssertEqual(MeetingDigest.text([meeting("Old", daysAgo: 9, now: now)], now: now), "")
        XCTAssertEqual(MeetingDigest.text([meeting("Live", daysAgo: 0.1, now: now, status: .recording)], now: now), "")
    }

    func testListsMeetingsAndOnlyOpenItems() {
        let text = MeetingDigest.text([meeting("Pricing", daysAgo: 1, now: now), meeting("Hiring", daysAgo: 2, now: now, summary: nil)], now: now)
        XCTAssertTrue(text.hasPrefix("Chrupio: 2 meeting(s) in the last 7 days."))
        XCTAssertLessThan(text.range(of: "Pricing")!.lowerBound, text.range(of: "Hiring")!.lowerBound, "newest first")
        XCTAssertTrue(text.contains("no summary"))
        XCTAssertTrue(text.contains("Sam: send the contract"))
        XCTAssertFalse(text.contains("book the room"))
    }

    func testStaysWithinLineBudget() {
        let many = (0..<60).map { meeting("Call \($0)", daysAgo: Double($0) / 10, now: now) }
        let text = MeetingDigest.text(many, now: now)
        XCTAssertLessThanOrEqual(text.split(separator: "\n", omittingEmptySubsequences: false).count, 40)
        XCTAssertTrue(text.contains("more (list_meetings)"))
        XCTAssertTrue(text.contains("more (list_action_items)"))
        XCTAssertLessThanOrEqual(text.count, MeetingDigest.maxCharacters)
    }
}

final class ProjectLinkTests: XCTestCase {
    var project: URL!
    var notes: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(UUID())", isDirectory: true)
        project = base.appendingPathComponent("project", isDirectory: true)
        notes = base.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }

    func testLinkCreatesSymlinkAndIgnoresItOnce() throws {
        try Data("node_modules\n".utf8).write(to: project.appendingPathComponent(".gitignore"))
        try ProjectLink.link(project: project, notes: notes)
        try ProjectLink.link(project: project, notes: notes)
        let link = project.appendingPathComponent("meetings")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), notes.path)
        let ignore = try String(contentsOf: project.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertEqual(ignore, "node_modules\n# Chrupio meeting notes (symlink)\n/meetings\n")

        XCTAssertTrue(try ProjectLink.unlink(project: project).hasPrefix("Removed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
    }

    func testNeverReplacesARealFolderOrForeignLink() throws {
        let real = project.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ProjectLink.link(project: project, notes: notes))
        XCTAssertTrue(try ProjectLink.unlink(project: project).hasPrefix("No Chrupio link"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path))

        try FileManager.default.removeItem(at: real)
        try FileManager.default.createSymbolicLink(at: real, withDestinationURL: project.appendingPathComponent(".git"))
        XCTAssertThrowsError(try ProjectLink.link(project: project, notes: notes))
    }
}

final class MCPServerRound2Tests: XCTestCase {
    var root: URL!
    var server: MCPServer!
    var done: Meeting!
    var live: Meeting!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp2-\(UUID())")
        let store = MeetingStore(root: root)
        let now = Date()
        done = meeting("Pricing", daysAgo: 1, now: now)
        try store.save(done)
        live = meeting("Live", daysAgo: 0, now: now, status: .recording)
        try store.save(live)
        // Never reach a running app from tests: edits go straight to the temporary store.
        server = MCPServer(store: store) { id, edit in try store.edit(id, edit).message }
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func send(_ line: String) throws -> [String: Any]? {
        guard let response = server.handle(line: line) else { return nil }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    func request(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        return try XCTUnwrap(try send(String(decoding: data, as: UTF8.self)))
    }

    func toolText(_ name: String, _ arguments: [String: Any]) throws -> String {
        let result = try XCTUnwrap(try request("tools/call", ["name": name, "arguments": arguments])["result"] as? [String: Any])
        return try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
    }

    func testResourcesListAndRead() throws {
        let resources = try XCTUnwrap((try request("resources/list")["result"] as? [String: Any])?["resources"] as? [[String: Any]])
        let uris = resources.compactMap { $0["uri"] as? String }
        XCTAssertTrue(uris.contains("chrupio://action-items"))
        XCTAssertTrue(uris.contains("chrupio://meetings/\(done.id.uuidString)"))
        XCTAssertEqual(uris.count, 2, "live meetings are not listed")

        let read = try request("resources/read", ["uri": "chrupio://meetings/\(done.id.uuidString)"])
        let contents = try XCTUnwrap((read["result"] as? [String: Any])?["contents"] as? [[String: Any]])
        XCTAssertTrue((contents.first?["text"] as? String ?? "").contains("Pricing"))
        let missing = try request("resources/read", ["uri": "chrupio://meetings/\(UUID().uuidString)"])
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? Int, -32002)
        let tooShort = try request("resources/read", ["uri": "chrupio://meetings/nope"])
        XCTAssertEqual((tooShort["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testPrompts() throws {
        let prompts = try XCTUnwrap((try request("prompts/list")["result"] as? [String: Any])?["prompts"] as? [[String: Any]])
        XCTAssertEqual(Set(prompts.compactMap { $0["name"] as? String }), ["recent_meetings", "meeting"])
        let got = try request("prompts/get", ["name": "recent_meetings", "arguments": ["days": "7"]])
        let messages = try XCTUnwrap((got["result"] as? [String: Any])?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
    }

    func testTranscriptPaging() throws {
        let full = try toolText("get_meeting", ["id": done.id.uuidString, "include_transcript": "true"])
        XCTAssertTrue(full.contains("Line 9"), "string booleans are accepted")
        let page = try toolText("get_meeting", ["id": done.id.uuidString, "include_transcript": true, "transcript_offset": 8])
        XCTAssertFalse(page.contains("Line 1\n"))
        XCTAssertTrue(page.contains("Line 9"))
    }

    func testLookupErrors() throws {
        XCTAssertTrue(try toolText("get_meeting", ["id": "ab"]).contains("first 8 characters"))
        let text = try toolText("get_meeting", ["id": String(live.id.uuidString.prefix(8))])
        XCTAssertTrue(text.contains("LIVE: this meeting is being recorded now"), text)
    }

    func testBatchesAndResponsesFromClient() throws {
        XCTAssertEqual(((try send("[]"))?["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertNil(try send(#"{"jsonrpc":"2.0","id":5,"result":{}}"#), "responses from the client get no reply")
        _ = try request("initialize", ["protocolVersion": "2025-06-18"])
        let batch = server.handle(line: #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#) ?? ""
        XCTAssertTrue(batch.contains("-32600"))
    }
}

final class Round2CoreTests: XCTestCase {
    func testFileNameStaysWithinByteLimit() {
        var long = meeting("x", daysAgo: 0, now: Date())
        long.title = String(repeating: "会議", count: 60)
        let name = MeetingExporter.fileName(for: long)
        XCTAssertLessThanOrEqual(name.utf8.count, 255)
        XCTAssertTrue(name.hasSuffix("].md"))
    }

    func testSilenceFillersDroppedOnlyWhenAlone() throws {
        func json(_ texts: [String]) -> Data {
            let items = texts.enumerated().map { ["offsets": ["from": $0.offset * 1000, "to": $0.offset * 1000 + 900], "text": $0.element] }
            return try! JSONSerialization.data(withJSONObject: ["transcription": items])
        }
        XCTAssertTrue(try Transcriber.parse(json: json([" Thank you."])).isEmpty)
        XCTAssertEqual(try Transcriber.parse(json: json([" Send it Monday.", " Thank you."])).count, 2)
    }
}
