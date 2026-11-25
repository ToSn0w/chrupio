import Foundation

public enum ClaudeSummarizerError: LocalizedError, Equatable {
    case notInstalled
    case notLoggedIn
    case timedOut
    /// The session or usage limit is used up; worth trying again once it resets.
    case usageLimit(String)
    /// The claude command is there but could not be started.
    case launchFailed(String)
    case failed(String)
    /// Claude Code can't use the summary model (retired, misspelt, or not on this plan). Retrying won't help.
    case modelUnavailable(String)
    /// This Claude Code doesn't know a flag the summary call uses. `claude update` fixes it; retrying won't.
    case outdated(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Claude Code is not installed (no claude command found)."
        case .notLoggedIn: "Claude Code is not logged in. Run claude and /login."
        case .timedOut: "Claude Code took too long to write the summary."
        case .usageLimit(let message): "Claude Code hit its usage limit: \(message)"
        case .launchFailed(let message): "Claude Code could not be started: \(message)"
        case .failed(let message): "Claude Code could not write the summary: \(message)"
        case .modelUnavailable(let message): "Claude Code can't use the summary model: \(message)"
        case .outdated: "Claude Code is too old for Chrupio's summaries. Run claude update, then try again."
        }
    }

    /// A few words for the meeting's "why not Claude" line.
    public var reason: String {
        switch self {
        case .notInstalled: "not installed"
        case .notLoggedIn: "not logged in"
        case .timedOut: "timed out"
        case .usageLimit: "session limit"
        case .launchFailed: "could not start"
        case .failed: "error"
        case .modelUnavailable: "model unavailable"
        case .outdated: "update Claude Code"
        }
    }

    /// What Claude said, when there is more to it than `reason`.
    var detail: String? {
        switch self {
        case .usageLimit(let message), .launchFailed(let message), .failed(let message),
             .modelUnavailable(let message), .outdated(let message): message
        case .notInstalled, .notLoggedIn, .timedOut: nil
        }
    }

    /// "You've hit your session limit", "Claude usage limit reached", "5-hour limit reached".
    static func isUsageLimit(_ message: String) -> Bool {
        message.range(of: #"(?i)\b(?:session|usage|weekly|5-hour|daily) limit\b|\bhit your (?:\w+ )?limit\b|\blimit (?:reached|will reset)\b"#,
                      options: .regularExpression) != nil
    }

    /// "There is an issue with the selected model", an API `not_found_error`, "model … not found / does not exist".
    static func isModelUnavailable(_ message: String) -> Bool {
        message.range(of: #"(?i)issue with the selected model|not_found_error|\bmodel\b[^\n]{0,80}\b(?:not found|does not exist)|invalid model"#,
                      options: .regularExpression) != nil
    }

    /// The start of every summary failure message, also those saved before `Meeting.summaryError` existed.
    static let failureMessagePrefixes: [String] = {
        let failures: [ClaudeSummarizerError] = [.notInstalled, .notLoggedIn, .timedOut, .usageLimit(""), .launchFailed(""),
                                                 .failed(""), .modelUnavailable(""), .outdated("")]
        let errors: [any Error] = failures + [SummarizerError.emptyTranscript, SummarizerError.notesWontShrink]
        return errors.map { $0.localizedDescription.trimmingCharacters(in: .whitespaces) }
    }()

    /// `message` is one a failed summary leaves on a meeting, not a transcription or audio warning.
    public static func isSummaryFailure(_ message: String?) -> Bool {
        guard let message else { return false }
        return failureMessagePrefixes.contains { message.hasPrefix($0) }
    }

    /// The CLI rejected a flag: it is older than the summary call.
    static func isOutdatedCLI(_ message: String) -> Bool {
        message.range(of: #"(?i)unknown option|unrecognized option|unknown argument"#, options: .regularExpression) != nil
    }
}

/// "Write summaries with Claude" was turned off: the summary stopped before its next Claude call. Not a failure:
/// nothing is retried and no error is shown.
public struct ClaudeSummariesOff: LocalizedError, Equatable {
    public init() {}
    public var errorDescription: String? { "Claude summaries are off in Settings." }
}

