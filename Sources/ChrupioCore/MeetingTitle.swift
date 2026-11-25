import Foundation

/// Titles for meetings the recorder could only name after the app ("Browser call", "Zoom"): the summary suggests
/// one, and the named voices of the transcript become the attendees.
public enum MeetingTitle {
    /// Fallback titles the app gives when the call reported none (`KnownMeetingApp`, `ZoomMonitor`, orphan
    /// recovery and the platform names).
    static let generic: Set<String> = ["browser call", "zoom", "zoom meeting", "microsoft teams", "slack huddle", "google meet", "meeting"]

    /// True for a title the app made up, which the user hasn't replaced.
    public static func isGeneric(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty || generic.contains(trimmed) || trimmed.hasPrefix("recovered recording")
    }

    /// The model's title as one short line: quotes, a trailing full stop and Markdown removed; nil when nothing
    /// usable is left or it's another placeholder.
    public static func cleaned(_ raw: String) -> String? {
        var title = raw.components(separatedBy: .newlines).first ?? ""
        title = title.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'“”„`#*.")))
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !title.isEmpty, !isGeneric(title), !StructuredSummary.isNone(title) else { return nil }
        return title.count > 80 ? String(title.prefix(80)).trimmingCharacters(in: .whitespaces) : title
    }
}

extension Meeting {
    /// Takes the summary's suggested title while the meeting still has a generic one; a title the user (or Claude
    /// Code) typed is never replaced.
    public mutating func adoptSuggestedTitle(_ suggested: String?) {
        guard MeetingTitle.isGeneric(title), let suggested = suggested.flatMap(MeetingTitle.cleaned) else { return }
        title = suggested
    }

    /// Gives a meeting nobody was reported in the people its transcript names: remote voices with a name, not
    /// "Speaker N" or "Others", cleaned like reported names (`mergeAttendees`). The user stays out.
    public mutating func fillAttendeesFromSpeakers() {
        guard attendees.isEmpty else { return }
        var names: [String] = []
        for segment in segments {
            guard case .remote(let name?) = segment.speaker, !Meeting.isUnnamedSpeaker(name), !names.contains(name) else { continue }
            names.append(name)
        }
        mergeAttendees(names)
    }
}

/// The text a follow-up draft is written from.
enum FollowUp {
    /// `fence`: the random tag suffix for this message (tests pass a fixed one).
    static func input(for meeting: Meeting, fence: String = UntrustedText.fenceSuffix()) -> String {
        var text = "Meeting: \(UntrustedText.inline(meeting.title))\n"
        if !meeting.attendees.isEmpty { text += "Attendees: \(meeting.attendees.map { UntrustedText.inline($0, limit: 100) }.joined(separator: ", "))\n" }
        if let summary = meeting.summary?.markdown, !summary.isEmpty {
            text += "\n" + UntrustedText.fenced(summary, tag: "notes", suffix: fence) + "\n"
        } else {
            // No summary yet: the transcript, cut to a size one call reads quickly.
            text += "\n" + UntrustedText.fenced(String(TranscriptFormatter.plainText(meeting.segments).prefix(60_000)), tag: "transcript", suffix: fence) + "\n"
        }
        return text + "\nWrite the follow-up message."
    }
}
