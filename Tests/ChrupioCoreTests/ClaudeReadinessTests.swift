import Foundation
@testable import ChrupioCore
import XCTest

/// Every `claude` here is a fixture or a shell script in a temp folder; auth output is invented, never copied from a real CLI.
final class ClaudeReadinessTests: XCTestCase {
    static let fullHelp = """
    Usage: claude [options] [command] [prompt]

    Options:
      -p, --print                       Print response and exit
      --output-format <format>          Output format
      --model <model>                   Model for the session
      --safe-mode                       Ignore CLAUDE.md, hooks, plugins and skills
      --setting-sources <sources>       Comma-separated list of setting sources
      --strict-mcp-config               Only use MCP servers from --mcp-config
      --tools <tools...>                Tools to allow
      --disable-slash-commands          Disable slash commands
      --no-session-persistence          Don't save the session
      --json-schema <schema>            Structured output schema

    Commands:
      auth                              Manage authentication
      mcp                               Configure MCP servers
    """

    static let loggedInJSON = #"{"loggedIn": true, "authMethod": "claude.ai", "email": "someone@example.com", "orgName": "Example Org"}"#
    static let loggedOutJSON = #"{"loggedIn": false, "authMethod": "none"}"#

    func result(_ status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) -> ProcessResult {
        ProcessResult(status: status, timedOut: timedOut, stdout: stdout, stderr: stderr)
    }

    func testEveryRequiredFlagIsOneTheSummaryCallUses() {
        let arguments = ClaudeSummarizer(executable: URL(fileURLWithPath: "/nonexistent")).arguments
        for flag in ClaudeReadiness.requiredFlags { XCTAssertTrue(arguments.contains(flag), flag) }
    }

    /// A flag added to the summary call must be either checked or deliberately left out, with a reason.
    func testEveryFlagTheSummaryCallPassesIsCheckedOrExcluded() {
        let passed = Set(ClaudeSummarizer(executable: URL(fileURLWithPath: "/nonexistent")).arguments(system: "system", schema: "{}")
            .filter { $0.hasPrefix("-") })
        let required = Set(ClaudeReadiness.requiredFlags)
        let excluded = Set(ClaudeReadiness.excludedFlags.keys)
        XCTAssertEqual(required.union(excluded), passed)
        XCTAssertTrue(required.isDisjoint(with: excluded))
        for (flag, reason) in ClaudeReadiness.excludedFlags { XCTAssertFalse(reason.isEmpty, flag) }
    }

    func testMissingFlags() {
        XCTAssertEqual(ClaudeReadiness.missingFlags(inHelp: Self.fullHelp), [])
        let old = Self.fullHelp.replacingOccurrences(of: "--safe-mode ", with: "").replacingOccurrences(of: "--tools <tools...>", with: "--allowed-tools <tools...>")
        XCTAssertEqual(ClaudeReadiness.missingFlags(inHelp: old), ["--safe-mode", "--tools"])
        // "--tools" inside "--allowed-tools" or "--tools-x" doesn't count.
        XCTAssertEqual(ClaudeReadiness.missingFlags(inHelp: "--allowed-tools --tools-x"), ClaudeReadiness.requiredFlags)
    }

    func testAuthCommandIsSeenInHelp() {
        XCTAssertTrue(ClaudeReadiness.hasAuthCommand(inHelp: Self.fullHelp))
        XCTAssertFalse(ClaudeReadiness.hasAuthCommand(inHelp: "Commands:\n  mcp   Configure MCP servers\n  --auth-token x"))
        XCTAssertFalse(ClaudeReadiness.hasAuthCommand(inHelp: "Commands:\n  auth-helper   Something else"))
        XCTAssertFalse(ClaudeReadiness.hasAuthCommand(inHelp: "Options:\n  auth   an option list, not a command\n"), "only under Commands:")
    }