/// Summarizes a meeting in one call to the Claude Code CLI (`claude -p`), with the whole transcript and the
/// project context; a transcript too long for one call is summarized in parts (`Summarizer`). The call is isolated: no tools, MCP servers, hooks, CLAUDE.md or saved session, so the
/// Chrupio hooks registered in Claude Code don't run and nothing is written to the user's history.
public struct ClaudeSummarizer: Sendable {
    /// An alias, so a retired model ID never breaks summaries: Claude Code maps it to the current Haiku.
    public static let defaultModel = "haiku"

    /// "Claude Haiku" for the aliases, keeping an ", edited" suffix; anything else (an old full ID, a local model) unchanged.
    public static func displayName(model: String) -> String {
        let suffix = ", edited"
        let base = model.hasSuffix(suffix) ? String(model.dropLast(suffix.count)) : model
        let names = ["haiku": "Claude Haiku", "sonnet": "Claude Sonnet", "opus": "Claude Opus"]
        guard let name = names[base.lowercased()] else { return model }
        return model.hasSuffix(suffix) ? name + suffix : name
    }

    /// Written by Claude (an alias or a full `claude-` ID, any case), as opposed to a model on this Mac.
    public static func isClaudeModel(_ model: String) -> Bool {
        let base = model.components(separatedBy: ",")[0].trimmingCharacters(in: .whitespaces).lowercased()
        return base.hasPrefix("claude") || ["haiku", "sonnet", "opus"].contains(base)
    }

    /// Who wrote the summary, for "Written by …": "Claude Haiku via Claude Code", "qwen3:8b on this Mac", or
    /// "Claude Code" (", edited" kept) when no model was saved or Claude Code wrote it through the MCP server.
    public static func attribution(model: String) -> String {
        let suffix = ", edited"
        let edited = model.hasSuffix(suffix)
        let base = (edited ? String(model.dropLast(suffix.count)) : model).trimmingCharacters(in: .whitespaces)
        if base.isEmpty || base.lowercased() == "claude code" { return "Claude Code" + (edited ? suffix : "") }
        return displayName(model: model) + (isClaudeModel(model) ? " via Claude Code" : " on this Mac")
    }

    public var executable: URL
    public var model: String
    /// CLAUDE_CONFIG_DIR for the call (the logged-in account's config home); nil for Claude's default.
    public var configDir: String?
    /// Project knowledge for the prompt (`MeetingContext.summaryPrompt`).
    public var context: String?
    /// Short project guidance repeated in every part of a long meeting (`MeetingContext.localSummaryGuidance`).
    public var partGuidance: String?
    public var timeout: TimeInterval
    /// People action item owners are checked against besides the meeting's own (the project's people, voice prints).
    public var knownPeople: [String] = []
    /// What kind of meeting the summary is written for (`SummaryTemplate.resolved(for:)`).
    public var template: SummaryTemplate = .standard
    /// The project's ticket key prefix (`MeetingContext.resolvedTicketPrefix`); nil turns ticket handling off.
    public var ticketPrefix: String?
    /// "Write summaries with Claude" is on; asked before every call, so turning it off stops a long summary
    /// between its parts.
    public var isEnabled: @Sendable () async -> Bool = { true }
    public var home: String
    /// A directory with nothing in it for Claude to pick up as a project.
    public var workingDirectory: URL

    public init(executable: URL, model: String = ClaudeSummarizer.defaultModel, configDir: String? = nil, context: String? = nil,
                timeout: TimeInterval = 300, home: String = NSHomeDirectory(),
                workingDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Chrupio-claude", isDirectory: true)) {
        self.executable = executable
        self.model = model
        self.configDir = configDir.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        self.context = context
        self.timeout = timeout
        self.home = home
        self.workingDirectory = workingDirectory
    }

    /// The installed `claude`, or nil.
    public static func findExecutable(home: String = NSHomeDirectory(),
                                      isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        ClaudeCLI.known(home: home, isExecutable: isExecutable)
    }

    /// Transcripts longer than this go through `Summarizer` in parts of `partCharacters`. About 120k tokens at
    /// 3 characters a token, well inside Haiku's context with the system prompt, the project context and the reply.
    public var singleCallCharacters = 360_000
    public var partCharacters = 90_000

    public var arguments: [String] { arguments() }

