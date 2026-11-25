import Foundation
import Observation
import ChrupioCore

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// A snapshot run starts from an empty domain of its own, so it never shows or changes saved preferences.
    static let snapshotDomain = "chrupio-debug-snapshot"
    private let defaults: UserDefaults = {
        guard DebugSnapshot.directory != nil, let demo = UserDefaults(suiteName: AppSettings.snapshotDomain) else { return .standard }
        demo.removePersistentDomain(forName: AppSettings.snapshotDomain)
        return demo
    }()

    var autoRecord: Bool { didSet { defaults.set(autoRecord, forKey: "autoRecord") } }
    var captureSystemAudio: Bool { didSet { defaults.set(captureSystemAudio, forKey: "captureSystemAudio") } }
    /// Record Chrome / desktop meeting apps that use the mic even when the extension reports nothing.
    var detectWithoutExtension: Bool { didSet { defaults.set(detectWithoutExtension, forKey: "detectWithoutExtension") } }
    var whisperModelName: String { didSet { defaults.set(whisperModelName, forKey: "whisperModel") } }
    /// Transcribe calls detected as Polish with Parakeet instead of whisper; English and mixed calls stay on whisper.
    var parakeetForPolish: Bool { didSet { defaults.set(parakeetForPolish, forKey: "parakeetForPolish") } }
    var language: String { didSet { defaults.set(language, forKey: "language") } }
    /// With automatic detection: the language most meetings are in, used when detection is unsure.
    var preferredLanguage: String { didSet { defaults.set(preferredLanguage, forKey: "preferredLanguage") } }
    /// Names and terms whisper should spell right, one per line or comma.
    var vocabulary: String { didSet { defaults.set(vocabulary, forKey: "vocabulary") } }
    /// The user's names as calls show them, one per line or comma; the first is used when a call doesn't say
    /// which participant is the user. Empty until filled from the meetings (`MeetingCoordinator.start`).
    var selfNames: String { didSet { defaults.set(selfNames, forKey: "selfNames") } }
    var selfNameList: [String] { SelfNames.parse(selfNames) }
    /// A project context JSON (see `MeetingContext`); empty for none.
    var contextFile: String { didSet { defaults.set(contextFile, forKey: "contextFile") } }
    /// CLAUDE_CONFIG_DIR of the logged-in Claude Code account, e.g. ~/.claude-personal; empty for Claude's default.
    var claudeConfigDir: String { didSet { defaults.set(claudeConfigDir, forKey: "claudeConfigDir") } }
    /// What Connect installs in Claude Code (the three switches). Nil: never connected, so Connect uses `.defaults`.
    /// Disconnect keeps it, so a later Connect restores what the user had.
    var claudeCodeComponents: ClaudeCodeSetup.Components? {
        didSet {
            if let claudeCodeComponents, let data = try? JSONEncoder().encode(claudeCodeComponents) {
                defaults.set(data, forKey: "claudeCodeComponents")
            } else {
                defaults.removeObject(forKey: "claudeCodeComponents")
            }
        }
    }
    /// Config dirs a Connect wrote to, so Disconnect cleans them even after the Settings folder changes.
    var claudeCodeHomes: [String] { didSet { defaults.set(claudeCodeHomes, forKey: "claudeCodeHomes") } }
    var autoSummarize: Bool { didSet { defaults.set(autoSummarize, forKey: "autoSummarize") } }
    /// Off: nothing is sent to Anthropic. Summaries asked for meanwhile are dropped, not queued; a running one stops
    /// before its next call; pending retries keep their schedule for when it is back on; follow-up drafts are refused.
    var claudeSummaries: Bool { didSet { defaults.set(claudeSummaries, forKey: "claudeSummaries") } }
    var keepAudio: Bool { didSet { defaults.set(keepAudio, forKey: "keepAudio") } }
    /// Removes call audio that the mic picked up from the speakers before transcribing.
    var echoCancellation: Bool { didSet { defaults.set(echoCancellation, forKey: "echoCancellation") } }
    /// Meetings shorter than this are discarded (accidental joins and quick hang-ups).
    var minimumMeetingSeconds: Double { didSet { defaults.set(minimumMeetingSeconds, forKey: "minimumMeetingSeconds") } }
    var notify: Bool { didSet { defaults.set(notify, forKey: "notify") } }
    /// Write each finished meeting as a Markdown file that other tools (Claude Code, Obsidian) can read.
    var exportMarkdown: Bool { didSet { defaults.set(exportMarkdown, forKey: "exportMarkdown") } }
    var exportFolderPath: String { didSet { defaults.set(exportFolderPath, forKey: "exportFolderPath") } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }
    /// Probe files and page snapshots from calls, for fixing speaker detection. Off by default; the owner turns it on
    /// with: defaults write com.chrupio.app saveDiagnostics -bool true
    var saveDiagnostics: Bool { didSet { defaults.set(saveDiagnostics, forKey: "saveDiagnostics") } }

    var whisperModel: WhisperModel {
        WhisperModel.all.first { $0.name == whisperModelName } ?? WhisperModel.all[1]
    }

    private init() {
        defaults.register(defaults: [
            "autoRecord": true,
            "captureSystemAudio": true,
            "detectWithoutExtension": false,
            "whisperModel": "small",
            "parakeetForPolish": true,
            "language": "auto",
            "preferredLanguage": "",
            "vocabulary": "",
            "selfNames": "",
            "contextFile": "",
            "claudeConfigDir": "",
            "autoSummarize": true,
            "claudeSummaries": true,
            "keepAudio": true,
            "echoCancellation": true,
            "minimumMeetingSeconds": 30.0,
            "notify": true,
            "exportMarkdown": true,
            "exportFolderPath": MeetingExporter.defaultFolder.path,
            "hasCompletedOnboarding": false,
            "saveDiagnostics": false,
        ])
        autoRecord = defaults.bool(forKey: "autoRecord")
        captureSystemAudio = defaults.bool(forKey: "captureSystemAudio")
        detectWithoutExtension = defaults.bool(forKey: "detectWithoutExtension")
        whisperModelName = defaults.string(forKey: "whisperModel") ?? "small"
        parakeetForPolish = defaults.bool(forKey: "parakeetForPolish")
        language = defaults.string(forKey: "language") ?? "auto"
        preferredLanguage = defaults.string(forKey: "preferredLanguage") ?? ""
        vocabulary = defaults.string(forKey: "vocabulary") ?? ""
        selfNames = defaults.string(forKey: "selfNames") ?? ""
        contextFile = defaults.string(forKey: "contextFile") ?? ""
        claudeConfigDir = defaults.string(forKey: "claudeConfigDir") ?? ""
        claudeCodeComponents = defaults.data(forKey: "claudeCodeComponents")
            .flatMap { try? JSONDecoder().decode(ClaudeCodeSetup.Components.self, from: $0) }
        claudeCodeHomes = defaults.stringArray(forKey: "claudeCodeHomes") ?? []
        autoSummarize = defaults.bool(forKey: "autoSummarize")
        claudeSummaries = defaults.bool(forKey: "claudeSummaries")
        keepAudio = defaults.bool(forKey: "keepAudio")
        echoCancellation = defaults.bool(forKey: "echoCancellation")
        minimumMeetingSeconds = defaults.double(forKey: "minimumMeetingSeconds")
        notify = defaults.bool(forKey: "notify")
        exportMarkdown = defaults.bool(forKey: "exportMarkdown")
        exportFolderPath = defaults.string(forKey: "exportFolderPath") ?? MeetingExporter.defaultFolder.path
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        saveDiagnostics = defaults.bool(forKey: "saveDiagnostics")
    }

    var exporter: MeetingExporter? {
        exportMarkdown ? MeetingExporter(folder: URL(fileURLWithPath: exportFolderPath, isDirectory: true)) : nil
    }

    static let languages: [(code: String, name: String)] = [
        ("auto", "Detect automatically"), ("en", "English"), ("pl", "Polish"), ("de", "German"),
        ("es", "Spanish"), ("fr", "French"), ("it", "Italian"), ("pt", "Portuguese"), ("uk", "Ukrainian"),
        ("nl", "Dutch"), ("cs", "Czech"), ("ja", "Japanese"), ("zh", "Chinese"),
    ]
}
