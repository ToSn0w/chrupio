import Foundation

public enum SummarizerError: LocalizedError {
    case emptyTranscript
    case notesWontShrink

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript: "Nothing to summarize: the transcript is empty."
        case .notesWontShrink: "The notes of this long meeting couldn't be condensed to fit; nothing was cut, so no summary was written."
        }
    }
}

/// Summarizes a meeting in parts: each part's notes and tasks first, then one call that writes the summary from the
/// notes. `ClaudeSummarizer` uses it for transcripts too long for one call; `chat` is one Claude call.
public struct Summarizer: Sendable {
    /// One model call: the system prompt, the user message and, for a JSON reply, the JSON schema it must match.
    public typealias Chat = @Sendable (_ system: String, _ user: String, _ schema: String?) async throws -> String

    public var model: String
    /// Transcripts longer than this are summarized in parts first.
    public var chunkCharacters: Int
    /// Project knowledge (house style, usual topics, spellings) added to the instructions.
    public var guidance: String?
    /// People action item owners are checked against besides the meeting's own (the project's people, voice prints).
    public var knownPeople: [String] = []
    /// What the final call of a long meeting may take, in tokens estimated as characters / 3 (`estimatedTokens`):
    /// instructions, guidance, meeting header, the user's notes and the part notes together. Part notes are condensed
    /// level by level until they fit; nothing is ever cut.
    public var tokenBudget: Int
    public var chat: Chat

    public init(model: String, chunkCharacters: Int = 8_000, tokenBudget: Int = 100_000, guidance: String? = nil, chat: @escaping Chat) {
        self.model = model
        self.chunkCharacters = chunkCharacters
        self.tokenBudget = tokenBudget
        self.guidance = guidance
        self.chat = chat
    }