    /// The isolated `claude -p` call; `schema` nil asks for a free-text reply.
    func arguments(system: String = ClaudePrompts.system, schema: String? = ClaudeNotes.schemaJSON) -> [String] {
        var arguments = [
            "-p",
            "--output-format", "json",
            "--model", model,
            // Turns off CLAUDE.md, hooks, plugins, skills and MCP servers from any settings file.
            "--safe-mode",
            "--setting-sources", "",
            "--settings", #"{"disableAllHooks":true}"#,
            "--strict-mcp-config",
            "--mcp-config", #"{"mcpServers":{}}"#,
            "--tools", "",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--max-turns", "3",
            "--system-prompt", system,
        ]
        if let schema { arguments += ["--json-schema", schema] }
        return arguments
    }

    /// Only what the CLI needs: the app's own environment (CLAUDECODE, API keys, proxies) is not passed on.
    public var environment: [String: String?] {
        let user = (home as NSString).lastPathComponent
        var environment: [String: String?] = [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "PATH": [executable.deletingLastPathComponent().path, "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ":"),
            "LANG": "en_US.UTF-8",
        ]
        if let configDir { environment["CLAUDE_CONFIG_DIR"] = (configDir as NSString).expandingTildeInPath }
        return environment
    }

    /// `fence`: the random tag suffix for this message (tests pass a fixed one).
    public func input(for meeting: Meeting, fence: String = UntrustedText.fenceSuffix()) -> String {
        var text = ""
        // Each block is fenced with a suffix the text can't guess, so it can't close its tag and pose as Chrupio's own instructions.
        if let context, !context.isEmpty { text += UntrustedText.fenced(context, tag: "project_context", suffix: fence) + "\n\n" }
        if let notes = Prompts.userNotes(meeting) { text += UntrustedText.fenced(notes, tag: "user_notes", suffix: fence) + "\n\n" }
        let transcript = Prompts.header(meeting) + ClaudePrompts.languageLine(meeting.language) + "\n" + TranscriptFormatter.plainText(meeting.segments)
        text += UntrustedText.fenced(transcript, tag: "transcript", suffix: fence) + "\n\nWrite the notes for this meeting."
        return text
    }

    /// 300 s for a normal meeting, 1 s more per 100 transcript characters beyond that (a 90k-character call gets
    /// 15 minutes), at most 30 minutes.
    public static func timeout(forTranscriptCharacters characters: Int) -> TimeInterval {
        min(1_800, max(300, (Double(characters) / 100).rounded()))
    }

    /// The system prompt for this meeting: the fixed rules, the template's guidance, and a request for a title
    /// when the meeting's own is a generic fallback.
    func system(for meeting: Meeting) -> String {
        var system = ClaudePrompts.system
        if let ticketPrefix = ticketPrefix.flatMap(MeetingContext.normalizedTicketPrefix) {
            system += "\n\n" + ClaudePrompts.ticketRule(prefix: ticketPrefix)
        }
        if let guidance = template.guidance { system += "\n\nMeeting type: " + guidance }
        if MeetingTitle.isGeneric(meeting.title) { system += "\n\n" + ClaudePrompts.titleRule }
        return system
    }

    public func summarize(_ meeting: Meeting) async throws -> MeetingSummary {
        let transcript = TranscriptFormatter.plainText(meeting.segments)
        guard !transcript.isEmpty else { throw SummarizerError.emptyTranscript }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ClaudeSummarizerError.notInstalled }
        if transcript.count > singleCallCharacters { return try await summarizeInParts(meeting) }
        let wantsTitle = MeetingTitle.isGeneric(meeting.title)
        let result = try await run(arguments(system: system(for: meeting), schema: wantsTitle ? ClaudeNotes.schemaWithTitleJSON : ClaudeNotes.schemaJSON),
                                   input: input(for: meeting), timeout: timeout)
        var notes = try Self.parse(stdout: result.stdout, stderr: result.stderr, status: result.status)
        let items = ActionItemRules.refine(notes.actionItems.map(\.structured), meeting: meeting, knownPeople: knownPeople)
        notes.actionItems = items.map(ClaudeNotes.ActionItem.init)
        var summary = MeetingSummary(markdown: notes.markdown(language: meeting.language, template: template, ticketPrefix: ticketPrefix), model: model, actionItems: items)
        summary.suggestedTitle = wantsTitle ? notes.title.flatMap(MeetingTitle.cleaned) : nil
        summary.template = template == .standard ? nil : template.rawValue
        if let warning = TicketGrounding.warning(for: TicketGrounding.ungrounded(in: summary.markdown, transcript: TranscriptFormatter.plainText(meeting.segments), prefix: ticketPrefix)) {
            summary.warnings = (summary.warnings ?? []) + [warning]
        }
        return summary
    }

