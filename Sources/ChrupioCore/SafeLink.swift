import Foundation

/// Links from meeting data (summaries, notes, the meeting's own URL) that the app will open: http and https with a host.
/// Anything else (file:, javascript:, data:, x-apple…, app schemes) is refused and shows as plain text.
public enum SafeLink {
    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        // `https://google.com@evil.com` opens evil.com: a user or password in a link is only ever there to mislead.
        guard url.user == nil, url.password == nil else { return false }
        return !(url.host ?? "").isEmpty
    }

    public static func url(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)), isAllowed(url) else { return nil }
        return url
    }

    /// Markdown text with only safe links left: other schemes become plain text, and so does a link whose whole
    /// visible text is itself an address (see `spoofs`) naming a different host, like `[https://bank.com](https://evil.com)`.
    /// Only the link text as a whole is judged: an address inside a sentence (`[Go to github.com](…)`) isn't checked,
    /// and a bare name with an unlisted ending (`[bank.local](…)`) counts as text and keeps its link.
    public static func sanitized(_ text: AttributedString) -> AttributedString {
        var result = text
        // Grouped by link only, so `[**bank**.com](…)` is judged on its whole text, not run by run.
        for (link, range) in text.runs[\.link] {
            guard let link else { continue }
            if !isAllowed(link) || spoofs(visible: String(text[range].characters), target: link) {
                result[range].link = nil
            }
        }
        return result
    }

    /// True when `visible` reads as an address whose host isn't `target`'s host. After `normalized`, the text is an
    /// address when it contains `://`, starts with `www.`, or is dot-separated labels with a port or path
    /// (`example.com/x`, `bank.com:443`). A bare name (`bank.com`) is an address only when its ending is in
    /// `addressEndings` and not in `fileExtensions`, so `Node.js`, `README.md` and `design.pdf` keep their links.
    static func spoofs(visible: String, target: URL) -> Bool {
        let shown = normalized(visible)
        let candidate: String
        if shown.contains("://") {
            candidate = shown
        } else if looksLikeAddress(shown) {
            candidate = "http://" + shown
        } else {
            return false
        }
        // It looks like an address: keep the link only if both name the same host.
        guard let shownHost = URL(string: candidate)?.host, let targetHost = target.host else { return true }
        return bareHost(shownHost) != bareHost(targetHost)
    }

    /// Drops invisible format characters (zero-width space, joiners, BOM), reads ideographic and full-width full stops
    /// as `.`, and trims surrounding spaces, `<>` and punctuation, so `(bank。com).` compares as `bank.com`.
    static func normalized(_ visible: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in visible.unicodeScalars where scalar.properties.generalCategory != .format {
            switch scalar {
            case "\u{3002}", "\u{FF0E}", "\u{FF61}": scalars.append(".")
            default: scalars.append(scalar)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines.union(surroundingPunctuation))
    }

    private static let surroundingPunctuation = CharacterSet(charactersIn: "<>.,;:!?()[]{}\"'\u{201C}\u{201D}\u{2018}\u{2019}")

    private static func looksLikeAddress(_ shown: String) -> Bool {
        guard let match = shown.wholeMatch(of: domainPattern) else { return false }
        if shown.lowercased().hasPrefix("www.") || match.output.port != nil || match.output.rest != nil { return true }
        let ending = match.output.ending.lowercased()
        return addressEndings.contains(ending) && !fileExtensions.contains(ending)
    }

    /// Dot-separated labels ending in a letters-only top-level domain, then an optional port and path.
    nonisolated(unsafe) private static let domainPattern =
        /(?i)[\p{L}\p{N}-]+(?:\.[\p{L}\p{N}-]+)*\.(?<ending>\p{L}{2,})(?<port>:\d+)?(?<rest>[\/?#].*)?/

    /// Common top-level domains that make a bare name read as an address.
    static let addressEndings: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "co", "pl", "de", "uk", "ai", "gov", "edu", "eu", "us", "fr", "it", "es",
        "nl", "ch", "at", "be", "se", "no", "dk", "fi", "cz", "ca", "au", "jp", "cn", "in", "br", "ru", "ua", "me", "tv",
        "info", "biz", "xyz", "online", "site", "tech", "cloud", "google", "microsoft", "apple",
    ]

    /// File extensions people put in link text; a bare name ending in one of these is never read as an address.
    static let fileExtensions: Set<String> = [
        "md", "js", "pdf", "txt", "png", "jpg", "jpeg", "gif", "json", "swift", "py", "ts", "html", "csv", "doc", "docx",
        "xls", "xlsx", "ppt", "pptx", "key", "zip", "mov", "mp4", "sh", "rs", "rb", "go", "yml", "yaml",
    ]

    private static func bareHost(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }
}