    public func summarize(_ meeting: Meeting) async throws -> MeetingSummary {
        let transcript = TranscriptFormatter.plainText(meeting.segments)
        guard !transcript.isEmpty else { throw SummarizerError.emptyTranscript }

        let chunks = Self.split(transcript, maxCharacters: chunkCharacters)
        guard chunks.count > 1 else {
            let user = Prompts.summaryUser(meeting: meeting, material: transcript, isNotes: false)
            // Structured output keeps the sections and checklist format exact; free text is the fallback when
            // the reply doesn't match the schema. A timeout or failed request is thrown, not retried as free
            // text, since a second run would take as long again.
            let json = try await chat(Prompts.withGuidance(Prompts.structuredSystem(language: meeting.language), guidance), user, StructuredSummary.schemaJSON)
            if let structured = StructuredSummary.decode(json) {
                return refined(structured, meeting: meeting)
            }
            let markdown = try await chat(Prompts.withGuidance(Prompts.summarySystem(language: meeting.language), guidance), user, nil)
            return freeText(Self.tidy(markdown), meeting: meeting)
        }

        // Long meetings: each part returns its tasks as data, merged here, so the final call can't drop or
        // translate them. The final call writes only the summary, key points and decisions from the notes.
        var notes: [String] = []
        var actionItems: [StructuredSummary.ActionItem] = []
        var warnings: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let user = Prompts.partUser(chunk, meeting: meeting, part: index + 1, of: chunks.count)
            let reply = try await chat(Prompts.withGuidance(Prompts.partSystem(language: meeting.language), guidance), user, PartNotes.schemaJSON)
            var part = PartNotes.decode(reply)
            var text = Self.tidy(reply)
            if part == nil {
                // An unusable JSON reply would drop the part's tasks; the same part is asked once more as plain lists.
                let retry = try await chat(Prompts.withGuidance(Prompts.partFreeTextSystem(language: meeting.language), guidance), user, nil)
                part = PartNotes.parseFreeText(retry)
                text = Self.tidy(retry)
                if part == nil {
                    warnings.append("Part \(index + 1) of \(chunks.count): the notes couldn't be read, so its action items may be missing.")
                }
            }
            actionItems += part?.actionItems ?? []
            notes.append("Part \(index + 1):\n" + (part?.text ?? text))
        }
        // A generic title ("Browser call") gets a suggested one from the final call, as a single call would.
        let wantsTitle = MeetingTitle.isGeneric(meeting.title)
        var structuredSystem = Prompts.withGuidance(Prompts.structuredSystem(language: meeting.language, actionItems: false), guidance)
        if wantsTitle { structuredSystem += "\n\n" + ClaudePrompts.titleRule }
        let freeTextSystem = Prompts.withGuidance(Prompts.summarySystem(language: meeting.language, actionItems: false), guidance)
        // Everything in the final call except the notes, with the longer of its two system prompts.
        let overhead = max(Self.estimatedTokens(structuredSystem), Self.estimatedTokens(freeTextSystem))
            + Self.estimatedTokens(Prompts.summaryUser(meeting: meeting, material: "", isNotes: true))
        let combined = try await fitted(notes.joined(separator: "\n\n"), maxCharacters: Self.notesCharacters(budget: tokenBudget, overhead: overhead),
                                        language: meeting.language)
        let items = StructuredSummary.merged(actionItems)
        let user = Prompts.summaryUser(meeting: meeting, material: combined, isNotes: true)
        let json = try await chat(structuredSystem, user, wantsTitle ? StructuredSummary.notesSchemaWithTitleJSON : StructuredSummary.notesSchemaJSON)
        if var structured = StructuredSummary.decode(json) {
            structured.actionItems = items
            var summary = refined(structured, meeting: meeting)
            summary.warnings = warnings.isEmpty ? nil : warnings
            summary.suggestedTitle = wantsTitle ? StructuredSummary.title(in: json).flatMap(MeetingTitle.cleaned) : nil
            return summary
        }
        let markdown = try await chat(freeTextSystem, user, nil)
        // Whatever the model wrote under "## Action items" is replaced by the merged items.
        var text = Self.tidy(markdown)
        if let section = text.range(of: #"(?m)^## Action items\b"#, options: .regularExpression) {
            text = String(text[..<section.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let kept = ActionItemRules.refine(items.map(\.structured), meeting: meeting, knownPeople: knownPeople)
        let rendered = StructuredSummary(summary: "", keyPoints: [], decisions: [], actionItems: kept.map(StructuredSummary.ActionItem.init)).actionItemsMarkdown
        var summary = MeetingSummary(markdown: text + "\n\n## Action items\n" + rendered, model: model, actionItems: kept)
        summary.warnings = warnings.isEmpty ? nil : warnings
        return summary
    }

    /// Tokens as the budget counts them: about 3 characters each, on the safe side for Polish and English.
    static func estimatedTokens(_ text: String) -> Int { (text.count + 2) / 3 }

    /// Characters of notes that fit beside `overhead` tokens; a quarter of the budget at least, so huge guidance
    /// can't leave the notes nothing.
    static func notesCharacters(budget: Int, overhead: Int) -> Int {
        max(budget - overhead, budget / 4) * 3
    }

    /// Condenses the notes level by level until they fit `maxCharacters`, with no limit on levels: each level splits
    /// them into groups no longer than a group may be (`chunkCharacters`, and never more than `maxCharacters`), and
    /// every group is condensed (`condensed`). Nothing is cut; a level that doesn't shrink the notes at all throws
    /// instead of looping.
    func fitted(_ notes: String, maxCharacters: Int, language: String?) async throws -> String {
        var combined = notes
        let groupCharacters = max(min(chunkCharacters, maxCharacters), 1)
        while combined.count > maxCharacters {
            let groups = Self.split(combined, maxCharacters: groupCharacters)
            var condensed: [String] = []
            for group in groups {
                condensed += try await self.condensed(group, language: language)
            }
            let shorter = condensed.joined(separator: "\n")
            guard shorter.count < combined.count else { throw SummarizerError.notesWontShrink }
            combined = shorter
        }
        return combined
    }

    /// Groups shorter than this that a call doesn't shrink are kept as they are, not split further.
    static let smallestGroup = 200

    /// One group's notes condensed, as one or more pieces. A reply not shorter by a tenth is thrown away and the
    /// group is split in two and each half condensed, down to `smallestGroup`, which is kept word for word.
    func condensed(_ group: String, language: String?) async throws -> [String] {
        let reply = Self.tidy(try await chat(Prompts.condenseSystem(language: language), Prompts.notesUser(group), nil))
        if !reply.isEmpty, reply.count + 1 <= group.count * 9 / 10 { return [reply] }
        guard group.count >= Self.smallestGroup else { return [group.trimmingCharacters(in: .newlines)] }
        var pieces: [String] = []
        for half in Self.split(group, maxCharacters: (group.count + 1) / 2) {
            pieces += try await condensed(half, language: language)
        }
        return pieces
    }

    /// The structured summary with its action items checked (`ActionItemRules.refine`) and kept as data.
    func refined(_ structured: StructuredSummary, meeting: Meeting) -> MeetingSummary {
        var structured = structured
        let items = ActionItemRules.refine(structured.actionItems.map(\.structured), meeting: meeting, knownPeople: knownPeople)
        structured.actionItems = items.map(StructuredSummary.ActionItem.init)
        return MeetingSummary(markdown: structured.markdown(headings: SummaryHeadings(language: meeting.language)), model: model, actionItems: items)
    }

    /// A free-text summary; a short call's checklist is emptied.
    func freeText(_ markdown: String, meeting: Meeting) -> MeetingSummary {
        MeetingSummary(markdown: ActionItemRules.isShortCall(meeting) ? ActionItemRules.clearingActionItems(markdown) : markdown, model: model)
    }

    /// Splits on line boundaries so no chunk exceeds `maxCharacters`; a single longer line is split inside it.
    /// Each chunk keeps its line breaks, so the chunks joined with nothing between them are exactly `text`.
    static func split(_ text: String, maxCharacters: Int) -> [String] {
        let limit = max(maxCharacters, 1)
        var chunks: [String] = []
        var current = ""
        var rest = Substring(text)
        while !rest.isEmpty {
            let end = rest.firstIndex(of: "\n").map { rest.index(after: $0) } ?? rest.endIndex
            var line = rest[..<end]
            rest = rest[end...]
            if current.count + line.count > limit, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            while line.count > limit {
                chunks.append(String(line.prefix(limit)))
                line = line.dropFirst(limit)
            }
            current += line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Removes reasoning blocks and code fences some models wrap around Markdown, and the tags Chrupio fences meeting
    /// text in (`UntrustedText.fenced`) when a model echoes them.
    static func tidy(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?im)^[ \t]*"# + fenceTagPattern + #"[ \t]*(?:\n|$)"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: fenceTagPattern, with: "", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            result = result.replacingOccurrences(of: #"^```[a-z]*\n?"#, with: "", options: .regularExpression)
            result = result.replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
        }
        // Small models sometimes write an empty list as a task ("- [ ] Unassigned: None recorded"), which would read as an open action item.
        result = result.replacingOccurrences(of: #"(?im)^[-*] \[[ x]\] (?:[^:\n]+: )?none( recorded)?\.?[ \t]*$"#, with: "- None recorded", options: .regularExpression)
        // "Others" as an owner names nobody. "Speaker 2" stays: naming that voice later renames the owner.
        result = result.replacingOccurrences(of: #"(?im)^([-*] \[[ x]\] )others: "#, with: "$1Unassigned: ", options: .regularExpression)
        return tidyActionItems(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An opening or closing fence tag such as "</transcript-4f9a1c2e>"; no nested repetition, so it runs in linear time.
    static let fenceTagPattern = #"(?i)</?(?:"# + UntrustedText.reservedTags.joined(separator: "|") + #")-[0-9a-f]{8}>"#

    /// "Speaker 2", "Others": labels for remote speakers whose names are unknown, so not an owner.
    static func isUnknownSpeaker(_ label: String) -> Bool {
        label.range(of: #"^(?:speaker \d+|mówca \d+|others)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Fixes checklist lines in free-text and stored summaries: an owner written twice ("Gustavo: Gustavo: fix it")
    /// and a due date that says there is none ("(no due date specified)").
    static func tidyActionItems(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").map { line in
            guard let match = line.firstMatch(of: /^(\s*[-*+]\s+\[[ xX]\]\s+)([^:]{1,60}):\s+(.*)$/) else { return line }
            let owner = String(match.2)
            var task = droppingOwner(owner, from: String(match.3))
            if let due = task.firstMatch(of: /\s*\(([^()]*)\)\s*$/), isNoDueDate(String(due.1)) {
                task = String(task[..<due.range.lowerBound])
            }
            return "\(match.1)\(owner): \(task)"
        }.joined(separator: "\n")
    }

    /// The task without a leading "<owner>:" the model already wrote into it.
    static func droppingOwner(_ owner: String, from task: String) -> String {
        var task = task
        let prefix = owner.trimmingCharacters(in: .whitespaces) + ":"
        while prefix.count > 1, task.lowercased().hasPrefix(prefix.lowercased()) {
            task = String(task.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return task
    }

    /// Due values small models write when no date was said: "no due date specified", "not specified",
    /// "none - ongoing", "brak terminu".
    static func isNoDueDate(_ text: String) -> Bool {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let patterns = [
            #"^$"#, #"^none\b"#, #"^n/?a$"#, #"^tbd$"#, #"^ongoing$"#, #"^unspecified$"#,
            #"^no (?:due )?(?:date|deadline|term)\b"#, #"^not (?:specified|mentioned|given|set|stated|said)\b"#,
            #"^brak\b"#, #"^bez (?:terminu|daty)\b"#, #"^nie (?:określono|podano|ustalono|wskazano)\b"#, #"^nieokreślon"#,
        ]
        return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
    }
}

/// The summary as returned under a JSON schema, rendered to the same Markdown as free-text summaries.
struct StructuredSummary: Decodable, Equatable {
    struct ActionItem: Decodable, Equatable {
        var owner: String
        var task: String
        var due: String?
        var sourceQuote: String?
        var confidence: Double?
        var deadlineDate: String?

        enum CodingKeys: String, CodingKey {
            case owner, task, due, confidence
            case sourceQuote = "source_quote"
            case deadlineDate = "deadline_date"
        }

        init(owner: String, task: String, due: String?, sourceQuote: String? = nil, confidence: Double? = nil, deadlineDate: String? = nil) {
            self.owner = owner
            self.task = task
            self.due = due
            self.sourceQuote = sourceQuote
            self.confidence = confidence
            self.deadlineDate = deadlineDate
        }

        init(_ item: SummaryActionItem) {
            self.init(owner: item.owner, task: item.action, due: item.deadline, sourceQuote: item.sourceQuote, confidence: item.confidence,
                      deadlineDate: item.deadlineDate)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            owner = try container.decodeIfPresent(String.self, forKey: .owner) ?? "Unassigned"
            task = try container.decode(String.self, forKey: .task)
            due = try container.decodeIfPresent(String.self, forKey: .due)
            sourceQuote = try? container.decodeIfPresent(String.self, forKey: .sourceQuote)
            confidence = try? container.decodeIfPresent(Double.self, forKey: .confidence)
            deadlineDate = try? container.decodeIfPresent(String.self, forKey: .deadlineDate)
        }

        var structured: SummaryActionItem {
            SummaryActionItem(action: task, owner: owner, deadline: due, sourceQuote: sourceQuote, confidence: confidence, deadlineDate: deadlineDate)
        }
    }

    var summary: String
    var keyPoints: [String]
    var decisions: [String]
    var actionItems: [ActionItem]

    enum CodingKeys: String, CodingKey {
        case summary, decisions
        case keyPoints = "key_points"
        case actionItems = "action_items"
    }

    /// Action items go first so the model reads the transcript for tasks before it has written a summary that could
    /// crowd them out.
    static var schema: [String: Any] { [
        "type": "object",
        "properties": [
            "action_items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["owner": ["type": "string"], "task": ["type": "string"], "due": ["type": "string"],
                                   "deadline_date": ["type": "string"], "source_quote": ["type": "string"], "confidence": ["type": "number"]],
                    "required": ["owner", "task"],
                ],
            ],
            "decisions": ["type": "array", "items": ["type": "string"]],
            "key_points": ["type": "array", "items": ["type": "string"]],
            "summary": ["type": "string"],
        ],
        "required": ["action_items", "decisions", "key_points", "summary"],
    ] }

    static var schemaJSON: String { jsonString(schema) }
    static var notesSchemaJSON: String { jsonString(notesSchema) }
    /// The final call for a long meeting whose title is a generic fallback: also a short "title".
    static var notesSchemaWithTitleJSON: String {
        var schema = notesSchema
        var properties = schema["properties"] as? [String: Any] ?? [:]
        properties["title"] = ["type": "string"]
        schema["properties"] = properties
        schema["required"] = ["decisions", "key_points", "summary", "title"]
        return jsonString(schema)
    }

    /// The "title" field of a final-call reply, if it has one.
    static func title(in json: String) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: Data(Summarizer.tidy(json).utf8))) as? [String: Any]
        return object?["title"] as? String
    }

    static func jsonString(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    /// The final call for a long meeting: action items come from the parts, so they are left out.
    static var notesSchema: [String: Any] {
        var schema = Self.schema
        var properties = schema["properties"] as? [String: Any] ?? [:]
        properties["action_items"] = nil
        schema["properties"] = properties
        schema["required"] = ["decisions", "key_points", "summary"]
        return schema
    }

    init(summary: String, keyPoints: [String], decisions: [String], actionItems: [ActionItem]) {
        self.summary = summary
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(String.self, forKey: .summary)
        keyPoints = try container.decode([String].self, forKey: .keyPoints)
        decisions = try container.decode([String].self, forKey: .decisions)
        actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
    }

    /// Nil when the reply isn't usable, so the caller falls back to free text.
    static func decode(_ text: String) -> StructuredSummary? {
        guard let summary = try? JSONDecoder().decode(StructuredSummary.self, from: Data(Summarizer.tidy(text).utf8)),
              !summary.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return summary
    }

    var markdown: String { markdown(headings: SummaryHeadings(language: nil)) }

    func markdown(headings: SummaryHeadings) -> String {
        let clean = Self.clean, unbulleted = Self.unbulleted, isNone = Self.isNone
        func list(_ items: [String]) -> String {
            let kept = items.map(unbulleted).filter { !isNone($0) }
            return kept.isEmpty ? "- None recorded" : kept.map { "- \($0)" }.joined(separator: "\n")
        }
        // Small models sometimes write the whole Markdown summary, headings and all, into the summary field; the
        // sections after the first heading repeat the other fields, so keep only the prose before it.
        var prose = clean(summary).replacingOccurrences(of: #"(?i)^#{1,6}\s*(?:summary|podsumowanie)\b:?\s*"#, with: "", options: .regularExpression)
        if let heading = prose.range(of: #"(?:^|\s)#{1,6}\s"#, options: .regularExpression) {
            prose = String(prose[..<heading.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if prose.isEmpty {
            prose = keyPoints.map(unbulleted).filter { !isNone($0) }
                .map { $0.hasSuffix(".") || $0.hasSuffix("!") || $0.hasSuffix("?") ? $0 : $0 + "." }
                .joined(separator: " ")
        }
        return """
        ## \(headings.summary)
        \(prose)

        ## \(headings.keyPoints)
        \(list(keyPoints))

        ## \(headings.decisions)
        \(list(decisions))

        ## \(headings.actionItems)
        \(actionItemsMarkdown)
        """
    }

    /// The "## Action items" checklist, or "- None recorded".
    var actionItemsMarkdown: String {
        let clean = Self.clean, unbulleted = Self.unbulleted, isNone = Self.isNone
        let items = actionItems.filter { !isNone($0.task) }.map { item -> String in
            // "Speaker 2" stays, so naming that voice later renames the owner; "Others" names nobody.
            let owner = isNone(item.owner) || clean(item.owner).lowercased() == "others" ? "Unassigned" : unbulleted(item.owner)
            // "Gustavo: Gustavo: fix it": the model put the owner in the task as well.
            var task = Summarizer.droppingOwner(owner, from: unbulleted(item.task))
            let due = item.due.map(clean).flatMap { isNone($0) || Summarizer.isNoDueDate($0) ? nil : $0 }
            // Small models repeat the date in the task ("write notes by Thursday" + "Thursday").
            if let due, task.lowercased().hasSuffix(due.lowercased()) {
                task = String(task.dropLast(due.count)).trimmingCharacters(in: .whitespaces)
                for word in [" by", " on", " until", " before"] where task.lowercased().hasSuffix(word) {
                    task = String(task.dropLast(word.count))
                }
            }
            return "- [ ] \(owner): \(task)" + (due.map { " (\($0))" } ?? "")
        }
        return items.isEmpty ? "- None recorded" : items.joined(separator: "\n")
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Small models sometimes start list items with their own bullet ("- - point").
    static func unbulleted(_ text: String) -> String {
        clean(text).replacingOccurrences(of: #"^(?:(?:[-*•]|\d+[.)])(?: \[[ xX]\])?\s+)+"#, with: "", options: .regularExpression)
    }

    static func isNone(_ text: String) -> Bool {
        ["", "none", "none recorded", "n/a", "brak"].contains(clean(text).lowercased().trimmingCharacters(in: .punctuationCharacters))
    }

    /// Action items from the parts of a long meeting, each task once. A task repeated across parts (the same
    /// words, or one wording containing the other for the same owner) keeps the named owner, the longer wording
    /// and any due date.
    static func merged(_ items: [ActionItem]) -> [ActionItem] {
        func unnamed(_ owner: String) -> Bool {
            isNone(owner) || clean(owner).lowercased() == "unassigned" || Summarizer.isUnknownSpeaker(clean(owner))
        }
        func words(_ text: String) -> String {
            text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        func key(_ item: ActionItem) -> (owner: String, task: String) {
            (unnamed(item.owner) ? "" : words(item.owner), words(Summarizer.droppingOwner(item.owner, from: unbulleted(item.task))))
        }
        var result: [ActionItem] = []
        for item in items where !isNone(item.task) {
            let (owner, task) = key(item)
            let match = result.firstIndex { kept in
                let (keptOwner, keptTask) = key(kept)
                if keptTask == task { return owner.isEmpty || keptOwner.isEmpty || owner == keptOwner }
                let (shorter, longer) = keptTask.count < task.count ? (keptTask, task) : (task, keptTask)
                return owner == keptOwner && shorter.split(separator: " ").count >= 3 && longer.contains(shorter)
            }
            guard let match else { result.append(item); continue }
            var kept = result[match]
            if unnamed(kept.owner), !owner.isEmpty { kept.owner = item.owner }
            if task.count > key(kept).task.count { kept.task = item.task }
            if kept.due.map({ isNone($0) || Summarizer.isNoDueDate($0) }) ?? true, let due = item.due { kept.due = due }
            if kept.deadlineDate == nil { kept.deadlineDate = item.deadlineDate }
            result[match] = kept
        }
        return result
    }
}

/// What each part of a long meeting returns: notes for the final call, and tasks kept as data.
struct PartNotes: Decodable, Equatable {
    var topics: [String]
    var decisions: [String]
    var actionItems: [StructuredSummary.ActionItem]

    enum CodingKeys: String, CodingKey {
        case topics, decisions
        case actionItems = "action_items"
    }

    static var schema: [String: Any] { [
        "type": "object",
        "properties": [
            "action_items": (StructuredSummary.schema["properties"] as? [String: Any])?["action_items"] ?? [:],
            "decisions": ["type": "array", "items": ["type": "string"]],
            "topics": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["action_items", "decisions", "topics"],
    ] }

    static var schemaJSON: String { StructuredSummary.jsonString(schema) }

    static func decode(_ text: String) -> PartNotes? {
        try? JSONDecoder().decode(PartNotes.self, from: Data(Summarizer.tidy(text).utf8))
    }

    /// Notes written as plain lists ("Topics:", "Decisions:", "Action items:" with "- [ ] Owner: task (due)"),
    /// the reply `Prompts.partFreeTextSystem` asks for. Nil without an "Action items:" list, since then the
    /// part's tasks can't be told apart from the rest.
    static func parseFreeText(_ reply: String) -> PartNotes? {
        var sections: [String: [String]] = [:]
        var current: String?
        for raw in Summarizer.tidy(reply).components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let heading = line.replacingOccurrences(of: #"^(?:#+\s*|\*\*)|(?:\*\*)?:?(?:\*\*)?$"#, with: "", options: .regularExpression).lowercased()
            if ["topics", "decisions", "action items"].contains(heading) {
                current = heading
                sections[heading, default: []] = []
            } else if let current, !line.isEmpty {
                sections[current, default: []].append(line)
            }
        }
        guard let tasks = sections["action items"] else { return nil }
        func list(_ lines: [String]?) -> [String] {
            (lines ?? []).map(StructuredSummary.unbulleted).filter { !$0.isEmpty && !StructuredSummary.isNone($0) }
        }
        let items = ActionItem.parse(tasks.joined(separator: "\n")).compactMap { item -> StructuredSummary.ActionItem? in
            guard let match = item.text.firstMatch(of: /^([^:]{1,60}):\s+(.+?)(?:\s*\(([^()]*)\))?$/) else {
                return StructuredSummary.isNone(item.text) ? nil : StructuredSummary.ActionItem(owner: "Unassigned", task: item.text, due: nil)
            }
            let task = String(match.2)
            guard !StructuredSummary.isNone(task) else { return nil }
            return StructuredSummary.ActionItem(owner: String(match.1), task: task, due: match.3.map(String.init))
        }
        return PartNotes(topics: list(sections["topics"]), decisions: list(sections["decisions"]), actionItems: items)
    }

    /// The notes the final call reads; tasks are left out, since they are merged in code.
    var text: String {
        func list(_ items: [String]) -> String {
            let kept = items.map(StructuredSummary.unbulleted).filter { !StructuredSummary.isNone($0) }
            return kept.isEmpty ? "- none" : kept.map { "- \($0)" }.joined(separator: "\n")
        }
        return "Topics:\n\(list(topics))\nDecisions:\n\(list(decisions))"
    }
}

enum Prompts {
    static let speakerRule = """
    Speaker labels: "You" is the person who recorded this meeting; a label that is a name is that person. \
    "Speaker 1", "Speaker 2" and so on are distinct remote participants whose names are unknown, and "Others" \
    means one or more of them. \
    Owners: the owner of a task is the person who will do it, and you name them only when the transcript shows \
    who they are: the sentence names them ("<name> will..." -> <name>), or the speaker who says \
    "I will..." is "You" or has a name, either as their label or because someone addresses them by name. \
    When the speaker who says "I will..." is an unnamed "Speaker N", the owner is that label ("Speaker 2"). \
    Otherwise the owner is "Unassigned", and never use "Others" as an owner.
    """

    static func withGuidance(_ system: String, _ guidance: String?) -> String {
        guard let guidance, !guidance.isEmpty else { return system }
        return system + "\n\n" + guidance
    }

    static func languageName(_ language: String?) -> String? {
        language.flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0) }
    }

    /// For JSON replies: names the meeting's language when it is known, so small models don't drift into English.
    static func valuesLanguageRule(_ language: String?) -> String {
        languageName(language).map { "Write all values in \($0); never translate." }
            ?? "Write all values in the language most of the transcript is in; never translate."
    }

    static let actionItemsRule = """
    one entry per task with "owner", "task" (an imperative sentence that starts with a verb), "due" (only if a date \
    was said, in words as said; otherwise leave it out), "deadline_date" (that day as YYYY-MM-DD, counted from the \
    meeting's date in the transcript header; "jutro" is the next day, "do piątku" and "by Friday" are the first \
    Friday on or after the meeting's date; leave it out when no day was said or you cannot tell which), "source_quote" (the transcript words where the task was said) and "confidence" \
    (0 to 1, how sure you are someone committed to it). Decisions, open questions and statements of fact are not tasks. \
    Every sentence that names a person and something they will do is a task, in any tense \
    ("<name> will...", "<name> is fixing...", "I'll..."); these patterns are not tasks, so list only tasks said in the text. \
    The task says what will be done, without the owner's name. Empty list if there were none.
    """

    /// `actionItems: false` is the final call for a long meeting, whose tasks come from the parts.
    static func structuredSystem(language: String?, actionItems: Bool = true) -> String {
        let source = actionItems ? "transcripts" : "notes taken from consecutive parts of a meeting"
        return """
        You write concise, factual meeting notes from \(source). Use only information in the \(actionItems ? "transcript" : "notes"); \
        never invent names, numbers, dates or decisions. Reply with JSON only:
        - "summary": two to four sentences on what the meeting was about and its outcome.
        - "key_points": the important topics and facts discussed.
        - "decisions": what was decided, agreed or scheduled. Any sentence like "we agreed to...", \
        "we decided to...", "let's go with..." or "we'll ship it on..." is a decision; list it even if it is also a key point. \
        Empty list if nothing was decided.
        """ + (actionItems ? "\n- \"action_items\": " + actionItemsRule : "") + """

        \(speakerRule) \(valuesLanguageRule(language)) \
        If a line is unintelligible or repeats itself, ignore it. \(UntrustedText.promptRule)
        """
    }

    static func summarySystem(language: String?, actionItems: Bool = true) -> String {
        let count = actionItems ? "four" : "three"
        let languageRule = languageName(language).map { "Keep the \(count) headings exactly in English; write everything under them in \($0)." }
            ?? "Keep the \(count) headings exactly in English; write everything under them in the language most of the transcript is in."
        return summaryInstructions + (actionItems ? "\n\n" + actionItemsInstructions : "") + "\n\n" + """
        \(speakerRule) \(languageRule) \
        If a line is unintelligible or repeats itself, ignore it. \(UntrustedText.promptRule)
        """
    }

    static let summaryInstructions = """
    You write concise, factual meeting notes from transcripts. Use only information in the transcript; \
    never invent names, numbers, dates or decisions. \
    Output GitHub Markdown with exactly these sections:

    ## Summary
    Two to four sentences on what the meeting was about and its outcome.

    ## Key points
    Bullet list of the important topics and facts discussed.

    ## Decisions
    Bullet list of what was decided, agreed or scheduled. Any sentence like "we agreed to...", \
    "we decided to...", "let's go with..." or "we'll ship it on..." is a decision; list it here \
    even if it also appears in Key points. Write "- None recorded" only when nothing at all was decided.
    """

    static let actionItemsInstructions = """
    ## Action items
    Checklist lines in the form "- [ ] <owner>: <task> (<due date, only if one was said>)". List each task once. \
    Write "- None recorded" if there were none.
    """

    /// The material is fenced (`UntrustedText.fenced`) with a fresh suffix per message; tests pass a fixed `fence`.
    static func summaryUser(meeting: Meeting, material: String, isNotes: Bool, fence: String = UntrustedText.fenceSuffix()) -> String {
        let kind = isNotes ? "Notes taken from consecutive parts of the meeting" : "Transcript"
        let block = UntrustedText.fenced(material, tag: isNotes ? "notes" : "transcript", suffix: fence)
        return "\(header(meeting))\(typedNotes(meeting, fence: fence))\n\(kind):\n\(block)"
    }

    /// The user's own notes, trimmed; nil when there are none.
    static func userNotes(_ meeting: Meeting) -> String? {
        guard let notes = meeting.typedNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty else { return nil }
        return notes
    }

    static let userNotesRule = """
    The user typed their own notes during the meeting. Treat them as the outline: cover each of their points, \
    in their order and under their wording, and fill them in from the transcript (who, what, when). The \
    transcript decides the facts; when it contradicts a note, follow the transcript. A point the transcript \
    doesn't mention stays in the summary as the user wrote it, briefly. Topics the notes miss are added after \
    theirs.
    """

    /// The user's notes and how to use them, for the call that writes the summary; empty without notes.
    static func typedNotes(_ meeting: Meeting, fence: String) -> String {
        guard let notes = userNotes(meeting) else { return "" }
        return "\n\(userNotesRule)\nThe user's notes:\n" + UntrustedText.fenced(notes, tag: "user_notes", suffix: fence) + "\n"
    }

    /// Who is in the meeting, so owners can be named. Title and names are kept on their lines (`UntrustedText.inline`),
    /// so they can't add a line that looks like the start of the transcript or an instruction.
    static func header(_ meeting: Meeting) -> String {
        var header = "Meeting: \(UntrustedText.inline(meeting.title)) (\(meeting.platform.displayName))\n"
        header += ActionItemDates.headerLine(meeting.startedAt)
        if !meeting.attendees.isEmpty {
            header += "Attendees: \(meeting.attendees.map { UntrustedText.inline($0, limit: 100) }.joined(separator: ", "))\n"
        }
        if let selfName = meeting.selfName {
            header += "\"You\" in the transcript is \(UntrustedText.inline(selfName, limit: 100)).\n"
        } else {
            header += "\"You\" is the person who recorded these notes.\n"
        }
        return header
    }

    static func partSystem(language: String?) -> String {
        """
        You take notes from one part of a longer meeting transcript. Use only what is in this part; \
        never invent names, numbers, dates or tasks. Reply with JSON only:
        - "topics": the important topics and facts discussed in this part.
        - "decisions": what was decided, agreed or scheduled in this part. Empty list if nothing was decided.
        - "action_items": \(actionItemsRule)
        \(speakerRule) \(valuesLanguageRule(language)) \
        If a line is unintelligible or repeats itself, ignore it. \(UntrustedText.promptRule)
        """
    }

    /// The second try for a part whose JSON reply was unusable: the same notes as plain lists.
    static func partFreeTextSystem(language: String?) -> String {
        """
        You take notes from one part of a longer meeting transcript. Use only what is in this part; \
        never invent names, numbers, dates or tasks. Reply with exactly three plain lists and nothing else:
        Topics:
        - the important topics and facts discussed in this part
        Decisions:
        - what was decided, agreed or scheduled ("- none" if nothing)
        Action items:
        - [ ] Owner: task (due date, only when one was said)
        Write "- none" under Action items when nobody committed to anything. \(speakerRule) \(valuesLanguageRule(language)) \
        If a line is unintelligible or repeats itself, ignore it. \(UntrustedText.promptRule)
        """
    }

    static func partUser(_ chunk: String, meeting: Meeting, part: Int, of total: Int, fence: String = UntrustedText.fenceSuffix()) -> String {
        "\(header(meeting))\nPart \(part) of \(total) of the transcript:\n" + UntrustedText.fenced(chunk, tag: "transcript", suffix: fence)
    }

    static func condenseSystem(language: String?) -> String {
        let name = languageName(language).map { "in \($0)" } ?? "in the language of the notes"
        return """
        Shorten these meeting notes. Output exactly two lists, "Topics:" and "Decisions:", \
        each line starting with "- "; write "- none" for an empty list. No prose. \
        Keep every decision; use only what is in the notes. Write \(name); never translate. \(UntrustedText.promptRule)
        """
    }

    static func notesUser(_ notes: String, fence: String = UntrustedText.fenceSuffix()) -> String {
        "Notes from a long meeting:\n" + UntrustedText.fenced(notes, tag: "notes", suffix: fence)
    }
}