    /// A short recap of the meeting for Slack or email, in the meeting's language, written from its summary (or
    /// the transcript when there is none yet).
    public func draftFollowUp(_ meeting: Meeting) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ClaudeSummarizerError.notInstalled }
        let reply = try await complete(system: ClaudePrompts.followUp(language: meeting.language), user: FollowUp.input(for: meeting), schema: nil)
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A very long meeting: `Summarizer` takes notes per part and writes the summary from them, one call each.
    func summarizeInParts(_ meeting: Meeting) async throws -> MeetingSummary {
        let guidance = [partGuidance, template.guidance].compactMap { $0 }.joined(separator: "\n\n")
        var summarizer = Summarizer(model: model, chunkCharacters: partCharacters, tokenBudget: singleCallCharacters / 3,
                                    guidance: guidance.isEmpty ? nil : guidance) { [self] system, user, schema in
            try await complete(system: system, user: user, schema: schema)
        }
        summarizer.knownPeople = knownPeople
        var summary = try await summarizer.summarize(meeting)
        summary.template = template == .standard ? nil : template.rawValue
        if let warning = TicketGrounding.warning(for: TicketGrounding.ungrounded(in: summary.markdown, transcript: TranscriptFormatter.plainText(meeting.segments), prefix: ticketPrefix)) {
            summary.warnings = (summary.warnings ?? []) + [warning]
        }
        return summary
    }

    /// One call with its own instructions: the JSON matching `schema`, or the free-text reply when there is none.
    public func complete(system: String, user: String, schema: String?) async throws -> String {
        let result = try await run(arguments(system: system, schema: schema), input: user,
                                   timeout: Self.timeout(forTranscriptCharacters: user.count))
        return try Self.reply(stdout: result.stdout, stderr: result.stderr, status: result.status)
    }

    private func run(_ arguments: [String], input: String, timeout: TimeInterval) async throws -> ProcessResult {
        // Every call, each part of a long meeting included, goes through here.
        guard await isEnabled() else { throw ClaudeSummariesOff() }
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(executable, arguments: arguments, environment: environment, inheritEnvironment: false,
                                                 input: Data(input.utf8), directory: workingDirectory, timeout: timeout)
        } catch {
            throw ClaudeSummarizerError.launchFailed(String(error.localizedDescription.prefix(300)))
        }
        // Turned off while Claude was answering: the answer is dropped, so it is never saved or notified. Checked before
        // the timeout, so a call that also ran out of time counts as stopped, not as a failure to retry.
        guard await isEnabled() else { throw ClaudeSummariesOff() }
        if result.timedOut { throw ClaudeSummarizerError.timedOut }
        return result
    }

    /// The structured output as JSON text, or the text reply; errors as `parse` reports them.
    static func reply(stdout: String, stderr: String, status: Int32) throws -> String {
        let envelope = (try? JSONSerialization.jsonObject(with: Data(stdout.utf8))) as? [String: Any]
        try check(envelope: envelope.map { ($0["is_error"] as? Bool, $0["result"] as? String) }, stdout: stdout, stderr: stderr, status: status)
        if let structured = envelope?["structured_output"], !(structured is NSNull),
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        if let result = envelope?["result"] as? String, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return result }
        throw ClaudeSummarizerError.failed("the reply was empty (\(envelope?["subtype"] as? String ?? "no result"))")
    }

    /// Throws the error a failed call reported: not logged in, an old CLI, an unusable model, the usage limit, or anything else.
    private static func check(envelope: (isError: Bool?, result: String?)?, stdout: String, stderr: String, status: Int32) throws {
        let message = [envelope?.result, stderr, stdout].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "exit status \(status)"
        guard envelope != nil, envelope?.isError != true, status == 0 else {
            // Only a failed call: a summary or draft may itself mention "the /login page".
            if message.localizedCaseInsensitiveContains("not logged in") || message.localizedCaseInsensitiveContains("/login") {
                throw ClaudeSummarizerError.notLoggedIn
            }
            let short = String(message.prefix(300))
            if ClaudeSummarizerError.isOutdatedCLI(message) { throw ClaudeSummarizerError.outdated(short) }
            if ClaudeSummarizerError.isModelUnavailable(message) { throw ClaudeSummarizerError.modelUnavailable(short) }
            if ClaudeSummarizerError.isUsageLimit(message) { throw ClaudeSummarizerError.usageLimit(short) }
            throw ClaudeSummarizerError.failed(short)
        }
    }

    /// The notes from `claude -p --output-format json`, or the error it reported.
    static func parse(stdout: String, stderr: String, status: Int32) throws -> ClaudeNotes {
        struct Envelope: Decodable {
            var is_error: Bool?
            var result: String?
            var subtype: String?
            var structured_output: ClaudeNotes?
        }
        let decoded = try? JSONDecoder().decode(Envelope.self, from: Data(stdout.utf8))
        try check(envelope: decoded.map { ($0.is_error, $0.result) }, stdout: stdout, stderr: stderr, status: status)
        guard let envelope = decoded else { throw ClaudeSummarizerError.failed("exit status \(status)") }
        if let notes = envelope.structured_output ?? envelope.result.flatMap(ClaudeNotes.decode), !notes.isEmpty {
            return notes
        }
        throw ClaudeSummarizerError.failed("the reply had no notes (\(envelope.subtype ?? "no result"))")
    }
}

