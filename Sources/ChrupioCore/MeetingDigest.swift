import Foundation

/// The short recap the SessionStart hook injects into every Claude Code session.
public enum MeetingDigest {
    public static let maxCharacters = 4_000

    /// How far back meetings that mention the session's project are looked for.
    public static let projectDays = 30

    /// Recent finished meetings and their open action items, or "" when there were none.
    /// With a project, meetings from the last `projectDays` days that mention it come first.
    public static func text(_ meetings: [Meeting], now: Date = Date(), days: Int = 7, maxLines: Int = 40,
                            project: ProjectContext? = nil) -> String {
        text(entries: meetings.map { MeetingIndex.Entry($0, modified: .distantPast) }, now: now, days: days, maxLines: maxLines, project: project)
    }

    /// The same from index.json entries, which carry the parsed action items and project terms.
    public static func text(entries: [MeetingIndex.Entry], now: Date = Date(), days: Int = 7, maxLines: Int = 40,
                            project: ProjectContext? = nil) -> String {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let finished = entries.filter { $0.status != .recording && $0.status != .transcribing }.sorted { $0.startedAt > $1.startedAt }
        let recent = finished.filter { $0.startedAt >= since }
        let projectSince = now.addingTimeInterval(-Double(projectDays) * 86_400)
        let related = project.map { project in finished.filter { $0.startedAt >= projectSince && project.matches($0) } } ?? []
        guard !recent.isEmpty || !related.isEmpty else { return "" }

        var lines = ["Chrupio: \(recent.count) meeting(s) in the last \(days) days. Use the chrupio MCP tools "
            + "(get_meeting, search_meetings, list_action_items) for summaries and transcripts.", UntrustedText.notice, ""]
        if let project, !related.isEmpty {
            lines += ["Meetings that mention \(project.name) (last \(projectDays) days):"]
                + related.prefix(5).map { meetingLine($0.meeting) }
                + (related.count > 5 ? ["- … \(related.count - 5) more (search_meetings \"\(project.name)\")"] : [])
                + [""]
        }
        var meetingLines = recent.map { meetingLine($0.meeting) }
        var items = recent.flatMap { entry in
            entry.openItems.map { "- [ ] \(UntrustedText.inline($0.text)) (\(UntrustedText.quoted(entry.title)), \(MCPServer.day(entry.startedAt)), item \($0.number))" }
        }

        // Share the line budget, meetings first.
        let budget = maxLines - lines.count - 1 - (items.isEmpty ? 0 : 2)
        let meetingBudget = max(2, items.isEmpty ? budget : max(budget / 2, budget - items.count))
        if meetingLines.count > meetingBudget {
            let hidden = meetingLines.count - (meetingBudget - 1)
            meetingLines = Array(meetingLines.prefix(meetingBudget - 1)) + ["- … \(hidden) more (list_meetings)"]
        }
        if !meetingLines.isEmpty { lines += ["Recent meetings:"] + meetingLines }
        if !items.isEmpty {
            let itemBudget = max(1, budget - meetingLines.count)
            if items.count > itemBudget {
                let hidden = items.count - (itemBudget - 1)
                items = Array(items.prefix(itemBudget - 1)) + ["- … \(hidden) more (list_action_items)"]
            }
            lines += ["", "Open action items:"] + items
        }

        var text = lines.joined(separator: "\n")
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters - 40)) + "\n… (truncated; use the chrupio tools)"
        }
        return text
    }

    static func meetingLine(_ meeting: Meeting) -> String {
        let platform = meeting.platform.displayName == meeting.title ? "" : meeting.platform.displayName + ", "
        var line = "- \(MCPServer.day(meeting.startedAt, time: true)) \(UntrustedText.quoted(meeting.title)) (\(platform)"
            + "\(TranscriptFormatter.durationText(meeting.duration)))"
        if !meeting.attendees.isEmpty {
            let names = meeting.attendees.prefix(5).map { UntrustedText.inline($0, limit: 60) }.joined(separator: ", ")
            line += " with \(names)" + (meeting.attendees.count > 5 ? " +\(meeting.attendees.count - 5)" : "")
        }
        line += " id \(MeetingExporter.shortID(meeting.id))"
        if meeting.summary == nil { line += ", no summary" }
        return line
    }
}
