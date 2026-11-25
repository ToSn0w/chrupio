import Foundation

/// The recognizer that turns a chunk into text.
public enum SpeechEngine: String, Sendable, Equatable {
    /// whisper.cpp: detects the language, takes the names prompt; used for every chunk not in Polish.
    case whisper
    /// Parakeet TDT v3 (FluidAudio, CoreML): more accurate on Polish, but no prompt and no language detection.
    case parakeet
}

/// Picks the engine for each chunk on its own, so a mixed call gets Parakeet only for its Polish parts. Whisper
/// transcribes every chunk first and detects its language (the meeting's language so far only steers a doubtful guess,
/// see `Transcriber.fallbackLanguage`); a chunk it hears as Polish is then redone on Parakeet.
public struct EngineRouting: Sendable, Equatable {
    /// Languages Parakeet transcribes instead of whisper.
    public static let parakeetLanguages: Set<String> = ["pl"]

    public let parakeetEnabled: Bool
    /// The language chosen in Settings; nil when each chunk's language is detected.
    public let language: String?

    /// - Parameter language: the language chosen in Settings; "auto" or empty means detect it.
    public init(parakeetEnabled: Bool, language: String? = nil) {
        self.parakeetEnabled = parakeetEnabled
        self.language = language.flatMap { $0.isEmpty || $0 == "auto" ? nil : $0 }
    }

    /// The engine a chunk goes to first: Parakeet only when Settings say every chunk is Polish, else whisper.
    public var engine: SpeechEngine { parakeetLanguage(for: language) == nil ? .whisper : .parakeet }

    /// The routing once the meeting's language is confirmed: a Parakeet language sends later chunks straight to
    /// Parakeet, skipping whisper's pass. A language chosen in Settings is never overridden.
    public func pinned(toConfirmed confirmed: String?) -> EngineRouting {
        guard language == nil, parakeetEnabled, let confirmed, Self.parakeetLanguages.contains(confirmed) else { return self }
        return EngineRouting(parakeetEnabled: true, language: confirmed)
    }

    /// The language to redo a whisper chunk in on Parakeet, nil to keep whisper's lines. A chunk with no speech
    /// isn't redone: whisper's language guess on silence means nothing.
    public func parakeetLanguage(after whisper: Transcription) -> String? {
        whisper.speech.isEmpty ? nil : parakeetLanguage(for: whisper.language)
    }

    private func parakeetLanguage(for language: String?) -> String? {
        guard parakeetEnabled, let language, Self.parakeetLanguages.contains(language) else { return nil }
        return language
    }
}

/// Names and terms for Parakeet's vocabulary boosting: the same list whisper's prompt gets (attendees, known people,
/// Settings vocabulary, project-context terms). The coordinator sets them on the `Transcriber` right before each
/// chunk, and chunks are transcribed one at a time, so the latest list belongs to the chunk being transcribed.
public enum SpeechVocabulary {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var terms: [String] = []

    public static var current: [String] { lock.withLock { terms } }

    static func publish(_ items: [String]) {
        let cleaned = boostTerms(items)
        lock.withLock { terms = cleaned }
    }

    /// Trimmed, deduplicated ignoring case, and at least 3 characters (FluidAudio skips shorter terms as false-positive prone).
    public static func boostTerms(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 && seen.insert($0.lowercased()).inserted }
    }
}

/// Turns Parakeet's token timings into the same shape as whisper output.
public enum ParakeetOutput {
    /// Words split at sentence ends and at pauses this long, so lines come out about as long as whisper's.
    static let pause: TimeInterval = 1.0

    /// One `RecognizedSpeech` per sentence; times are seconds from the start of the file.
    /// A token starting with a space (or SentencePiece's "▁") starts a word, others continue it.
    public static func speech(tokens: [(text: String, start: TimeInterval, end: TimeInterval)]) -> [RecognizedSpeech] {
        var words: [TimedWord] = []
        for token in tokens {
            let text = token.text.replacingOccurrences(of: "▁", with: " ")
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            // Control tokens (<unk>, <|endoftext|>) are never speech.
            guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { continue }
            if text.hasPrefix(" ") || words.isEmpty {
                words.append(TimedWord(start: token.start, end: max(token.start, token.end), text: trimmed))
            } else {
                words[words.count - 1].text += trimmed
                words[words.count - 1].end = max(words[words.count - 1].end, token.end)
            }
        }

        var sentences: [[TimedWord]] = []
        var current: [TimedWord] = []
        for (index, word) in words.enumerated() {
            current.append(word)
            let next = index + 1 < words.count ? words[index + 1] : nil
            let endsSentence = word.text.last.map { ".?!…".contains($0) } ?? false
            if next == nil || endsSentence || next!.start - word.end >= pause {
                sentences.append(current)
                current = []
            }
        }

        return sentences.compactMap { words in
            let text = Transcriber.cleanText(words.map(\.text).joined(separator: " "))
            guard !text.isEmpty, let first = words.first, let last = words.last else { return nil }
            return RecognizedSpeech(start: first.start, end: last.end, text: text, words: words)
        }
    }

    /// Applies vocabulary corrections (spoken form → term) to recognized lines, keeping word times. A multi-word
    /// original becomes one word spanning its times; the last word's trailing punctuation stays.
    public static func applying(replacements: [(original: String, replacement: String)], to speech: [RecognizedSpeech]) -> [RecognizedSpeech] {
        let key = { (text: String) in text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }
        return speech.map { line in
            var words = line.words
            for (original, replacement) in replacements {
                let target = original.split(separator: " ").map { key(String($0)) }.filter { !$0.isEmpty }
                guard !target.isEmpty, !replacement.isEmpty else { continue }
                var index = 0
                while index + target.count <= words.count {
                    let span = words[index..<index + target.count]
                    guard span.map({ key($0.text) }) == target else { index += 1; continue }
                    let last = span.last!.text
                    let trailing = String(last.reversed().prefix { $0.isPunctuation }.reversed())
                    let merged = TimedWord(start: span.first!.start, end: span.last!.end, text: replacement + trailing)
                    words.replaceSubrange(index..<index + target.count, with: [merged])
                    index += 1
                }
            }
            guard words != line.words else { return line }
            var fixed = line
            fixed.words = words
            fixed.text = Transcriber.cleanText(words.map(\.text).joined(separator: " "))
            return fixed
        }
    }
}