/// The notes Claude returns under `--json-schema`, rendered per person.
public struct ClaudeNotes: Codable, Equatable, Sendable {
    public struct Person: Codable, Equatable, Sendable {
        public var name: String
        public var status: [String]
        public var blockers: [String]
        public var nextSteps: [String]

        enum CodingKeys: String, CodingKey {
            case name, status, blockers
            case nextSteps = "next_steps"
        }

        public init(name: String, status: [String], blockers: [String] = [], nextSteps: [String] = []) {
            self.name = name
            self.status = status
            self.blockers = blockers
            self.nextSteps = nextSteps
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            status = try container.decodeIfPresent([String].self, forKey: .status) ?? []
            blockers = try container.decodeIfPresent([String].self, forKey: .blockers) ?? []
            nextSteps = try container.decodeIfPresent([String].self, forKey: .nextSteps) ?? []
        }
    }

    /// Read as {action, owner, deadline, source_quote, confidence, tickets}; replies in the older {task, due} shape still decode.
    public struct ActionItem: Codable, Equatable, Sendable {
        public var owner: String
        public var task: String
        public var tickets: [String]
        public var due: String?
        public var sourceQuote: String?
        public var confidence: Double?
        /// The deadline as YYYY-MM-DD, counted from the meeting's date.
        public var dueDate: String?

        enum CodingKeys: String, CodingKey {
            case owner, action, task, tickets, deadline, due, confidence
            case sourceQuote = "source_quote"
            case deadlineDate = "deadline_date"
        }

        public init(owner: String, task: String, tickets: [String] = [], due: String? = nil, sourceQuote: String? = nil, confidence: Double? = nil,
                    dueDate: String? = nil) {
            self.owner = owner
            self.task = task
            self.tickets = tickets
            self.due = due
            self.sourceQuote = sourceQuote
            self.confidence = confidence
            self.dueDate = dueDate
        }

        init(_ item: SummaryActionItem) {
            self.init(owner: item.owner, task: item.action, tickets: item.tickets ?? [], due: item.deadline,
                      sourceQuote: item.sourceQuote, confidence: item.confidence, dueDate: item.deadlineDate)
        }

