import Foundation

/// Decides which vocabulary replacements Parakeet's CTC rescoring may apply. The rescorer reports no position and
/// `ParakeetOutput.applying` replaces every occurrence in the chunk, so a wrong short term ("nad" > "NADA") spreads.
public enum BoostingGuard {
    /// Terms with fewer letters and digits than this are inserted only for a listed alias.
    public static let minimumTermLetters = 5
    /// How alike the heard word and the term must be (1 minus edit distance over the longer length).
    public static let minimumSimilarity = 0.6

    /// Lowercased, without accents, punctuation or spaces.
    public static func key(_ text: String) -> String {
        String(PersonName.key(text).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Alias lists keyed by the folded term, so a term written "jira" or " Jira" in the corrections still finds its aliases.
    /// Lists of terms that fold to the same key are merged.
    public static func aliasIndex(_ aliases: [String: [String]]) -> [String: [String]] {
        aliases.reduce(into: [:]) { index, entry in index[key(entry.key), default: []] += entry.value }
    }

    /// - Parameter aliases: the misheard forms listed for `replacement` (see `aliasIndex`).
    public static func accepts(original: String, replacement: String, aliases: [String]) -> Bool {
        let heard = key(original), term = key(replacement)
        guard !heard.isEmpty, !term.isEmpty else { return false }
        if aliases.contains(where: { key($0) == heard }) { return true }
        guard term.count >= minimumTermLetters else { return false }
        let longest = max(heard.count, term.count)
        return 1 - Double(ActionItemRules.editDistance(heard, term)) / Double(longest) >= minimumSimilarity
    }
}
