import AppKit
import Foundation
import ChrupioCore

// First of all: a snapshot's CHRUPIO_SUPPORT_DIR is for the app only, never for the helper.
if let refusal = AppPaths.helperRefusal(environment: ProcessInfo.processInfo.environment) {
    FileHandle.standardError.write(Data((refusal + "\n").utf8))
    exit(1)
}

// Before anything reads AppPaths, so an OpenKrisp install moves instead of starting an empty Chrupio folder.
LegacyMigration.migrateIfNeeded()

let arguments = Array(CommandLine.arguments.dropFirst())
let binary = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Commands that rewrite meetings on disk refuse while the app runs: it keeps meetings in memory and would write the
/// old version back, or keep recording into audio that is being moved. A custom CHRUPIO_MEETINGS_DIR is not the app's
/// store. (A custom support folder never applies here: the helper refuses to start in a snapshot run.)
func requireAppQuit(_ command: String) {
    guard ProcessInfo.processInfo.environment["CHRUPIO_MEETINGS_DIR"] == nil,
          !NSRunningApplication.runningApplications(withBundleIdentifier: ProjectLink.appDefaultsDomain).isEmpty else { return }
    fail("Chrupio is running. Quit it from the menu bar (Quit Chrupio), then run `chrupio-mcp \(command)` again. Nothing was changed.")
}

func projectArgument() -> URL {
    let path = arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
    return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
}