        var structured: SummaryActionItem {
            SummaryActionItem(action: task, owner: owner, deadline: due, sourceQuote: sourceQuote, confidence: confidence, tickets: tickets, deadlineDate: dueDate)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            owner = try container.decodeIfPresent(String.self, forKey: .owner) ?? "Unassigned"
            task = try container.decodeIfPresent(String.self, forKey: .action) ?? container.decode(String.self, forKey: .task)
            tickets = try container.decodeIfPresent([String].self, forKey: .tickets) ?? []
            due = try container.decodeIfPresent(String.self, forKey: .deadline) ?? container.decodeIfPresent(String.self, forKey: .due)
            sourceQuote = try container.decodeIfPresent(String.self, forKey: .sourceQuote)
            confidence = try? container.decodeIfPresent(Double.self, forKey: .confidence)
            dueDate = try container.decodeIfPresent(String.self, forKey: .deadlineDate)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(owner, forKey: .owner)
            try container.encode(task, forKey: .action)
            try container.encode(tickets, forKey: .tickets)
            try container.encodeIfPresent(due, forKey: .deadline)
            try container.encodeIfPresent(sourceQuote, forKey: .sourceQuote)
            try container.encodeIfPresent(confidence, forKey: .confidence)
            try container.encodeIfPresent(dueDate, forKey: .deadlineDate)
        }
    }

    public var tldr: String
    public var people: [Person]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    /// A short meeting title, asked for only when the meeting's own is a generic fallback.
    public var title: String?

    enum CodingKeys: String, CodingKey {
        case tldr, people, decisions, title
        case actionItems = "action_items"
    }

    public init(tldr: String, people: [Person], decisions: [String], actionItems: [ActionItem]) {
        self.tldr = tldr
        self.people = people
        self.decisions = decisions
        self.actionItems = actionItems
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tldr = try container.decodeIfPresent(String.self, forKey: .tldr) ?? ""
        people = try container.decodeIfPresent([Person].self, forKey: .people) ?? []
        decisions = try container.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }

    var isEmpty: Bool { tldr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && people.isEmpty }

    static func decode(_ text: String) -> ClaudeNotes? {
        try? JSONDecoder().decode(ClaudeNotes.self, from: Data(Summarizer.tidy(text).utf8))
    }

    static let schemaJSON: String = schema(title: false)
    /// The schema with a required "title".
    static let schemaWithTitleJSON: String = schema(title: true)

