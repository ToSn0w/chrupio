import XCTest
@testable import ChrupioCore

/// Prompt labels: the Whisper prompt carries no labels, and labels that leak into the transcript are stripped.
final class PromptLabelTests: XCTestCase {
    func testPromptHasNoLabels() {
        let transcriber = Transcriber(model: WhisperModel.all[1], language: "pl", vocabulary: ["Anna Nowak", "Piotr"], terms: ["Kibana"])
        XCTAssertEqual(transcriber.prompt(), "Kibana. Anna Nowak, Piotr.")
        let english = Transcriber(model: WhisperModel.all[1], language: "en", vocabulary: ["Ann"])
        XCTAssertEqual(english.prompt(), "Ann.")
    }

    func testLeakedLabelIsStripped() {
        // Whisper repeated the prompt as speech.
        XCTAssertEqual(Transcriber.cleanText("Uczestnicy: Piotr Kaczmarek, Sam Carter."), "")
        XCTAssertEqual(Transcriber.cleanText(" Participants: Ann, Bob. So let's start."), "So let's start.")
        XCTAssertEqual(Transcriber.cleanText("Słownictwo: Kibana, CRM. Uczestnicy: Ann. Dobra, zaczynamy."), "Dobra, zaczynamy.")
        XCTAssertEqual(Transcriber.cleanText("vocabulary: CRM"), "")
        XCTAssertEqual(Transcriber.cleanText("Uczestnicy."), "")
    }

    func testLabelWordsInsideSpeechStay() {
        XCTAssertEqual(Transcriber.cleanText("The participants: all of them agreed."), "The participants: all of them agreed.")
        XCTAssertEqual(Transcriber.cleanText("Participants were late."), "Participants were late.")
    }
}

final class LanguageFallbackTests: XCTestCase {
    func testTrustedGuessesAreKept() {
        XCTAssertNil(Transcriber.fallbackLanguage(detected: "en", preferred: "pl", meeting: nil))
        XCTAssertNil(Transcriber.fallbackLanguage(detected: "pl", preferred: "pl", meeting: "en"))
        XCTAssertNil(Transcriber.fallbackLanguage(detected: "de", preferred: "pl", meeting: "de"), "a German call stays German")
        XCTAssertNil(Transcriber.fallbackLanguage(detected: "nl", preferred: nil, meeting: nil), "no preferred language, no redo")
    }

    func testAccentedEnglishIsNotForcedToPolish() {
        for detected in ["nl", "de", "cy"] {
            XCTAssertEqual(Transcriber.fallbackLanguage(detected: detected, preferred: "pl", meeting: nil), "en")
            XCTAssertEqual(Transcriber.fallbackLanguage(detected: detected, preferred: "pl", meeting: "en"), "en")
        }
        XCTAssertEqual(Transcriber.fallbackLanguage(detected: "nl", preferred: "pl", meeting: "pl"), "pl", "a Polish call stays Polish")
    }

    func testPolishHeardAsARelatedLanguageGoesToPolish() {
        for detected in ["ru", "cs", "sk"] {
            XCTAssertEqual(Transcriber.fallbackLanguage(detected: detected, preferred: "pl", meeting: nil), "pl")
            XCTAssertEqual(Transcriber.fallbackLanguage(detected: detected, preferred: "pl", meeting: "en"), "pl")
        }
    }
}
