import Foundation

/// How a summary is written for a kind of meeting: extra guidance for the prompt and the heading of the per-person
/// section. Picked by hand in the meeting window, or from the title by a few plain keyword rules.
public enum SummaryTemplate: String, Codable, Sendable, CaseIterable, Identifiable {
    case standard = "default"
    case standup
    case oneOnOne = "one-on-one"
    case clientCall = "client-call"
    case interview

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: "Default"
        case .standup: "Standup"
        case .oneOnOne: "1:1"
        case .clientCall: "Client call"
        case .interview: "Interview"
        }
    }

    /// The template saved on the meeting, or one picked from its title.
    public static func resolved(for meeting: Meeting) -> SummaryTemplate {
        meeting.summaryTemplate.flatMap(SummaryTemplate.init(rawValue:)) ?? auto(title: meeting.title)
    }

    /// Conservative on purpose: only titles that say what the meeting is ("Daily standup", "1:1 Anna", "Interview
    /// – backend") pick a template; everything else, huddles and client names included, gets the default.
    public static func auto(title: String) -> SummaryTemplate {
        let lower = title.lowercased()
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        if has(#"\b(?:stand-?up|daily|daily scrum)\b"#) { return .standup }
        if has(#"(?:^|[^\d])1\s*(?::|on|-on-)\s*1(?:$|[^\d])|\bone[- ]on[- ]one\b"#) { return .oneOnOne }
        if has(#"\b(?:interview|rozmowa rekrutacyjna|rekrutacja)\b"#) { return .interview }
        return .standard
    }

    /// Added to the system prompt after the fixed rules; nil for the default, which is the prompt as it is.
    public var guidance: String? {
        switch self {
        case .standard:
            nil
        case .standup:
            """
            This meeting is a standup. Keep "tldr" to one or two sentences about the team's overall state. In "people", \
            give every person who reported an entry, even a short one: yesterday/today work as "status", anything \
            stopping them as "blockers". Decisions are rare in a standup; list only explicit ones.
            """
        case .oneOnOne:
            """
            This meeting is a one-on-one between two people. In "people", one entry per person with the topics \
            they raised (feedback, growth, concerns, plans) as "status" and their concerns as "blockers". \
            Report personal topics briefly and neutrally. "decisions" holds what the two agreed.
            """
        case .clientCall:
            """
            This meeting is a call with a client. In "tldr", say what the client wanted and where things stand. \
            In "people", put the client's side first: their requests, questions and concerns as "status", their \
            objections or risks as "blockers". "decisions" holds what was agreed with the client (scope, dates, \
            prices). Action items are commitments made to the client or by the client.
            """
        case .interview:
            """
            This meeting is a job interview. In "tldr", name the role if said and the overall impression without \
            judging the candidate yourself. In "people", one entry for the candidate with their experience, \
            answers and questions as "status", and one per interviewer only if they said something substantive. \
            "decisions" holds only next steps in the process that were agreed (another round, a task, a date).
            """
        }
    }
}

/// The headings of a summary in the meeting's language, so a Polish summary is Polish throughout.
public struct SummaryHeadings: Equatable, Sendable {
    public var summary = "Summary"
    public var people = "By person"
    public var keyPoints = "Key points"
    public var decisions = "Decisions"
    public var actionItems = "Action items"
    public var blocker = "Blocker"
    public var next = "Next"

    public init(language: String?, template: SummaryTemplate = .standard) {
        let polish = language == "pl"
        if polish {
            summary = "Podsumowanie"; people = "Kto co robi"; keyPoints = "Najważniejsze punkty"
            decisions = "Decyzje"; actionItems = "Zadania"; blocker = "Bloker"; next = "Dalej"
        }
        switch template {
        case .standard: break
        case .standup: people = polish ? "Aktualizacje" : "Updates"
        case .oneOnOne: people = polish ? "Tematy" : "Topics"
        case .clientCall: people = polish ? "Kto co mówił" : "Who said what"
        case .interview: people = polish ? "Rozmówcy" : "Participants"
        }
    }

    /// Every spelling of the action items heading, for code that finds the checklist in a saved summary.
    public static let actionItemsPattern = #"^## (?:Action items|Zadania)\b"#
}
