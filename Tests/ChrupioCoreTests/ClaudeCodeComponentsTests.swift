import Foundation
@testable import ChrupioCore
import XCTest

extension ClaudeCodeSetupTests {
    private var settingsFile: URL { home.appendingPathComponent(".claude/settings.json") }
    private var configFile: URL { home.appendingPathComponent(".claude.json") }

    /// The stub CLI edits `.claude.json` with plutil, which needs the file and its `mcpServers` to exist.
    private func makeConnectableStub() throws -> (cli: URL, log: URL) {
        try writeJSON(["mcpServers": [String: Any]()], to: configFile)
        return try makeStubCLI()
    }

    private func fileMode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testDefaultComponentsAreTheServerOnly() {
        XCTAssertEqual(ClaudeCodeSetup.Components.defaults, .init(mcp: true, digest: false, prompt: false))
        XCTAssertTrue(ClaudeCodeSetup.Components.none.isEmpty)
        XCTAssertFalse(ClaudeCodeSetup.Components.defaults.isEmpty)
    }

    func testConnectWithDefaultsInstallsNoHooks() async throws {
        let (cli, _) = try makeConnectableStub()
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])
        let outcome = await setup.connect(cli: cli, components: .defaults)
        XCTAssertTrue(outcome.ok, outcome.lines.joined(separator: "\n"))
        XCTAssertEqual(ClaudeCodeSetup.registeredCommand(in: configFile), binary.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsFile.path), "no hooks, no settings file")
        XCTAssertTrue(outcome.lines.contains { $0.hasPrefix("Hooks in ") && $0.hasSuffix(": session digest off, prompt updates off") },
                      outcome.lines.joined(separator: "\n"))
        XCTAssertEqual(ClaudeCodeSetup.connection(setup.status(), binary: binary.path, components: .defaults), .connected)
        XCTAssertEqual(ClaudeCodeSetup.connection(setup.status(), binary: binary.path, components: .all), .partial)
    }

    func testTurningOneHookOffRemovesOnlyThatHook() async throws {
        let (cli, _) = try makeConnectableStub()
        try writeJSON(["hooks": ["SessionStart": [["hooks": [["type": "command", "command": "echo keep"]]]]]], to: settingsFile)
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])
        _ = await setup.connect(cli: cli, components: .all)
        XCTAssertEqual(setup.installedComponents(), .all)

        let outcome = await setup.connect(cli: cli, components: .init(mcp: true, digest: false, prompt: true))
        XCTAssertTrue(outcome.lines.contains { $0.hasPrefix("Hooks in ") && $0.hasSuffix("session digest off, prompt updates on") }, outcome.lines.joined(separator: "\n"))
        XCTAssertEqual(try hookCommands(settingsFile, "SessionStart"), ["echo keep"])
        XCTAssertEqual(try hookCommands(settingsFile, "UserPromptSubmit").count, 1)
        XCTAssertEqual(setup.installedComponents(), .init(mcp: true, digest: false, prompt: true))
    }

    func testTurningTheServerOffUnregistersIt() async throws {
        let (cli, log) = try makeConnectableStub()
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])
        _ = await setup.connect(cli: cli, components: .defaults)
        let outcome = await setup.connect(cli: cli, components: .init(mcp: false, digest: true, prompt: false))
        XCTAssertTrue(outcome.ok, outcome.lines.joined(separator: "\n"))
        XCTAssertTrue(outcome.lines.contains("MCP server removed from \(setup.targets()[0].label)"), outcome.lines.joined(separator: "\n"))
        XCTAssertNil(ClaudeCodeSetup.registeredCommand(in: configFile))
        XCTAssertTrue(logLines(log).contains { $0.contains("mcp remove --scope user chrupio") })
        XCTAssertEqual(setup.installedComponents(), .init(mcp: false, digest: true, prompt: false))
    }

    func testInstalledComponentsAndMigration() async throws {
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])
        XCTAssertNil(setup.installedComponents(), "nothing installed")
        let (cli, _) = try makeConnectableStub()
        _ = await setup.connect(cli: cli, components: .all)
        XCTAssertEqual(ClaudeCodeSetup.migrated(stored: nil, installed: setup.installedComponents()), .all, "the owner keeps all three")
        XCTAssertEqual(ClaudeCodeSetup.migrated(stored: .defaults, installed: .all), .defaults, "a stored choice wins")
        XCTAssertNil(ClaudeCodeSetup.migrated(stored: nil, installed: nil), "never connected: new Connects get the defaults")
    }

    func testConnectLineNamesWhatTheSwitchesTurnOn() {
        typealias C = ClaudeCodeSetup.Components
        XCTAssertEqual(C.defaults.connectLine,
                       "Adds the meeting tools only. Turn on the session digest and meeting updates in Settings → Claude Code.")
        XCTAssertEqual(C.all.connectLine,
                       "Adds the meeting tools, the session digest and meeting updates, as set in Settings → Claude Code.")
        XCTAssertEqual(C(mcp: false, digest: true, prompt: false).connectLine,
                       "Adds the session digest, as set in Settings → Claude Code.")
        XCTAssertEqual(C(mcp: true, digest: false, prompt: true).connectLine,
                       "Adds the meeting tools and meeting updates, as set in Settings → Claude Code.")
        XCTAssertEqual(C.none.connectLine, "Nothing is switched on. Turn on at least one switch in Settings → Claude Code.")
    }

    func testSwitchingHooksOffRemovesThemWithoutTheCLIAndAddsNothing() async throws {
        let (cli, _) = try makeConnectableStub()
        try writeJSON(["hooks": ["SessionStart": [["hooks": [["type": "command", "command": "echo keep"]]]]]], to: settingsFile)
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])
        _ = await setup.connect(cli: cli, components: .all)

        let digestOff = setup.removeHooksSwitchedOff(.init(mcp: true, digest: false, prompt: true))
        XCTAssertTrue(digestOff.ok)
        XCTAssertEqual(digestOff.line, "Removed the session digest from Claude Code.")
        XCTAssertEqual(try hookCommands(settingsFile, "SessionStart"), ["echo keep"])
        XCTAssertEqual(try hookCommands(settingsFile, "UserPromptSubmit").count, 1)
        XCTAssertEqual(ClaudeCodeSetup.registeredCommand(in: configFile), binary.path, "the server is left alone")

        XCTAssertNil(setup.removeHooksSwitchedOff(.all).line, "switching on waits for Connect")
        XCTAssertEqual(try hookCommands(settingsFile, "SessionStart"), ["echo keep"], "nothing is added")

        let allOff = setup.removeHooksSwitchedOff(.none)
        XCTAssertEqual(allOff.line, "Removed meeting updates from Claude Code.")
        XCTAssertEqual(try hookCommands(settingsFile, "UserPromptSubmit"), [])
        XCTAssertEqual(setup.installedComponents(), .defaults)
        XCTAssertNil(setup.removeHooksSwitchedOff(.none).line, "nothing left to remove")
    }

    func testSwitchingBothHooksOffNamesBoth() async throws {
        let (cli, _) = try makeConnectableStub()
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])
        _ = await setup.connect(cli: cli, components: .all)
        XCTAssertEqual(setup.removeHooksSwitchedOff(.defaults).line,
                       "Removed the session digest and meeting updates from Claude Code.")
    }

    func testCommandLineSetupKeepsInstalledHooksAndOtherwiseAddsTheServerOnly() {
        XCTAssertEqual(ClaudeCodeSetup.commandLineSetup(installed: nil), .defaults)
        XCTAssertEqual(ClaudeCodeSetup.commandLineSetup(installed: .all), .all, "an earlier install keeps its hooks")
        XCTAssertEqual(ClaudeCodeSetup.commandLineSetup(installed: .init(mcp: false, digest: true, prompt: false)),
                       .init(mcp: true, digest: true, prompt: false), "setup always registers the server")
    }

    func testDisconnectWithoutTheCLIEditsTheConfigAndKeepsTheRest() async throws {
        let (cli, _) = try makeConnectableStub()
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])
        _ = await setup.connect(cli: cli, components: .all)
        // Another server and keys before and after ours, in an order that isn't sorted.
        try Data(#"""
        {"zeta": 1, "mcpServers": {"chrupio": {"type": "stdio", "command": "\#(binary.path)"}, "other": {"command": "/bin/other"}}, "alpha": 2}
        """#.utf8).write(to: configFile)

        let outcome = await setup.disconnect(cli: nil)
        XCTAssertTrue(outcome.ok, outcome.lines.joined(separator: "\n"))
        XCTAssertEqual(outcome.lines.last, "Restart open Claude Code sessions.")
        XCTAssertNil(ClaudeCodeSetup.registeredCommand(in: configFile))
        XCTAssertEqual(ClaudeCodeSetup.registeredCommand(in: configFile, name: "other"), "/bin/other")
        let written = try String(contentsOf: configFile, encoding: .utf8)
        XCTAssertLessThan(try XCTUnwrap(written.range(of: "\"zeta\"")).lowerBound, try XCTUnwrap(written.range(of: "\"alpha\"")).lowerBound)
        XCTAssertEqual(try hookCommands(settingsFile, "SessionStart"), [])
        XCTAssertNil(setup.installedComponents())

        let again = await setup.disconnect(cli: nil)
        XCTAssertFalse(again.lines.contains("Restart open Claude Code sessions."), "nothing was left to remove")
    }

    func testDisconnectWithTheCLIDoesNotAskForARestart() async throws {
        let (cli, _) = try makeConnectableStub()
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])
        _ = await setup.connect(cli: cli, components: .defaults)
        let outcome = await setup.disconnect(cli: cli)
        XCTAssertTrue(outcome.ok)
        XCTAssertFalse(outcome.lines.contains("Restart open Claude Code sessions."))
    }

    /// `.claude.json` as Claude Code writes it (`JSON.stringify(config, null, 2)`, made with node from a hand-written
    /// object, never from a real file): two projects whose paths differ only in Unicode normalization, an env secret,
    /// escapes, an empty object and array, and no newline at the end.
    private func claudeCodeConfig(withOurServers: Bool) -> String {
        let nfc = "/Users/a/Caf\u{E9}", nfd = "/Users/a/Cafe\u{301}"
        let ours = withOurServers ? """
            },
            "chrupio": {
              "type": "stdio",
              "command": "/Apps/Chrupio.app/Contents/MacOS/chrupio-mcp",
              "args": [],
              "env": {}
            },
            "openkrisp": {
              "type": "stdio",
              "command": "/Apps/OpenKrisp.app/Contents/MacOS/openkrisp-mcp"
            }
        """ : """
            }
        """
        return """
        {
          "numStartups": 42,
          "theme": "dark",
          "tipsHistory": {
            "new-user-warmup": 7
          },
          "mcpServers": {
            "other": {
              "type": "stdio",
              "command": "/bin/other",
              "args": [],
              "env": {
                "API_TOKEN": "not-a-real-secret"
              }
        \(ours)
          },
          "projects": {
            "\(nfc)": {
              "allowedTools": [],
              "history": [
                {
                  "display": "fix the \\"bug\\"\\nnow \u{2014} za\u{17C}\u{F3}\u{142}\u{107}",
                  "pastedContents": {}
                }
              ],
              "lastCost": 0.1234
            },
            "\(nfd)": {
              "allowedTools": [
                "Bash"
              ],
              "history": [],
              "lastDuration": 1500
            }
          },
          "firstStartTime": "2026-11-01T10:00:00.000Z",
          "autoUpdates": false
        }
        """
    }

    func testDisconnectWithoutTheCLIChangesOnlyOurEntriesInClaudeCodesFormat() async throws {
        let original = claudeCodeConfig(withOurServers: true)
        try Data(original.utf8).write(to: configFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configFile.path)
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])

        let outcome = await setup.disconnect(cli: nil)
        XCTAssertTrue(outcome.ok, outcome.lines.joined(separator: "\n"))
        XCTAssertEqual(try Data(contentsOf: configFile), Data(claudeCodeConfig(withOurServers: false).utf8),
                       "byte for byte what Claude Code would write without our two servers; both projects are kept")
        XCTAssertEqual(try fileMode(configFile), 0o644, "the config keeps its mode")

        let names = try FileManager.default.contentsOfDirectory(atPath: home.path).filter { $0.hasPrefix(".claude.json.chrupio-backup") }
        XCTAssertEqual(names.count, 2, "one dated first backup and the latest: \(names)")
        for name in names {
            let backup = home.appendingPathComponent(name)
            XCTAssertEqual(try fileMode(backup), 0o600, "a backup holds secrets, so it is private whatever the config's mode")
            XCTAssertEqual(try Data(contentsOf: backup), Data(original.utf8))
        }
    }

    func testTheConfigIsEditedEvenWhenClaudeCodeKeepsSavingIt() throws {
        try Data(claudeCodeConfig(withOurServers: true).utf8).write(to: configFile)
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])
        let target = setup.targets()[0]
        var saves = 0
        let removed = try setup.removeServerEntries(target, retryDelay: 0, beforeWrite: {
            saves += 1
            // Claude Code saves the config between Chrupio's read and write, four times in a row.
            if saves < 5 { try Data(self.claudeCodeConfig(withOurServers: true).replacingOccurrences(of: "42", with: "\(42 + saves)").utf8).write(to: self.configFile) }
        })
        XCTAssertTrue(removed)
        XCTAssertEqual(saves, 5)
        let written = try String(contentsOf: configFile, encoding: .utf8)
        XCTAssertTrue(written.contains(#""numStartups": 46"#), "Claude Code's last save is kept")
        XCTAssertNil(ClaudeCodeSetup.registeredCommand(in: configFile))

        try Data(claudeCodeConfig(withOurServers: true).utf8).write(to: configFile)
        saves = 0
        XCTAssertThrowsError(try setup.removeServerEntries(target, retryDelay: 0, beforeWrite: {
            saves += 1
            try Data(self.claudeCodeConfig(withOurServers: true).replacingOccurrences(of: "42", with: "\(100 + saves)").utf8).write(to: self.configFile)
        })) { error in
            XCTAssertEqual(error.localizedDescription,
                           "Chrupio didn't change \(self.configFile.path): it changed while Chrupio was editing it. Try again.")
        }
        XCTAssertEqual(saves, 5, "five tries, then Chrupio gives up")
        XCTAssertNotNil(ClaudeCodeSetup.registeredCommand(in: configFile), "Claude Code's last save is left as it is")
    }

    func testStatusChecksShowComponentsThatAreOff() async throws {
        let (cli, _) = try makeConnectableStub()
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])
        _ = await setup.connect(cli: cli, components: .defaults)
        let detail = try XCTUnwrap(setup.status().first)
        let checks = detail.checks(binary: binary.path, components: .defaults)
        XCTAssertEqual(checks.map(\.title), ["server OK", "digest off", "prompt updates off"])
        XCTAssertTrue(checks.allSatisfy(\.ok))

        let off = detail.checks(binary: binary.path, components: .init(mcp: false, digest: false, prompt: false))
        XCTAssertEqual(off, [.init("server still registered", ok: false), .init("digest off", ok: true), .init("prompt updates off", ok: true)],
                       "a server switched off but still registered is not OK, as connection() says")
        XCTAssertEqual(ClaudeCodeSetup.connection(setup.status(), binary: binary.path, components: .init(mcp: false, digest: false, prompt: false)), .partial)
        let gone = ClaudeCodeSetup.Status(target: detail.target, registeredCommand: nil, hookInstalled: true, promptHookInstalled: false)
        XCTAssertEqual(gone.checks(binary: binary.path, components: .init(mcp: false, digest: false, prompt: false)),
                       [.init("server off", ok: true), .init("digest still installed", ok: false), .init("prompt updates off", ok: true)])
    }

    func testAHookSwitchedOffButStillThereFails() {
        let target = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:]).targets()[0]
        // A moved copy's hooks: found, not installed for this binary.
        let stale = ClaudeCodeSetup.Status(target: target, registeredCommand: binary.path, hookInstalled: false, promptHookInstalled: false,
                                           digestHookFound: true, promptHookFound: true)
        XCTAssertEqual(stale.checks(binary: binary.path, components: .defaults), [
            .init("server OK", ok: true), .init("digest still installed", ok: false), .init("prompt updates still installed", ok: false),
        ])
        XCTAssertEqual(ClaudeCodeSetup.connection([stale], binary: binary.path, components: .defaults), .partial,
                       "a stale hook with the hook off is not connected")
        let staleOnly = ClaudeCodeSetup.Status(target: target, registeredCommand: nil, hookInstalled: false, promptHookInstalled: false,
                                               digestHookFound: true)
        XCTAssertEqual(ClaudeCodeSetup.connection([staleOnly], binary: binary.path, components: .defaults), .partial,
                       "a stale hook alone is something of ours, not nothing")
        let clean = ClaudeCodeSetup.Status(target: target, registeredCommand: binary.path, hookInstalled: false, promptHookInstalled: false)
        XCTAssertEqual(clean.checks(binary: binary.path, components: .defaults).map(\.title), ["server OK", "digest off", "prompt updates off"])
        XCTAssertEqual(ClaudeCodeSetup.connection([clean], binary: binary.path, components: .defaults), .connected)
    }

    func testDisconnectLeavesASettingsFileWithoutOurHooksAlone() async throws {
        let (cli, _) = try makeConnectableStub()
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])
        _ = await setup.connect(cli: cli, components: .defaults)
        // A trailing comma and a repeated key: Chrupio can't rewrite it, but nothing of ours is in it.
        let unreadable = Data(#"{"theme": "dark", "theme": "light", "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "echo keep"}]}],},}"#.utf8)
        try unreadable.write(to: settingsFile)
        let outcome = await setup.disconnect(cli: cli)
        XCTAssertTrue(outcome.ok, outcome.lines.joined(separator: "\n"))
        XCTAssertEqual(try Data(contentsOf: settingsFile), unreadable)
        XCTAssertNil(ClaudeCodeSetup.registeredCommand(in: configFile))
    }

    func testRewritingAStaleHookKeepsItsGroupAndMatcher() throws {
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])
        let settings: [String: Any] = ["hooks": ["SessionStart": [
            ["matcher": "first", "hooks": [["type": "command", "command": "echo first"]]],
            ["matcher": "startup", "hooks": [["type": "command", "command": "echo before"],
                                             ["type": "command", "command": "'/Old/Chrupio.app/Contents/MacOS/chrupio-mcp' digest", "timeout": 10],
                                             ["type": "command", "command": "echo after"]]],
            ["hooks": [["type": "command", "command": "echo last"]]],
        ]]]
        let command = setup.command(for: ClaudeCodeSetup.digestHook)
        let updated = ClaudeCodeSetup.addingHook(to: settings, command: command, ClaudeCodeSetup.digestHook)
        let groups = try XCTUnwrap((updated["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 3, "no new group")
        XCTAssertEqual(groups.map { $0["matcher"] as? String }, ["first", "startup", nil])
        XCTAssertEqual((groups[1]["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String }, ["echo before", command, "echo after"])
        XCTAssertEqual((groups[1]["hooks"] as? [[String: Any]])?[1]["timeout"] as? Int, 10)

        // Duplicates elsewhere go; a group they leave empty goes with them.
        var duplicated = settings
        duplicated["hooks"] = ["SessionStart": (settings["hooks"] as! [String: Any])["SessionStart"] as! [[String: Any]]
            + [["matcher": "x", "hooks": [["type": "command", "command": "'/Other/chrupio-mcp' digest"]]]]]
        let deduplicated = ClaudeCodeSetup.addingHook(to: duplicated, command: command, ClaudeCodeSetup.digestHook)
        XCTAssertEqual(try hookCommandsOf(deduplicated, "SessionStart"), ["echo first", "echo before", command, "echo after", "echo last"])
        XCTAssertEqual(((deduplicated["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]])?.count, 3)

        // Nothing of ours yet: a new group at the end.
        let fresh = ClaudeCodeSetup.addingHook(to: ["hooks": ["SessionStart": [["matcher": "m", "hooks": [["type": "command", "command": "echo a"]]]]]],
                                               command: command, ClaudeCodeSetup.digestHook)
        let freshGroups = try XCTUnwrap((fresh["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(freshGroups.count, 2)
        XCTAssertNil(freshGroups[1]["matcher"])
        XCTAssertEqual((freshGroups[1]["hooks"] as? [[String: Any]])?.first?["command"] as? String, command)
    }

    private func hookCommandsOf(_ settings: [String: Any], _ event: String) throws -> [String] {
        ClaudeCodeSetup.entries(settings, event).compactMap { $0["command"] as? String }
    }

    private func backupNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: home.path).filter { $0.hasPrefix(".claude.json.chrupio-backup") }.sorted()
    }

    func testHooksOfAMovedAppOrOpenKrispCountAsInstalledAndConnectRewritesThem() async throws {
        let (cli, _) = try makeConnectableStub()
        try writeJSON(["hooks": [
            "SessionStart": [["hooks": [["type": "command", "command": "'/Old/Chrupio.app/Contents/MacOS/chrupio-mcp' digest", "timeout": 10]]]],
            "UserPromptSubmit": [["hooks": [["type": "command", "command": "'\(legacyBinary)' prompt-hook", "timeout": 5]]]],
        ]], to: settingsFile)
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])
        XCTAssertEqual(setup.installedComponents(), .init(mcp: false, digest: true, prompt: true), "a hook is found by its program's name")
        XCTAssertEqual(ClaudeCodeSetup.migrated(stored: nil, installed: setup.installedComponents()), .init(mcp: false, digest: true, prompt: true))
        let components = ClaudeCodeSetup.commandLineSetup(installed: setup.installedComponents())
        XCTAssertEqual(components, .all, "setup keeps both hooks")

        let outcome = await setup.connect(cli: cli, components: components)
        XCTAssertTrue(outcome.ok, outcome.lines.joined(separator: "\n"))
        XCTAssertEqual(try hookCommands(settingsFile, "SessionStart"), [setup.command(for: ClaudeCodeSetup.digestHook)], "the old path is rewritten")
        XCTAssertEqual(try hookCommands(settingsFile, "UserPromptSubmit"), [setup.command(for: ClaudeCodeSetup.promptHook)])
        XCTAssertEqual(ClaudeCodeSetup.connection(setup.status(), binary: binary.path, components: .all), .connected)
    }

    func testServerOnlyConnectLeavesASettingsFileItCannotReadAlone() async throws {
        let (cli, _) = try makeConnectableStub()
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])
        // A repeated key: Chrupio would refuse to rewrite this file, but no hook is wanted and none of ours is in it.
        let unreadable = Data(#"{"theme": "dark", "theme": "light"}"#.utf8)
        try unreadable.write(to: settingsFile)
        let outcome = await setup.connect(cli: cli, components: .defaults)
        XCTAssertTrue(outcome.ok, outcome.lines.joined(separator: "\n"))
        XCTAssertEqual(try Data(contentsOf: settingsFile), unreadable)

        // One of our hooks is in it: it has to come out, and Chrupio says it couldn't.
        let withHook = Data(#"{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "'\#(binary.path)' digest"}]}]}, "theme": "a", "theme": "b"}"#.utf8)
        try withHook.write(to: settingsFile)
        let refused = await setup.connect(cli: cli, components: .defaults)
        XCTAssertFalse(refused.ok)
        XCTAssertTrue(refused.lines.contains { $0.hasPrefix("Hook NOT removed from \(settingsFile.path)") }, refused.lines.joined(separator: "\n"))
        XCTAssertEqual(try Data(contentsOf: settingsFile), withHook)
    }

    func testARefusedEditLeavesTheBackupsAlone() throws {
        try Data(claudeCodeConfig(withOurServers: true).utf8).write(to: configFile)
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])
        let target = setup.targets()[0]
        var saves = 0
        let keepSaving = {
            saves += 1
            try Data(self.claudeCodeConfig(withOurServers: true).replacingOccurrences(of: "42", with: "\(100 + saves)").utf8).write(to: self.configFile)
        }
        XCTAssertThrowsError(try setup.removeServerEntries(target, retryDelay: 0, beforeWrite: keepSaving))
        XCTAssertEqual(try backupNames(), [], "nothing was changed, so nothing was backed up")

        try setup.removeServerEntries(target, retryDelay: 0)
        let latest = home.appendingPathComponent(".claude.json.chrupio-backup")
        let backups = try backupNames()
        XCTAssertEqual(backups.count, 2)
        let before = try Data(contentsOf: latest)

        try Data(claudeCodeConfig(withOurServers: true).utf8).write(to: configFile)
        XCTAssertThrowsError(try setup.removeServerEntries(target, retryDelay: 0, beforeWrite: keepSaving))
        XCTAssertEqual(try Data(contentsOf: latest), before, "a refused edit doesn't replace the latest backup")
        XCTAssertEqual(try backupNames(), backups)
    }

    func testDisconnectRemovesTheHooksWhenTheConfigCannotBeEdited() async throws {
        let (cli, _) = try makeConnectableStub()
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])
        _ = await setup.connect(cli: cli, components: .all)
        let label = setup.targets()[0].label
        // A repeated key: Chrupio won't rewrite .claude.json.
        try Data(#"{"mcpServers": {"chrupio": {"command": "\#(binary.path)"}}, "theme": "a", "theme": "b"}"#.utf8).write(to: configFile)

        let outcome = await setup.disconnect(cli: nil)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(try hookCommands(settingsFile, "SessionStart"), [], "the hooks still come out")
        XCTAssertEqual(try hookCommands(settingsFile, "UserPromptSubmit"), [])
        XCTAssertTrue(outcome.lines.contains { $0.hasPrefix("Could not fully remove from \(label): Chrupio didn't change \(configFile.path)") },
                      outcome.lines.joined(separator: "\n"))

        // Both files refused: both are reported.
        try Data(#"{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "'\#(binary.path)' digest"}]}]}, "theme": "a", "theme": "b"}"#.utf8)
            .write(to: settingsFile)
        let both = await setup.disconnect(cli: nil)
        let line = try XCTUnwrap(both.lines.first { $0.hasPrefix("Could not fully remove from \(label): ") }, both.lines.joined(separator: "\n"))
        XCTAssertTrue(line.contains(configFile.path) && line.contains(settingsFile.path), line)
    }

    func testConnectWithoutTheCLIRemovesOpenKrispsServer() async throws {
        try writeJSON(["mcpServers": ["openkrisp": ["type": "stdio", "command": legacyBinary], "other": ["command": "/bin/other"]]], to: configFile)
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])
        let outcome = await setup.connect(cli: nil, components: .defaults)
        XCTAssertFalse(outcome.ok, "the server still needs the CLI")
        XCTAssertNil(ClaudeCodeSetup.registeredCommand(in: configFile, name: ClaudeCodeSetup.legacyServerName))
        XCTAssertEqual(ClaudeCodeSetup.registeredCommand(in: configFile, name: "other"), "/bin/other")
        XCTAssertEqual(outcome.lines.last, ClaudeCodeSetup.restartLine)
    }

    func testCommandLineStatusCallsHooksNoOneInstalledOff() async throws {
        let (cli, _) = try makeConnectableStub()
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:])
        let label = setup.targets()[0].label
        _ = await setup.connect(cli: cli, components: .defaults)
        XCTAssertEqual(setup.statusLines(), ["\(label): MCP registered; digest off; prompt updates off"])

        _ = await setup.connect(cli: cli, components: .all)
        XCTAssertEqual(setup.statusLines(), ["\(label): MCP registered; digest hook installed; prompt hook installed"])

        // Installed in another home but not this one: missing, not off.
        let other = home.appendingPathComponent(".claude-alt", isDirectory: true)
        try writeJSON(["mcpServers": ["chrupio": ["command": binary.path]]], to: other.appendingPathComponent(".claude.json"))
        try writeJSON(["hooks": ["SessionStart": [["hooks": [["type": "command", "command": setup.command(for: ClaudeCodeSetup.digestHook)]]]]]],
                      to: other.appendingPathComponent("settings.json"))
        try writeJSON([:], to: settingsFile)
        XCTAssertEqual(setup.statusLines().first, "\(label): MCP registered; digest hook missing; prompt updates off")

        // A hook of ours for another copy: says so, not "missing".
        try writeJSON(["hooks": [
            "SessionStart": [["hooks": [["type": "command", "command": "'/Old/Chrupio.app/Contents/MacOS/chrupio-mcp' digest"]]]],
            "UserPromptSubmit": [["hooks": [["type": "command", "command": "'/Old/Chrupio.app/Contents/MacOS/chrupio-mcp' prompt-hook"]]]],
        ]], to: settingsFile)
        XCTAssertEqual(setup.statusLines().first,
                       "\(label): MCP registered; digest hook points to another copy; prompt hook points to another copy")
    }

    func testKnownConfigDirsAreTargetsWhenTheyHoldAConfig() throws {
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try writeJSON(["mcpServers": ["chrupio": ["command": binary.path]]], to: elsewhere.appendingPathComponent(".claude.json"))
        let setup = ClaudeCodeSetup(serverBinary: binary, home: home, environment: [:], knownConfigDirs: [elsewhere.path, "/nonexistent/x", elsewhere.path])
        let dirs = setup.targets().compactMap { $0.configDir?.resolvingSymlinksInPath().path }
        XCTAssertTrue(dirs.contains(elsewhere.resolvingSymlinksInPath().path))
        XCTAssertFalse(dirs.contains("/nonexistent/x"))
        XCTAssertEqual(setup.targets().count, 2, "default home + the known one, listed once")
    }
}
