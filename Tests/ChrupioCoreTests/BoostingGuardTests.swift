@testable import ChrupioCore
import XCTest

final class BoostingGuardTests: XCTestCase {
    func testShortTermsAreNeverInsertedWithoutAnAlias() {
        XCTAssertFalse(BoostingGuard.accepts(original: "nad", replacement: "NADA", aliases: []))
        XCTAssertFalse(BoostingGuard.accepts(original: "i", replacement: "Jira", aliases: []))
        XCTAssertFalse(BoostingGuard.accepts(original: "roi", replacement: "ROI", aliases: []))
    }

    func testAnAliasIsAcceptedWhateverTheLength() {
        XCTAssertTrue(BoostingGuard.accepts(original: "Dżira", replacement: "Jira", aliases: ["dżira", "żyra"]))
        XCTAssertTrue(BoostingGuard.accepts(original: "and a no rack,", replacement: "Anna Nowak", aliases: ["And a no rack"]))
    }

    func testALongTermNeedsToSoundLikeTheOriginal() {
        XCTAssertTrue(BoostingGuard.accepts(original: "Alcja", replacement: "Alicja", aliases: []))
        XCTAssertTrue(BoostingGuard.accepts(original: "kibane", replacement: "Kibana", aliases: []))
        XCTAssertFalse(BoostingGuard.accepts(original: "jeszcze", replacement: "Kibana", aliases: []))
        XCTAssertFalse(BoostingGuard.accepts(original: "tak", replacement: "Alicja", aliases: []))
    }

    func testEmptyInputIsRejected() {
        XCTAssertFalse(BoostingGuard.accepts(original: "", replacement: "Alicja", aliases: []))
        XCTAssertFalse(BoostingGuard.accepts(original: "Alcja", replacement: " ", aliases: []))
    }

    func testAliasIndexIgnoresCaseAndSpacingAndMergesDuplicates() {
        let index = BoostingGuard.aliasIndex(["jira": ["dżira"], " Jira ": ["żyra"], "Kibana": []])
        XCTAssertEqual(Set(index[BoostingGuard.key("Jira")] ?? []), ["dżira", "żyra"])
        XCTAssertNotNil(index[BoostingGuard.key("kibana")])
        XCTAssertTrue(BoostingGuard.accepts(original: "żyra", replacement: "Jira", aliases: index[BoostingGuard.key("Jira")] ?? []))
    }

    func testMultiWordOriginalPassesSimilarityWithoutAlias() {
        XCTAssertTrue(BoostingGuard.accepts(original: "hit czado", replacement: "Hitczado", aliases: []))
    }

    func testPolishLetterFoldingMakesTheComparisonAccentBlind() {
        XCTAssertTrue(BoostingGuard.accepts(original: "Łukasz", replacement: "Lukasz", aliases: []))
    }

    func testPunctuationOnlyOriginalIsRejected() {
        XCTAssertFalse(BoostingGuard.accepts(original: "...", replacement: "Alicja", aliases: []))
    }
}