switch arguments.first {
case nil, "serve":
    // MCP stdio transport: one JSON-RPC message per line on stdin, responses on stdout, logs on stderr.
    // Responses and list_changed notifications go through the session's lock, one whole line per write.
    let session = MCPStdioSession(server: MCPServer()) { line in
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
    let watcher = session.startWatching()
    while let line = readLine(strippingNewline: true) {
        session.receive(line)
    }
    watcher.cancel()

case "digest":
    // SessionStart hook: whatever is printed becomes context. Print nothing when there is nothing to say,
    // and never fail the session start.
    let input = HookInput.read()
    let now = Date()
    // index.json only: no transcript is decoded.
    let cutoff = now.addingTimeInterval(-Double(MeetingDigest.projectDays) * 86_400)
    let meetings = MeetingStore().index().filter { $0.modifiedDate >= cutoff || $0.startedAt >= cutoff }
    let text = MeetingDigest.text(entries: meetings, now: now, project: ProjectContext.from(cwd: input.cwd))
    if !text.isEmpty { print(text) }
    if let session = input.sessionID {
        // Everything finished so far is covered by the digest; the prompt hook reports what comes after.
        var state = HookSessionState.load(session) ?? HookSessionState(since: now)
        state.since = now
        state.lastChecked = now
        state.announced.formUnion(meetings.filter { $0.status == .done || $0.status == .failed }.map(\.id))
        state.save(session)
    }

case "prompt-hook":
    // UserPromptSubmit hook: one line per meeting that finished or started recording since this session last
    // heard about meetings. Silent otherwise, and never blocks the prompt.
    let input = HookInput.read()
    guard let session = input.sessionID else { exit(0) }
    let now = Date()
    guard let state = HookSessionState.load(session) else {
        HookSessionState(since: now, lastChecked: now).save(session)
        exit(0)
    }
    let update = PromptUpdates.lines(MeetingStore().index(), state: state, project: ProjectContext.from(cwd: input.cwd), now: now)
    if !update.lines.isEmpty { print(update.lines.joined(separator: "\n")) }
    if update.state != state { update.state.save(session) }

case "setup", "remove":
    // Claude Code stores this binary's path: setup only from /Applications or ~/Applications. Remove works anywhere.
    if arguments.first == "setup", let refusal = InstallLocation.refusal(serverBinary: binary, commandLine: true) { fail(refusal) }
    let setup = ClaudeCodeSetup(serverBinary: binary)
    let cli = await ClaudeCodeSetup.findCLI()
    // Same default as Connect in the app: the meeting tools only. Hooks an earlier setup installed stay.
    let outcome = arguments.first == "setup"
        ? await setup.connect(cli: cli, components: ClaudeCodeSetup.commandLineSetup(installed: setup.installedComponents()))
        : await setup.disconnect(cli: cli)
    outcome.lines.forEach { print($0) }
    exit(outcome.ok ? 0 : 1)

case "status":
    ClaudeCodeSetup(serverBinary: binary).statusLines().forEach { print($0) }

case "split":
    // Two calls recorded as one: quit the app first, so it doesn't write the old meeting back.
    guard arguments.count == 3, let id = UUID(uuidString: arguments[1]), let offset = TimeInterval(arguments[2]) else {
        fail("usage: chrupio-mcp split <meeting-id> <seconds>")
    }
    requireAppQuit("split")
    do {
        let (first, second) = try MeetingStore().split(id, at: offset, retranscribe: true)
        print("\(first.id): \(first.segments.count) segments, ends at \(Int(first.duration)) s")
        print("\(second.id): \(second.segments.count) segments, \(Int(second.duration)) s; both are retranscribed when Chrupio starts")
    } catch { fail(error.localizedDescription) }

case "voices":
    // Groups a meeting's remote speech by voice and prints the groups; --write saves the names (app must be quit).
    guard arguments.count >= 2, let id = UUID(uuidString: arguments[1]) else {
        fail("usage: chrupio-mcp voices <meeting-id> [--write]")
    }
    do {
        let store = MeetingStore()
        let printsURL = store.root.deletingLastPathComponent().appendingPathComponent("voices.json")
        var meeting = store.annotateVoices(try store.load(id))
        SpeakerAttribution.apply(to: &meeting)
        let threshold = ProcessInfo.processInfo.environment["CHRUPIO_VOICE_THRESHOLD"].flatMap(Float.init) ?? VoiceAttribution.mergeDistance
        VoiceAttribution.apply(to: &meeting, prints: VoicePrints.load(from: printsURL), threshold: threshold)
        let remote = meeting.segments.filter { !$0.speaker.isMe }
        let groups = Dictionary(grouping: remote, by: \.speaker.label).sorted { $0.value.count > $1.value.count }
        for (label, segments) in groups {
            let seconds = Int(segments.reduce(0) { $0 + $1.end - $1.start })
            print("\(label): \(segments.count) lines, \(seconds) s; e.g. \(segments.prefix(2).map { "[\(TranscriptFormatter.timestamp($0.start))] \($0.text.prefix(60))" }.joined(separator: " | "))")
        }
        if arguments.contains("--write") {
            requireAppQuit("voices")
            try store.save(meeting)
            print("saved")
        }
    } catch { fail(error.localizedDescription) }

case "link":
    do { print(try ProjectLink.link(project: projectArgument())) } catch { fail(error.localizedDescription) }

case "unlink":
    do { print(try ProjectLink.unlink(project: projectArgument())) } catch { fail(error.localizedDescription) }

default:
    fail("""
    usage: chrupio-mcp [serve]      MCP server on stdin/stdout (what Claude Code runs)
           chrupio-mcp setup        register the meeting tools with Claude Code (hooks: Settings > Claude Code)
           chrupio-mcp remove       undo setup
           chrupio-mcp status       show registration in each Claude config
           chrupio-mcp digest       print recent meetings (SessionStart hook; reads hook JSON on stdin)
           chrupio-mcp prompt-hook  print meetings finished since the last prompt (UserPromptSubmit hook)
           chrupio-mcp split <id> <s>  split a recording of two calls into two meetings (app must be quit)
           chrupio-mcp voices <id> [--write]  group a meeting's remote speech by voice; --write saves names (app must be quit)
           chrupio-mcp link [dir]   link the notes folder into a project as meetings/
           chrupio-mcp unlink [dir] remove that link
    """)
}
