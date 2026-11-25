import XCTest
@testable import ChrupioCore

/// VAD flags and the hallucination guard.
final class HallucinationGuardTests: XCTestCase {
    private func json(_ items: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["transcription": items])
    }

    private func item(_ text: String, from: Int = 0, to: Int = 1000, avg: Double? = nil, p: [Double]? = nil) -> [String: Any] {
        var item: [String: Any] = ["offsets": ["from": from, "to": to], "text": text]
        if let avg { item["avg_logprob"] = avg }
        if let p {
            item["tokens"] = p.enumerated().map { index, p in
                ["text": " w\(index)", "offsets": ["from": from, "to": to], "p": p] as [String: Any]
            }
        }
        return item
    }

    func testLowAverageLogProbabilityIsDropped() throws {
        let data = try json([item("Real speech here.", avg: -0.3), item("Invented words in noise.", avg: -1.4)])
        XCTAssertEqual(try Transcriber.parse(json: data).map(\.text), ["Real speech here."])
    }

    func testCLITokenProbabilitiesGiveTheAverage() throws {
        // whisper-cli -ojf has no avg_logprob, only per-token p; ln(0.2) ≈ -1.6.
        let data = try json([item("Clear line.", p: [0.9, 0.8]), item("Mumbled line.", p: [0.2, 0.2])])
        XCTAssertEqual(try Transcriber.parse(json: data).map(\.text), ["Clear line."])
    }

    func testSpecialTokensDoNotCountTowardTheAverage() throws {
        var segment = item("Fine line.", p: [0.9])
        var tokens = segment["tokens"] as! [[String: Any]]
        tokens.insert(["text": "[_BEG_]", "offsets": ["from": 0, "to": 0], "p": 0.01], at: 0)
        segment["tokens"] = tokens
        XCTAssertEqual(try Transcriber.parse(json: json([segment])).map(\.text), ["Fine line."])
    }

    func testNearVerbatimRepeatIsDropped() throws {
        let data = try json([
            item("We need to ship the release on Friday.", from: 0, to: 3000),
            item("We need to ship the release on Friday", from: 3000, to: 6000),
            item("we need to ship the release on friday!", from: 6000, to: 9000),
            item("Then we test it.", from: 9000, to: 10000),
        ])
        XCTAssertEqual(try Transcriber.parse(json: data).map(\.text), ["We need to ship the release on Friday.", "Then we test it."])
    }

    func testOneWordDifferenceIsStillARepeat() throws {
        let data = try json([
            item("Okay so the deployment pipeline is broken again today"),
            item("Okay so the deployment pipeline is broken again, today."),
            item("Okay so the deployment pipeline is broken again tday"),
        ])
        XCTAssertEqual(try Transcriber.parse(json: data).count, 1)
    }

    func testDifferentSentencesStay() throws {
        let data = try json([item("The pipeline is broken."), item("The pipeline is fixed now, thanks to Anna.")])
        XCTAssertEqual(try Transcriber.parse(json: data).count, 2)
    }

    func testShortRepliesMayRepeatOnce() throws {
        let data = try json([item("Tak."), item("Tak."), item("Tak.")])
        XCTAssertEqual(try Transcriber.parse(json: data).count, 2)
    }

    func testMoreSilenceHallucinationsAreDropped() {
        XCTAssertEqual(Transcriber.cleanText("Dzięki za obejrzenie!"), "")
        XCTAssertEqual(Transcriber.cleanText("Don't forget to like and subscribe."), "")
    }

    func testServerAverageLogProbabilityIsPassedOn() throws {
        let reply = #"{"segments":[{"text":" Hi","start":0,"end":1,"avg_logprob":-1.7,"words":[]}]}"#
        let data = try XCTUnwrap(WhisperServer.cliJSON(fromServer: Data(reply.utf8), requestedLanguage: "en"))
        XCTAssertEqual(try Transcriber.parse(json: data).count, 0)
    }

    func testVADPaddingIsAtLeast200ms() throws {
        let args = WhisperServer.arguments(.init(model: "/m.bin", vadModel: "/vad.bin", threads: 4), port: 1)
        let pad = try XCTUnwrap(args.firstIndex(of: "-vp"))
        XCTAssertGreaterThanOrEqual(Int(args[pad + 1]) ?? 0, 200)
        XCTAssertTrue(args.contains("--vad"))
        XCTAssertFalse(WhisperServer.arguments(.init(model: "/m.bin", vadModel: nil, threads: 4), port: 1).contains("--vad"))
    }
}