    static func schema(title: Bool) -> String {
        let strings: [String: Any] = ["type": "array", "items": ["type": "string"]]
        var schema: [String: Any] = [
            "type": "object",
            "properties": [
                "tldr": ["type": "string"],
                "people": ["type": "array", "items": [
                    "type": "object",
                    "properties": ["name": ["type": "string"], "status": strings, "blockers": strings, "next_steps": strings],
                    "required": ["name", "status", "blockers", "next_steps"],
                ]],
                "decisions": strings,
                "action_items": ["type": "array", "items": [
                    "type": "object",
                    "properties": ["action": ["type": "string"], "owner": ["type": "string"], "deadline": ["type": "string"], "deadline_date": ["type": "string"],
                                   "source_quote": ["type": "string"], "confidence": ["type": "number"], "tickets": strings],
                    "required": ["action", "owner", "source_quote", "confidence", "tickets"],
                ]],
            ],
            "required": ["tldr", "people", "decisions", "action_items"],
        ]
        if title {
            var properties = schema["properties"] as? [String: Any] ?? [:]
            properties["title"] = ["type": "string"]
            schema["properties"] = properties
            schema["required"] = ["tldr", "people", "decisions", "action_items", "title"]
        }
        let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// "## Summary" (the TL;DR), one "###" block per person, "## Decisions" and the "## Action items" checklist
    /// that `ActionItem.parse` and the MCP tools read.
    public func markdown(language: String?, template: SummaryTemplate = .standard, ticketPrefix: String? = nil) -> String {
        let labels = SummaryHeadings(language: language, template: template)
        let clean = StructuredSummary.unbulleted, isNone = StructuredSummary.isNone
        var lines = ["## \(labels.summary)", StructuredSummary.clean(tldr), "", "## \(labels.people)"]
        let kept = people.filter { !isNone($0.name) && !($0.status + $0.blockers + $0.nextSteps).allSatisfy(isNone) }
        if kept.isEmpty { lines.append("- None recorded") }
        let tasks = actionItems.map(\.task)
        for person in kept {
            lines.append("")
            lines.append("### " + StructuredSummary.clean(person.name))
            lines += person.status.map(clean).filter { !isNone($0) }.map { "- \($0)" }
            lines += person.blockers.map(clean).filter { !isNone($0) }.map { "- **\(labels.blocker):** \($0)" }
            // A next step that is also an action item is listed once, as the action item.
            lines += person.nextSteps.map(clean).filter { step in !isNone(step) && !tasks.contains { ActionItemRules.similarity($0, step) >= 0.75 } }
                .map { "- **\(labels.next):** \($0)" }
        }
        lines += ["", "## \(labels.decisions)"]
        let decisions = decisions.map(clean).filter { !isNone($0) }
        lines += decisions.isEmpty ? ["- None recorded"] : decisions.map { "- \($0)" }
        lines += ["", "## \(labels.actionItems)"]
        let items = actionItems.filter { !isNone($0.task) }.map { item -> String in
            // Owners were checked by ActionItemRules.refine (unnamed voices are "Unassigned"); "Others" names nobody.
            let owner = isNone(item.owner) || StructuredSummary.clean(item.owner).lowercased() == "others" ? "Unassigned" : clean(item.owner)
            let task = Summarizer.droppingOwner(owner, from: clean(item.task))
            let keys = item.tickets.flatMap { MeetingContext.ticketKeys(in: $0, prefix: ticketPrefix) }
                .reduce(into: [String]()) { if !$0.contains($1), !task.contains($1) { $0.append($1) } }
            // Parentheses inside the "(PRJ-1; due)" suffix would read as a second suffix.
            let due = item.due.map { StructuredSummary.clean($0.replacingOccurrences(of: #"[()]"#, with: "", options: .regularExpression)) }
                .flatMap { isNone($0) || Summarizer.isNoDueDate($0) ? nil : $0 }
            // The model sometimes repeats the ISO date in the spoken deadline; show it once.
            let isoDate = item.dueDate.flatMap { $0.trimmingCharacters(in: .whitespaces) == due?.trimmingCharacters(in: .whitespaces) ? nil : $0 }
            let when = [due, isoDate].compactMap { $0 }.joined(separator: ", ")
            let extra = (keys + (when.isEmpty ? [] : [when])).joined(separator: "; ")
            return "- [ ] \(owner): \(task)" + (extra.isEmpty ? "" : " (\(extra))")
        }
        lines += items.isEmpty ? ["- None recorded"] : items
        return lines.joined(separator: "\n")
    }
}

enum ClaudePrompts {
    static func languageLine(_ language: String?) -> String {
        Prompts.languageName(language).map { "Spoken language: \($0)\n" } ?? ""
    }

    static let titleRule = """
    The meeting's title is a generic placeholder. Also fill "title": a short title for this meeting, 2 to 6 words, \
    in the language the meeting was spoken in, naming its main topic or purpose (for example "Sprint planning \
    reporting module" or "Daily standup"). No date, no quotes, no platform name. Use names only when the meeting \
    is clearly about one person or client.
    """

    static func followUp(language: String?) -> String {
        let language = Prompts.languageName(language).map { "Write it in \($0)." }
            ?? "Write it in the language the meeting notes are written in."
        return """
        You write a short follow-up message after a meeting, to be pasted into Slack or an email by the person \
        who recorded it ("You"). \(language) Start with one line thanking people or naming the meeting, then a \
        short recap of what was covered, the decisions, and the action items with their owners and deadlines. \
        Use plain text with "-" bullets, no Markdown headings, no greeting placeholders like [Name], no sign-off. \
        Report only what the notes say; never add facts. Keep it under 150 words. Reply with the message only.

        \(UntrustedText.promptRule)
        """
    }

    static let system = """
    You write meeting notes from a speech-to-text transcript. The user message has a <transcript-…> block and, when \
    the user set one up, a <project_context-…> block (background about the project, its people and terms). Reply \
    only through the JSON schema.

    \(UntrustedText.promptRule)

    When the user message also has a <user_notes-…> block: \(Prompts.userNotesRule)

    Language: write every value in the language the meeting was spoken in (named in the transcript header; \
    otherwise the language most of the transcript is in). Keep names, product names, numbers and any ticket keys as they are. Never translate.

    Report only what was said in this meeting. The project context exists so you can spell names and terms, \
    tell who people are and, when the project uses ticket keys, link work to them. It is never a source of facts about this meeting: a ticket, \
    topic or decision that appears only in the context must not appear in the notes.

    The transcript comes from speech recognition and contains mistakes. In your notes, silently fix obvious ones: \
    misheard names of people, products and modules, environments and any ticket numbers. When there is a \
    project context, use it for this. When it lists known mistakes ("heard -> meant"), apply the same judgement to similar ones. \
    Also check every odd word or name against the context's brief, terms and People list: one that sounds like a \
    term or person listed there is that term or person ("Cooper Netties" -> Kubernetes, "plot" in a sentence about environments -> \
    prod). Without a project context, fix only what is obvious from the transcript itself. When you cannot tell what a garbled passage means, leave it out rather than guess. \
    Never quote the transcript word for word (except an action item's "source_quote"); write short clear sentences.

    Speakers: "You" is the person named as recording the meeting. A label that is a name is that person. \
    "Speaker 1", "Speaker 2" and so on are different remote people whose names the app does not know; "Others" \
    is one or more of them. These labels come from automatic voice clustering and can be wrong: one label can \
    cover two people and one person can get two labels, so work out who is speaking turn by turn, not label by \
    label. In standups the host hands over by name ("Thanks Anna. Ben?"), and the next turn is usually that \
    person; people also name themselves or are named in replies. When such evidence shows who a Speaker N turn \
    is, use that person, written "Name (Speaker 2)" in the "people" name, and plain "Name" as an action item owner. \
    Use full names from the context's People list when the first name is unambiguous there. The recorder is \
    always "You" and never a Speaker N: when the host hands over to someone with the recorder's first name, \
    that is a different person with the same first name. When only a first name is known, write \
    "Anna (Speaker 1)". Without such evidence keep the label, e.g. "Speaker 2", also as an action item owner. Never guess a name from the topic \
    alone. The notes never comment on the transcript, the labels or your reasoning.

    Fields:
    - "tldr": two or three sentences: what the meeting covered and its main outcomes.
    - "people": standup-style updates, one entry per person who reported on their work or took on work, in the \
    order they first spoke. "status": what they did or are doing, concretely (modules, environments and any ticket keys). \
    "blockers": what is stopping them, only if said. "next_steps": what they will do next, only if said and not \
    already an action item. One short sentence per item; empty lists are fine. Leave out people who only made small remarks.
    - "decisions": only real decisions or agreements made in this meeting: something chosen, agreed, approved or \
    scheduled. Not status updates and not one person's plan. Empty list if nothing was decided.
    - "action_items": follow-up tasks someone in this transcript committed to or was asked to do. Read them from \
    the transcript itself. Not decisions, open questions, status updates or statements of fact, and nothing that \
    was not said. "action": a short imperative sentence that starts with a verb, with corrected terms, and makes \
    sense on its own. "owner": who will do it, only when the transcript shows who (the sentence names them, or the \
    speaker who says "I will" is "You" or has a name or an identified Speaker N); when that speaker is an \
    unidentified Speaker N, that label ("Speaker 2"); otherwise "Unassigned". Never "Others". "deadline": only if a \
    date or day was said, in words as said ("dziś", "do piątku", "Friday"), no parentheses; otherwise leave it out. \
    "deadline_date": that day as YYYY-MM-DD, counted from the meeting's date in the transcript header ("jutro" is \
    the next day; "do piątku" and "by Friday" are the first Friday on or after the meeting's date); leave it out \
    when no day was said or you cannot tell which day is meant. \
    "source_quote": the transcript words where the task was said, copied exactly, at most 25 words. "confidence": \
    0 to 1, how sure you are that someone really committed to this task. "tickets": the ticket keys it concerns, \
    written as the ticket rule below says; empty if none or when there is no ticket rule. One task per item; list each task once.
    """

    /// Appended to `system` only when the project context sets `ticketPrefix`.
    static func ticketRule(prefix: String) -> String {
        """
        Tickets: this project's ticket keys look like \(prefix)-1234. Write every key that way: "\(prefix)2,366", \
        "\(prefix) 2366" and "ticket 2366" are \(prefix)-2366. Put the keys an action item concerns in its "tickets".
        """
    }
}