    func testAuthStatusAnswers() {
        XCTAssertEqual(ClaudeReadiness.interpret(authStatus: result(0, stdout: Self.loggedInJSON)), .loggedIn)
        XCTAssertEqual(ClaudeReadiness.interpret(authStatus: result(0, stdout: #"{"loggedIn":true}"#)), .loggedIn)
        XCTAssertEqual(ClaudeReadiness.interpret(authStatus: result(1, stdout: Self.loggedOutJSON)), .notLoggedIn)
        XCTAssertEqual(ClaudeReadiness.interpret(authStatus: result(1, stdout: #"{"loggedIn": false}"#)), .notLoggedIn)
        XCTAssertEqual(ClaudeReadiness.interpret(authStatus: result(1, stderr: "Not logged in")), .notLoggedIn)
        XCTAssertNil(ClaudeReadiness.interpret(authStatus: result(2, stderr: "error: unknown command 'auth'")))
        XCTAssertNil(ClaudeReadiness.interpret(authStatus: result(0, timedOut: true)))
        XCTAssertNil(ClaudeReadiness.interpret(authStatus: result(0, stdout: "something else")), "exit 0 without a loggedIn key says nothing")
        // A failed run that happens to say true is not trusted as logged in.
        XCTAssertNil(ClaudeReadiness.interpret(authStatus: result(1, stdout: #"{"loggedIn": true}"#)))
        // Values that mention logging in elsewhere don't decide the answer; the loggedIn key does.
        XCTAssertEqual(ClaudeReadiness.interpret(authStatus: result(0, stdout: #"{"loggedIn": true, "orgName": "Not logged in Ltd"}"#)), .loggedIn)
    }

    func testAuthStatusAfterABannerLine() {
        let banner = "Claude Code 9.9.9 (invented banner) {beta}\n"
        XCTAssertEqual(ClaudeReadiness.interpret(authStatus: result(0, stdout: banner + Self.loggedInJSON + "\n")), .loggedIn)
        XCTAssertEqual(ClaudeReadiness.interpret(authStatus: result(1, stdout: banner + Self.loggedOutJSON)), .notLoggedIn)
        // Braces inside strings and nested objects don't end the object early; text after it is ignored.
        let nested = #"{"loggedIn": true, "orgName": "Ex}ample {Org", "extra": {"a": "\"}"}}"# + "\nTip: run claude doctor"
        XCTAssertEqual(ClaudeReadiness.interpret(authStatus: result(0, stdout: banner + nested)), .loggedIn)
        XCTAssertNil(ClaudeReadiness.interpret(authStatus: result(0, stdout: banner + #"{"other": 1}"#)))
    }

    func testConfigFileFallback() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("readiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(".claude.json")
        XCTAssertEqual(ClaudeReadiness.loginFromConfig(file), .unknown, "no file")
        try #"{"numStartups": 3}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeReadiness.loginFromConfig(file), .unknown, "API-key users have no oauthAccount")
        try #"{"oauthAccount": {"emailAddress": "someone@example.com"}}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeReadiness.loginFromConfig(file), .loggedIn)
    }

    func testCheckAsksHelpThenAuthAndNeverAModel() async {
        let calls = Calls()
        let readiness = await ClaudeReadiness.check(configFile: URL(fileURLWithPath: "/nonexistent/.claude.json")) { arguments in
            calls.append(arguments)
            if arguments == ["--help"] { return ProcessResult(status: 0, timedOut: false, stdout: Self.fullHelp, stderr: "") }
            return ProcessResult(status: 1, timedOut: false, stdout: Self.loggedOutJSON, stderr: "")
        }
        XCTAssertEqual(readiness, ClaudeReadiness(login: .notLoggedIn, missingFlags: []))
        XCTAssertEqual(calls.all, [["--help"], ["auth", "status"]])
    }

    func testCheckWithoutAuthCommandUsesTheConfigFile() async {
        let calls = Calls()
        let readiness = await ClaudeReadiness.check(configFile: URL(fileURLWithPath: "/nonexistent/.claude.json")) { arguments in
            calls.append(arguments)
            return ProcessResult(status: 0, timedOut: false, stdout: "--safe-mode --json-schema", stderr: "")
        }
        XCTAssertEqual(readiness.login, .unknown)
        XCTAssertEqual(readiness.missingFlags.count, ClaudeReadiness.requiredFlags.count - 2)
        XCTAssertEqual(calls.all, [["--help"]])
    }

    func testHelpThatFailsReportsNothingMissing() async {
        let readiness = await ClaudeReadiness.check(configFile: URL(fileURLWithPath: "/nonexistent/.claude.json")) { _ in nil }
        XCTAssertEqual(readiness, ClaudeReadiness(login: .unknown, missingFlags: []))
    }

    func testLiveRunsAFakeClaudeWithTheSummaryEnvironment() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("readiness-live-\(UUID().uuidString)", isDirectory: true)
        let home = folder.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.fullHelp.write(to: folder.appendingPathComponent("help.txt"), atomically: true, encoding: .utf8)
        try Self.loggedOutJSON.write(to: folder.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        let fake = folder.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        dir="$(dirname "$0")"
        echo "$*" >> "$dir/calls.txt"
        echo "HOME=$HOME CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR" >> "$dir/env.txt"
        case "$1" in
          --help) cat "$dir/help.txt" ;;
          auth) cat "$dir/auth.json"; exit 1 ;;
          *) echo "unexpected call" >&2; exit 9 ;;
        esac
        """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let configDir = folder.appendingPathComponent("account", isDirectory: true).path
        let readiness = await ClaudeReadiness.live(executable: fake, configDir: configDir, home: home.path)
        XCTAssertEqual(readiness, ClaudeReadiness(login: .notLoggedIn, missingFlags: []))
        let calls = try String(contentsOf: folder.appendingPathComponent("calls.txt"), encoding: .utf8)
        XCTAssertEqual(calls, "--help\nauth status\n")
        let environment = try String(contentsOf: folder.appendingPathComponent("env.txt"), encoding: .utf8)
        XCTAssertTrue(environment.hasPrefix("HOME=\(home.path) CLAUDE_CONFIG_DIR=\(configDir)\n"), environment)
    }

    func testLiveFallsBackToTheConfigFileInTheAccountFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("readiness-live-\(UUID().uuidString)", isDirectory: true)
        let home = folder.appendingPathComponent("home", isDirectory: true)
        let account = folder.appendingPathComponent("account", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"oauthAccount": {"emailAddress": "someone@example.com"}}"#.write(to: account.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let fake = folder.appendingPathComponent("claude")
        // An old CLI: no auth command, no --safe-mode.
        try "#!/bin/sh\necho 'Options:\n  --print\n  --tools <t>'\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let readiness = await ClaudeReadiness.live(executable: fake, configDir: account.path, home: home.path)
        XCTAssertEqual(readiness.login, .loggedIn)
        XCTAssertTrue(readiness.missingFlags.contains("--safe-mode"))
        XCTAssertFalse(readiness.missingFlags.contains("--tools"))
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    var all: [[String]] { lock.withLock { calls } }
    func append(_ arguments: [String]) { lock.withLock { calls.append(arguments) } }
}
