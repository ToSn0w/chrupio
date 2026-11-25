import XCTest
@testable import ChrupioCore

final class EngineRoutingTests: XCTestCase {
    private func whisper(_ language: String?, lines: Int = 1) -> Transcription {
        Transcription(speech: (0..<lines).map { RecognizedSpeech(start: Double($0), end: Double($0) + 1, text: "line \($0)") },
                      language: language)
    }

    func testAConfirmedPolishMeetingGoesStraightToParakeet() {
        let routing = EngineRouting(parakeetEnabled: true)
        XCTAssertEqual(routing.engine, .whisper)
        XCTAssertEqual(routing.pinned(toConfirmed: "pl").engine, .parakeet)
        XCTAssertEqual(routing.pinned(toConfirmed: "pl").language, "pl")
    }

    func testOtherLanguagesAndDisabledParakeetStayOnWhisper() {
        XCTAssertEqual(EngineRouting(parakeetEnabled: true).pinned(toConfirmed: "en").engine, .whisper)
        XCTAssertEqual(EngineRouting(parakeetEnabled: true).pinned(toConfirmed: nil).engine, .whisper)
        XCTAssertEqual(EngineRouting(parakeetEnabled: false).pinned(toConfirmed: "pl").engine, .whisper)
    }

    func testALanguageChosenInSettingsIsKept() {
        XCTAssertEqual(EngineRouting(parakeetEnabled: true, language: "en").pinned(toConfirmed: "pl").language, "en")
    }

    func testEachChunkIsRoutedByItsOwnLanguage() {
        let routing = EngineRouting(parakeetEnabled: true, language: "auto")
        XCTAssertEqual(routing.engine, .whisper, "whisper detects every chunk's language first")
        XCTAssertEqual(routing.parakeetLanguage(after: whisper("pl")), "pl", "a Polish chunk is redone on Parakeet")
        XCTAssertNil(routing.parakeetLanguage(after: whisper("en")), "an English chunk of the same call stays on whisper")
        XCTAssertEqual(routing.parakeetLanguage(after: whisper("pl")), "pl", "nothing is locked by earlier chunks")
        XCTAssertEqual(routing.engine, .whisper)
    }

    func testSilentOrUndetectedChunksStayOnWhisper() {
        let routing = EngineRouting(parakeetEnabled: true)
        XCTAssertNil(routing.parakeetLanguage(after: whisper("pl", lines: 0)), "a guess on silence means nothing")
        XCTAssertNil(routing.parakeetLanguage(after: whisper(nil)))
    }

    func testOffKeepsTodaysWhisperOnlyBehavior() {
        let routing = EngineRouting(parakeetEnabled: false)
        XCTAssertEqual(routing.engine, .whisper)
        XCTAssertNil(routing.parakeetLanguage(after: whisper("pl")))
        XCTAssertEqual(EngineRouting(parakeetEnabled: false, language: "pl").engine, .whisper)
    }

    func testPolishChosenInSettingsUsesParakeetFromTheStart() {
        XCTAssertEqual(EngineRouting(parakeetEnabled: true, language: "pl").engine, .parakeet)
        XCTAssertEqual(EngineRouting(parakeetEnabled: true, language: "").engine, .whisper)
        XCTAssertEqual(EngineRouting(parakeetEnabled: true, language: "en").engine, .whisper)
    }

    func testMeetingLanguageIsOnlyAPriorForRelatedGuesses() {
        XCTAssertEqual(Transcriber.fallbackLanguage(detected: "cs", preferred: nil, meeting: "pl"), "pl",
                       "a Polish call's chunk heard as Czech is Polish")
        XCTAssertNil(Transcriber.fallbackLanguage(detected: "en", preferred: nil, meeting: "pl"), "English in a Polish call stays English")
        XCTAssertNil(Transcriber.fallbackLanguage(detected: "de", preferred: nil, meeting: "pl"), "an unrelated language isn't forced")
        XCTAssertNil(Transcriber.fallbackLanguage(detected: "cs", preferred: nil, meeting: nil))
    }

    func testPreferredLanguageStillConfirmsTheCallLanguageForRouting() {
        var vote = LanguageVote(preferred: "pl")
        for index in 0..<2 { XCTAssertNil(vote.record("pl", speechCount: 3, at: Double(index) * 30)) }
        XCTAssertNil(vote.confirmed)
        XCTAssertNil(vote.record("pl", speechCount: 3, at: 60), "still not pinned")
        XCTAssertEqual(vote.confirmed, "pl")
        _ = vote.record("en", speechCount: 3, at: 90)
        XCTAssertEqual(vote.confirmed, "pl", "set once")

        var mixed = LanguageVote(preferred: "pl")
        for (index, language) in ["pl", "en", "pl", "pl", "en"].enumerated() {
            _ = mixed.record(language, speechCount: 3, at: Double(index) * 30)
        }
        XCTAssertNil(mixed.confirmed, "a mixed call has no confirmed language")
    }
}

final class ParakeetOutputTests: XCTestCase {
    func testTokensBecomeSentencesWithWordTimes() {
        let tokens: [(text: String, start: TimeInterval, end: TimeInterval)] = [
            (" Dzień", 0.24, 0.48), (" dob", 0.48, 0.64), ("ry", 0.64, 0.8), (".", 0.8, 0.88),
            ("▁Jak", 1.2, 1.36), (" się", 1.36, 1.52), (" mas", 1.52, 1.68), ("z", 1.68, 1.76), ("?", 1.76, 1.84),
        ]
        let speech = ParakeetOutput.speech(tokens: tokens)
        XCTAssertEqual(speech.map(\.text), ["Dzień dobry.", "Jak się masz?"])
        XCTAssertEqual(speech[0].start, 0.24)
        XCTAssertEqual(speech[0].end, 0.88)
        XCTAssertEqual(speech[0].words, [TimedWord(start: 0.24, end: 0.48, text: "Dzień"), TimedWord(start: 0.48, end: 0.88, text: "dobry.")])
        XCTAssertEqual(speech[1].words.map(\.text), ["Jak", "się", "masz?"])
        XCTAssertEqual(speech[1].words.first?.start, 1.2)
    }

    func testLongPauseSplitsAndControlTokensAreDropped() {
        let tokens: [(text: String, start: TimeInterval, end: TimeInterval)] = [
            (" no", 0, 0.2), (" dobra", 0.2, 0.5), ("<unk>", 0.5, 0.6), (" to", 2.0, 2.1), (" lecimy", 2.1, 2.5),
        ]
        XCTAssertEqual(ParakeetOutput.speech(tokens: tokens).map(\.text), ["no dobra", "to lecimy"])
    }

    func testCleanupMatchesWhisper() {
        XCTAssertEqual(ParakeetOutput.speech(tokens: [(" [muzyka]", 0, 1)]), [])
        XCTAssertEqual(ParakeetOutput.speech(tokens: []), [])
    }
}
