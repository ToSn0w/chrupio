import Foundation

/// How chrupio-mcp names a meeting as an MCP resource, and how Claude Code mentions it.
/// Claude Code's syntax is `@server:protocol://resource/path`
/// (https://code.claude.com/docs/en/mcp, "Reference MCP resources").
public enum MeetingResource {
    public static let meetingsPrefix = "chrupio://meetings/"
    static let transcriptSuffix = "/transcript"

    /// Summary, metadata and notes, without the transcript.
    public static func uri(for id: UUID) -> String { meetingsPrefix + id.uuidString }

    /// The meeting with its transcript.
    public static func transcriptURI(for id: UUID) -> String { uri(for: id) + transcriptSuffix }

    /// What to type in Claude Code to attach the meeting.
    public static func mention(for id: UUID) -> String { "@\(ClaudeCodeSetup.serverName):\(uri(for: id))" }

    /// The meeting key (full id, 8+ character prefix or "latest") and whether the transcript was asked for;
    /// nil for any other URI. The key is only matched against loaded meeting ids, never used as a path.
    public static func parse(_ uri: String) -> (key: String, transcript: Bool)? {
        guard uri.hasPrefix(meetingsPrefix) else { return nil }
        var rest = String(uri.dropFirst(meetingsPrefix.count))
        let transcript = rest.hasSuffix(transcriptSuffix)
        if transcript { rest.removeLast(transcriptSuffix.count) }
        guard !rest.isEmpty, !rest.contains("/") else { return nil }
        return (rest, transcript)
    }
}
