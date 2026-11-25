import XCTest
@testable import ChrupioCore

/// Item #9: Parakeet vocabulary boosting gets the same names and terms whisper's prompt gets.
final class ParakeetVocabularyTests: XCTestCase {
    func testSettingTheTranscriberVocabularyPublishesIt() {
        var transcriber = Transcriber(model: WhisperModel.all[1])
        transcriber.vocabulary = ["Piotr Kaczmarek", " ", "Alicja"]
        transcriber.terms = ["Kibana", "alicja"]
        XCTAssertEqual(SpeechVocabulary.current, ["Kibana", "alicja", "Piotr Kaczmarek"])
    }

    func testBoostTermsSkipTooShortAndDuplicates() {
        XCTAssertEqual(SpeechVocabulary.boostTerms(["CRM", "Ed", "Anna Nowak", "anna nowak", ""]), ["CRM", "Anna Nowak"])
    }

    private func speech(_ words: [(String, Double)]) -> RecognizedSpeech {
        let timed = words.map { TimedWord(start: $0.1, end: $0.1 + 0.3, text: $0.0) }
        return RecognizedSpeech(start: timed.first!.start, end: timed.last!.end, text: words.map(\.0).joined(separator: " "), words: timed)
    }

    func testSingleWordReplacementKeepsTimesAndPunctuation() {
        let line = speech([("Cześć", 0), ("Alcja,", 0.5), ("jak", 1.0), ("tam?", 1.4)])
        let fixed = ParakeetOutput.applying(replacements: [("Alcja", "Alicja")], to: [line])
        XCTAssertEqual(fixed[0].text, "Cześć Alicja, jak tam?")
        XCTAssertEqual(fixed[0].words[1].text, "Alicja,")
        XCTAssertEqual(fixed[0].words[1].start, 0.5)
    }

    func testMultiWordOriginalBecomesOneTerm() {
        let line = speech([("Ask", 0), ("Heath", 0.5), ("Chado.", 1.0)])
        let fixed = ParakeetOutput.applying(replacements: [("heath chado", "Hit Czado")], to: [line])
        XCTAssertEqual(fixed[0].text, "Ask Hit Czado.")
        XCTAssertEqual(fixed[0].words.count, 2)
        XCTAssertEqual(fixed[0].words[1].start, 0.5)
        XCTAssertEqual(fixed[0].words[1].end, 1.3, accuracy: 0.001)
    }

    func testUnmatchedReplacementChangesNothing() {
        let line = speech([("Dzień", 0), ("dobry.", 0.5)])
        XCTAssertEqual(ParakeetOutput.applying(replacements: [("Alcja", "Alicja")], to: [line]), [line])
    }
}

/// Follow-up: project corrections become boosting aliases (right spelling > misheard forms).
final class BoostAliasTests: XCTestCase {
    func testCorrectionsTurnIntoAliases() {
        let context = MeetingContext(corrections: ["Alcja": "Alicja", "alicya": "Alicja", "Kibana": "kibana", " ": "x"])
        XCTAssertEqual(context.boostAliases, ["Alicja": ["Alcja", "alicya"]])
    }
}
