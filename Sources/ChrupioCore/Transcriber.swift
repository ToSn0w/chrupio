import Foundation

public enum TranscriberError: LocalizedError {
    case whisperNotFound
    case modelNotFound(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .whisperNotFound: "whisper-cli is missing from Chrupio.app. Reinstall Chrupio from the latest release."
        case .modelNotFound(let name): "Whisper model \(name) is not downloaded. Open Settings → Transcription."
        case .failed(let message): "Transcription failed: \(message)"
        }
    }
}

/// A piece of recognized speech, with times relative to the start of the transcribed file.
public struct RecognizedSpeech: Sendable, Hashable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// Word times, seconds from the start of the file.
    public var words: [TimedWord] = []
}

public struct WhisperModel: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let sizeDescription: String

    public static let all: [WhisperModel] = [
        WhisperModel(name: "base", sizeDescription: "148 MB, fast, lower accuracy"),
        WhisperModel(name: "small", sizeDescription: "488 MB, recommended"),
        WhisperModel(name: "medium", sizeDescription: "1.5 GB, accurate, slow"),
        WhisperModel(name: "large-v3-turbo-q5_0", sizeDescription: "574 MB, best for Polish, slower than small"),
        WhisperModel(name: "base.en", sizeDescription: "148 MB, English only"),
        WhisperModel(name: "small.en", sizeDescription: "488 MB, English only"),
    ]

    public var fileName: String { "ggml-\(name).bin" }
    public var localURL: URL { AppPaths.models.appendingPathComponent(fileName) }
    /// The whisper.cpp model repository commit the files and pins below come from.
    public static let revision = "5359861c739e955e79d9a303bcbc70fb988958b1"

    /// Sizes and SHA-256 from Hugging Face's LFS metadata for `revision` (scripts/install.sh repeats the small one).
    static let pins: [String: PinnedFile] = [
        "base": PinnedFile(bytes: 147_951_465, sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
        "base.en": PinnedFile(bytes: 147_964_211, sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"),
        "small": PinnedFile(bytes: 487_601_967, sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        "small.en": PinnedFile(bytes: 487_614_201, sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"),
        "medium": PinnedFile(bytes: 1_533_763_059, sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"),
        "large-v3-turbo-q5_0": PinnedFile(bytes: 574_041_195, sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
    ]

    public var pin: PinnedFile { Self.pins[name]! }
    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(Self.revision)/\(fileName)")!
    }
    /// In place and the pinned size (the hash was checked when it was downloaded).
    public var isDownloaded: Bool { ModelVerifier.hasExpectedSize(localURL, pin) }
    public var isEnglishOnly: Bool { name.hasSuffix(".en") }
}

/// Silero voice-activity model for whisper.cpp. With it whisper only sees real speech, so listening time
/// doesn't turn into invented sentences and segment times line up with the audio.
public enum VADModel {
    public static let fileName = "ggml-silero-v5.1.2.bin"
    public static var localURL: URL { AppPaths.models.appendingPathComponent(fileName) }
    /// The whisper-vad repository commit; size and SHA-256 from Hugging Face's LFS metadata for it.
    public static let revision = "9ffd54a1e1ee413ddf265af9913beaf518d1639b"
    public static let pin = PinnedFile(bytes: 885_098, sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf")
    public static let downloadURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/\(revision)/ggml-silero-v5.1.2.bin")!
    public static var isDownloaded: Bool { ModelVerifier.hasExpectedSize(localURL, pin) }

    /// Downloads the model (under 1 MB) if it's missing. Transcription works without it, just less cleanly.
    public static func ensureDownloaded() async throws {
        guard !isDownloaded else { return }
        let (location, response) = try await URLSession.shared.download(from: downloadURL)
        defer { try? FileManager.default.removeItem(at: location) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TranscriberError.failed("VAD model download returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        try ModelVerifier.install(location, to: localURL, pin: pin)
    }
}

/// Recognized speech from one file, plus the language whisper detected (or was told).
public struct Transcription: Sendable, Hashable {
    public var speech: [RecognizedSpeech]
    public var language: String?

    public init(speech: [RecognizedSpeech], language: String?) {
        self.speech = speech
        self.language = language
    }
}

/// Runs whisper.cpp on WAV files: through `WhisperServer` when it is up, else `whisper-cli`.
public struct Transcriber: Sendable {
    public var model: WhisperModel
    /// ISO language code or "auto".
    public var language: String
    /// Names to bias spelling toward (meeting attendees). Only used with VAD, because a prompt on silent audio leaks into the text.
    /// Setting it (or `terms`) also hands the list to Parakeet's vocabulary boosting (`SpeechVocabulary`).
    public var vocabulary: [String] { didSet { SpeechVocabulary.publish(terms + vocabulary) } }
    /// The user's own words to bias spelling toward (team names, product terms), from Settings.
    public var terms: [String] { didSet { SpeechVocabulary.publish(terms + vocabulary) } }
    /// With "auto": the user's usual language. On short or noisy Polish chunks whisper often guesses a related
    /// language (Russian, Czech, Slovak); such a chunk is redone in this one (see `fallbackLanguage`).
    public var preferredLanguage: String?
    /// The language most of this meeting has been in so far (`LanguageVote.confirmed` or `majority`), if known.
    public var meetingLanguage: String?
    /// The end of what was said just before on the same track, so a sentence cut by the chunk boundary reads on.
    public var previousText: String?
    public var threads: Int

    public init(
        model: WhisperModel, language: String = "auto", preferredLanguage: String? = nil, vocabulary: [String] = [], terms: [String] = [],
        threads: Int = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    ) {
        self.model = model
        self.language = language
        self.preferredLanguage = preferredLanguage.flatMap { $0.isEmpty || $0 == "auto" ? nil : $0 }
        self.vocabulary = vocabulary
        self.terms = terms
        self.threads = threads
    }

    /// Whisper keeps only the end of a long prompt, so the prompt is capped and names go last.
    static let promptCharacterLimit = 500
    /// Characters of the previous chunk's text carried into the prompt.
    static let previousTextLimit = 200

    public var effectiveLanguage: String { model.isEnglishOnly ? "en" : language }

    func arguments(wav: URL, outBase: URL, useVAD: Bool) -> [String] {
        var arguments = [
            "-m", model.localURL.path,
            "-f", wav.path,
            "-l", effectiveLanguage,
            "-t", String(threads),
            "-ojf", "-of", outBase.path,
            "-np", "-sns",
        ]
        // Without VAD, whisper repeats the name prompt over silence; it goes in only with VAD.
        guard useVAD else { return arguments }
        // Pad speech a little so word edges survive; require half a second of silence before splitting.
        arguments += ["--vad", "-vm", VADModel.localURL.path, "-vp", "200", "-vsd", "500"]
        if let prompt = prompt() { arguments += ["--carry-initial-prompt", "--prompt", prompt] }
        return arguments
    }

    /// The user's terms, then the names, as plain comma lists. With a label ("Uczestnicy: …") whisper sometimes repeated it as speech.
    func prompt() -> String? {
        let clean = { (items: [String]) in
            items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        }
        let names = Array(clean(vocabulary).prefix(20))
        var words = clean(terms).filter { !names.contains($0) }
        let previous = previousText.map { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > Self.previousTextLimit else { return trimmed }
            // Start at a word, not in the middle of one.
            let tail = String(trimmed.suffix(Self.previousTextLimit))
            return tail.firstIndex(of: " ").map { String(tail[tail.index(after: $0)...]) } ?? tail
        } ?? ""
        func build() -> String {
            var parts: [String] = []
            if !words.isEmpty { parts.append("\(words.joined(separator: ", ")).") }
            if !names.isEmpty { parts.append("\(names.joined(separator: ", ")).") }
            // Last, because whisper reads the prompt as the text just before the audio.
            if !previous.isEmpty { parts.append(previous) }
            return parts.joined(separator: " ")
        }
        var prompt = build()
        while prompt.count > Self.promptCharacterLimit, !words.isEmpty {
            words.removeLast()
            prompt = build()
        }
        return prompt.isEmpty ? nil : prompt
    }

    /// Splits the Settings field: one term per line or comma.
    public static func terms(from text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public static func findWhisperCLI() -> URL? {
        WhisperBinaries.find("whisper-cli")
    }

    public func transcribe(wav: URL) async throws -> [RecognizedSpeech] {
        try await transcribeDetectingLanguage(wav: wav).speech
    }

    public func transcribeDetectingLanguage(wav: URL) async throws -> Transcription {
        guard let cli = Self.findWhisperCLI() else { throw TranscriberError.whisperNotFound }
        guard model.isDownloaded else { throw TranscriberError.modelNotFound(model.name) }

        let useVAD = VADModel.isDownloaded
        let timeout = Self.timeout(forSeconds: WAVFile.duration(of: wav))
        let data: Data
        let server = WhisperServer.Configuration(model: model.localURL.path, vadModel: useVAD ? VADModel.localURL.path : nil, threads: threads)
        switch await WhisperServer.shared.transcribe(
            wav: wav, configuration: server, language: effectiveLanguage, prompt: useVAD ? prompt() : nil, timeout: timeout
        ) {
        case .served(let served):
            data = served
        case .fallBack:
            data = try await runCLI(cli, wav: wav, useVAD: useVAD, timeout: timeout)
        case .broken(let failures):
            throw TranscriberError.failed("whisper-server failed \(failures) times in a row; chunks wait for it instead of reloading the model for each one. It is tried again in \(Int(WhisperServer.retryAfter / 60)) minutes.")
        }
        let detected = Self.detectedLanguage(json: data)
        if effectiveLanguage == "auto", let detected,
           let fallback = Self.fallbackLanguage(detected: detected, preferred: preferredLanguage, meeting: meetingLanguage) {
            var pinned = self
            pinned.language = fallback
            let retried = try await pinned.transcribeDetectingLanguage(wav: wav)
            return Transcription(speech: retried.speech, language: fallback)
        }
        return Transcription(speech: try Self.parse(json: data, language: detected ?? effectiveLanguage), language: detected)
    }

    /// Chunks run one at a time, so a hung one stalls the queue: twice the audio's length, at least 30 s (60 s for a
    /// 30 s chunk). Loading the model for the server has its own timeout.
    static func timeout(forSeconds seconds: TimeInterval) -> TimeInterval {
        max(30, seconds * 2)
    }

    /// One chunk through `whisper-cli`, which loads the model each time: the path when `WhisperServer` isn't available.
    private func runCLI(_ cli: URL, wav: URL, useVAD: Bool, timeout: TimeInterval) async throws -> Data {
        let outBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrupio-\(UUID().uuidString)")
        let jsonURL = outBase.appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        var result = try await ProcessRunner.run(cli, arguments: arguments(wav: wav, outBase: outBase, useVAD: useVAD), timeout: timeout)
        if useVAD, !result.timedOut, result.status != 0 {
            // An older whisper-cli without --vad, or a damaged VAD model: transcribe without it rather than lose the chunk.
            result = try await ProcessRunner.run(cli, arguments: arguments(wav: wav, outBase: outBase, useVAD: false), timeout: timeout)
        }
        guard !result.timedOut else { throw TranscriberError.failed("whisper-cli took longer than \(Int(timeout)) seconds.") }
        guard result.status == 0 else {
            throw TranscriberError.failed(result.stderr.suffix(300).description)
        }
        return try Data(contentsOf: jsonURL)
    }

    /// The language to redo a chunk in when whisper's guess is likely wrong; nil keeps the guess.
    /// Only with a preferred language set: English and the preferred language are trusted, and so is the meeting's own
    /// language. A guess related to the preferred language (Polish heard as Czech) goes to it; any other goes to the
    /// meeting's language so far, else to English. An English call with accents is often heard as Dutch, German or
    /// Welsh, and forcing those chunks to Polish translated them.
    /// Without a preferred language the meeting's language so far is the only prior, and it only corrects a guess
    /// related to it (a Polish call heard as Czech); an unrelated guess may be a real switch of language and stays.
    static func fallbackLanguage(detected: String, preferred: String?, meeting: String?) -> String? {
        guard let preferred else {
            guard let meeting, detected != meeting, detected != "en", related(detected, meeting) else { return nil }
            return meeting
        }
        guard detected != preferred, detected != "en", detected != meeting else { return nil }
        if related(detected, preferred) { return preferred }
        return meeting ?? "en"
    }

    static func related(_ a: String, _ b: String) -> Bool {
        languageFamilies.contains { $0.contains(a) && $0.contains(b) }
    }

    /// Languages whisper confuses with each other on short or noisy audio.
    static let languageFamilies: [Set<String>] = [
        ["pl", "cs", "sk", "ru", "uk", "be", "bg", "sr", "hr", "bs", "sl", "mk"],
        ["de", "nl", "af", "lb", "da", "sv", "no", "nn", "is"],
        ["es", "pt", "it", "fr", "ca", "gl", "ro"],
    ]

    /// Parses whisper-cli `-oj` output, dropping markers, known hallucinations, repeat loops and wrong-script text.
    public static func parse(json: Data, language: String? = nil) throws -> [RecognizedSpeech] {
        struct Offsets: Decodable { let from: Int; let to: Int }
        struct Output: Decodable {
            struct Item: Decodable {
                struct Token: Decodable { let text: String; let offsets: Offsets; let p: Double? }
                let offsets: Offsets
                let text: String
                let tokens: [Token]?
                /// Set by whisper-server; whisper-cli only gives per-token probabilities.
                let avg_logprob: Double?
            }
            let transcription: [Item]
        }
        let output = try JSONDecoder().decode(Output.self, from: json)
        let expectsLatin = language.map(latinScriptLanguages.contains) ?? false
        var last: String?
        var run = 0
        let speech: [RecognizedSpeech] = output.transcription.compactMap { item in
            let text = cleanText(item.text)
            guard !text.isEmpty else { return nil }
            // whisper loops on noise, emitting the same line again and again. People repeat short replies
            // ("Tak. Tak."), so a short line may come twice in a row; a longer one only once.
            // A segment whisper itself was unsure of is usually invented from noise.
            let logprob = item.avg_logprob ?? averageLogProbability(item.tokens?.compactMap { $0.text.hasPrefix("[_") ? nil : $0.p } ?? [])
            if let logprob, logprob < minimumAverageLogProbability { return nil }
            let normalized = normalize(text)
            let short = normalized.split(separator: " ").count <= 2
            // Short lines must match exactly; longer ones also when nearly the same (punctuation, one word).
            run = last.map { short ? $0 == normalized : nearlySame($0, normalized) } == true ? run + 1 : 1
            last = normalized
            if run > (short ? 2 : 1) { return nil }
            if expectsLatin, latinLetterShare(text) < 0.5 { return nil }
            return RecognizedSpeech(
                start: TimeInterval(item.offsets.from) / 1000,
                end: TimeInterval(item.offsets.to) / 1000,
                text: text,
                words: words(item.tokens?.map { ($0.text, $0.offsets.from, $0.offsets.to) } ?? [])
            )
        }
        // "Thank you" or "bye" alone in a chunk is whisper filling silence; next to other speech it was said.
        if speech.allSatisfy({ silenceFillers.contains(normalize($0.text)) }) { return [] }
        return speech
    }

    /// Joins whisper tokens into words: a token starting with a space starts a word, others continue it
    /// ("av", "alan", "che"; "doesn", "'t"; a trailing "."). Special tokens like `[_BEG_]` are skipped.
    static func words(_ tokens: [(text: String, from: Int, to: Int)]) -> [TimedWord] {
        var words: [TimedWord] = []
        for token in tokens where !token.text.hasPrefix("[_") && !token.text.isEmpty {
            let start = TimeInterval(token.from) / 1000, end = TimeInterval(token.to) / 1000
            if token.text.hasPrefix(" ") || words.isEmpty {
                let text = token.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                words.append(TimedWord(start: start, end: max(start, end), text: text))
            } else {
                words[words.count - 1].text += token.text
                words[words.count - 1].end = max(words[words.count - 1].end, end)
            }
        }
        return words
    }

    /// The language whisper reports in `result.language` of its JSON output.
    public static func detectedLanguage(json: Data) -> String? {
        struct Output: Decodable {
            struct Result: Decodable { let language: String? }
            let result: Result?
        }
        guard let language = (try? JSONDecoder().decode(Output.self, from: json))?.result?.language,
              !language.isEmpty, language != "auto" else { return nil }
        return language
    }

    static let latinScriptLanguages: Set<String> = [
        "en", "pl", "de", "es", "fr", "it", "pt", "nl", "sv", "da", "no", "nn", "fi", "cs", "sk", "sl", "hr",
        "ro", "hu", "tr", "id", "ms", "vi", "ca", "et", "lv", "lt", "sq", "is", "ga", "cy", "eu", "gl", "af", "sw", "tl",
    ]

    /// Share of letters in `text` that are Latin script (accents included).
    static func latinLetterShare(_ text: String) -> Double {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return 1 }
        let latin = letters.filter { $0.value < 0x250 || (0x1E00...0x1EFF).contains($0.value) }
        return Double(latin.count) / Double(letters.count)
    }

    /// Segments below this average token log-probability are dropped (item #9 of the 22 Oct report).
    static let minimumAverageLogProbability = -1.0

    static func averageLogProbability(_ probabilities: [Double]) -> Double? {
        guard !probabilities.isEmpty else { return nil }
        return probabilities.map { log(max($0, 1e-6)) }.reduce(0, +) / Double(probabilities.count)
    }

    /// Two normalized lines that differ only in punctuation or by about one word in ten.
    static func nearlySame(_ a: String, _ b: String) -> Bool {
        let strip = { (s: String) in s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init) }
        let x = strip(a), y = strip(b)
        guard !x.isEmpty, !y.isEmpty else { return x == y }
        if x == y { return true }
        let longer = max(x.count, y.count)
        guard Double(min(x.count, y.count)) / Double(longer) >= 0.85 else { return false }
        return Double(editDistance(x, y)) / Double(longer) <= 0.1
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, cb) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    /// Strips whisper's non-speech markers and subtitle credits it copies from training data.
    /// Common phrases it invents on silence are handled in `parse`, since people say them too.
    public static func cleanText(_ raw: String) -> String {
        // Brackets and asterisks are always markers; parentheses only when they hold a sound label, since speech can contain "(roughly)".
        var text = raw.replacingOccurrences(of: #"\[[^\]]*\]|\*[^*]*\*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"\((?i:music|silence|applause|laughter|laughs|noise|inaudible|background noise|static|coughs?|sighs?|beep|muzyka|cisza|śmiech|musik|stille|musique|música)\)"#,
            with: "", options: .regularExpression
        )
        text = stripPromptLabels(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let normalized = normalize(text)
        if subtitleCredits.contains(normalized) || hallucinationPrefixes.contains(where: normalized.hasPrefix) { return "" }
        if text.allSatisfy({ $0.isPunctuation || $0.isWhitespace }) { return "" }
        return text
    }

    /// Labels earlier prompts used ("Uczestnicy: Anna, Piotr."). Whisper sometimes repeated the prompt as speech.
    static let promptLabels = ["uczestnicy", "participants", "słownictwo", "vocabulary"]

    /// Drops a leading prompt label with the list after it, up to the end of that sentence; the rest of the line stays.
    static func stripPromptLabels(_ text: String) -> String {
        var text = text
        let pattern = #"^(?i:"# + promptLabels.joined(separator: "|") + #")\s*:[^.!?]*[.!?]*\s*"#
        while let range = text.range(of: pattern, options: .regularExpression) {
            text.removeSubrange(range)
        }
        // The label alone, without a list.
        return promptLabels.contains(normalize(text)) ? "" : text
    }

    /// Never real meeting speech.
    static let subtitleCredits: Set<String> = [
        "thanks for watching", "thank you for watching", "subtitles by the amara.org community",
        "napisy stworzone przez społeczność amara.org", "untertitel der amara.org-community",
        "please subscribe", "subscribe to the channel", "продолжение следует", "gracias por ver",
        "vielen dank fürs zuschauen", "dzięki za obejrzenie", "dziękuję za obejrzenie",
        "don't forget to like and subscribe", "like and subscribe",
    ]

    /// Said in meetings, but also what whisper produces on silence; dropped only when a chunk holds nothing else.
    static let silenceFillers: Set<String> = [
        "thank you", "you", "bye", "dziękuję", "dziękuję bardzo", "thank you very much", "dziękuję za uwagę",
    ]

    /// Subtitle credits whisper copies from its training data, followed by any name.
    static let hallucinationPrefixes = ["napisy wykonane przez", "napisy stworzone przez", "subtitles by", "untertitel von", "sous-titres réalisés par"]
}

public struct ProcessResult: Sendable {
    public let status: Int32
    public let timedOut: Bool
    public let stdout: String
    public let stderr: String
}

public enum ProcessRunner {
    private static let running = LockedProcesses()

    /// - Parameters:
    ///   - environment: overrides merged into the inherited environment; a nil value removes the variable.
    ///   - inheritEnvironment: false starts the child with only `environment`.
    ///   - input: written to the child's stdin, which is then closed.
    ///   - directory: the child's working directory.
    public static func run(_ executable: URL, arguments: [String], environment: [String: String?] = [:], inheritEnvironment: Bool = true,
                           input: Data? = nil, directory: URL? = nil, timeout: TimeInterval? = nil) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if !environment.isEmpty || !inheritEnvironment {
                var merged = inheritEnvironment ? ProcessInfo.processInfo.environment : [:]
                for (key, value) in environment { merged[key] = value }
                process.environment = merged
            }
            if let directory { process.currentDirectoryURL = directory }
            let stdin = input.map { _ in Pipe() }
            if let stdin { process.standardInput = stdin }
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            // Drain pipes concurrently so a chatty child can't block on a full pipe buffer.
            let outData = PipeCollector(out)
            let errData = PipeCollector(err)
            let timedOut = LockedFlag()
            process.terminationHandler = { process in
                running.remove(process)
                continuation.resume(returning: ProcessResult(
                    status: process.terminationStatus,
                    timedOut: timedOut.value,
                    stdout: outData.finish(),
                    stderr: errData.finish()
                ))
            }
            running.insert(process)
            do {
                try process.run()
            } catch {
                running.remove(process)
                continuation.resume(throwing: error)
                return
            }
            if let stdin, let input {
                // Written off the caller's thread: a large input fills the pipe until the child reads it.
                // A child that exits without reading would otherwise kill the app with SIGPIPE.
                _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                DispatchQueue.global().async {
                    try? stdin.fileHandleForWriting.write(contentsOf: input)
                    try? stdin.fileHandleForWriting.close()
                }
            }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    timedOut.set()
                    ProcessGroupKill.terminate(process)
                }
            }
        }
    }

    /// Stops every child process (called when the app quits so whisper-cli and whisper-server don't outlive it).
    public static func terminateAll() {
        running.terminateAll()
        WhisperServer.shared.terminate()
    }
}

/// Stops a child and everything it spawned. Foundation's `Process` starts each child as the leader of
/// its own process group, so signalling `-pid` reaches grandchildren (node, hooks) too.
public enum ProcessGroupKill {
    /// SIGTERM to the group, then SIGKILL to the group `grace` seconds later if the child is still running.
    public static func terminate(_ process: Process, grace: TimeInterval = 5) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        signalGroup(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            // Kill the group even if the leader is gone: a grandchild may still hold the pipes.
            if process.isRunning { CoreLog.process.warning("pid \(pid) ignored SIGTERM; sending SIGKILL") }
            signalGroup(pid, SIGKILL)
        }
    }

    static func signalGroup(_ pid: pid_t, _ signal: Int32) {
        kill(-pid, signal)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

private final class LockedProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]
    func insert(_ process: Process) { lock.withLock { processes[ObjectIdentifier(process)] = process } }
    func remove(_ process: Process) { _ = lock.withLock { processes.removeValue(forKey: ObjectIdentifier(process)) } }
    func terminateAll() { lock.withLock { processes.values.forEach { ProcessGroupKill.terminate($0) } } }
}

private final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let closed = DispatchSemaphore(value: 0)

    /// Reads on its own thread until the write end closes, so a chatty child can't block on a full pipe buffer.
    init(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        Thread.detachNewThread { [self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.withLock { data.append(chunk) }
            }
            closed.signal()
        }
    }

    /// Waits at most `grace` for the write end to close: a grandchild that inherited stdout and outlives
    /// the child would otherwise block here forever. Whatever was read by then is kept.
    func finish(grace: TimeInterval = 2) -> String {
        if closed.wait(timeout: .now() + grace) == .timedOut {
            CoreLog.process.warning("Child output still open \(grace, privacy: .public) s after exit; keeping what was read")
        }
        return lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}
