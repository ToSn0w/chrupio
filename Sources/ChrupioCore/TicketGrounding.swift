import Foundation

/// Finds ticket keys a summary mentions that nobody said: the model may have taken them from the project context.
public enum TicketGrounding {
    /// Keys in `markdown` whose number does not appear in `transcript`, in order, once each. Digits spoken in groups
    /// ("24 19", "2,366") are joined, but only within a line; a number counts only as a whole run of digits, so
    /// "PRJ-123" is not grounded by "4123"; the "[00:12:34]" line timestamps are ignored.
    public static func ungrounded(in markdown: String, transcript: String, prefix rawPrefix: String?) -> [String] {
        guard let prefix = rawPrefix.flatMap(MeetingContext.normalizedTicketPrefix),
              let keyPattern = try? Regex(#"\b"# + NSRegularExpression.escapedPattern(for: prefix) + #"-(\d{2,5})\b"#) else { return [] }
        let withoutTimestamps = transcript.replacing(/\[\d+:\d+(?::\d+)?\]/, with: " ")
        var joined = withoutTimestamps
        while true {
            let next = joined.replacingOccurrences(of: #"(\d)[ \t,.]+(\d)"#, with: "$1$2", options: .regularExpression)
            if next == joined { break }
            joined = next
        }
        let spoken = Set(joined.matches(of: /\d+/).map { String($0.0) })
        var result: [String] = []
        for match in markdown.matches(of: keyPattern) {
            let key = String(markdown[match.range])
            guard let digits = match.output[1].substring.map(String.init) else { continue }
            if !spoken.contains(digits), !result.contains(key) { result.append(key) }
        }
        return result
    }

    public static func warning(for keys: [String]) -> String? {
        keys.isEmpty ? nil : "Ticket keys not heard in the transcript: " + keys.joined(separator: ", ")
    }
}
