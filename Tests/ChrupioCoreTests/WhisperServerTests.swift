import Foundation
@testable import ChrupioCore
import XCTest

final class WhisperServerTests: XCTestCase {
    /// Trimmed from a real whisper-server 1.9.5 `verbose_json` reply.
    let serverReply = """
    {"task":"transcribe","language":"polish","duration":30.0,"text":" Dobra, zaczynamy.\\n Jasne.\\n",
     "segments":[
      {"id":0,"text":" Dobra, zaczynamy.","start":0.31,"end":2.5,"tokens":[1,2],
       "words":[{"word":" Dobra","start":0.31,"end":0.8,"t_dtw":-1,"probability":0.9},{"word":",","start":0.8,"end":0.82,"t_dtw":-1,"probability":0.9},
                {"word":" zaczy","start":0.9,"end":1.5,"t_dtw":-1,"probability":0.9},{"word":"namy.","start":1.5,"end":2.5,"t_dtw":-1,"probability":0.9}]},
      {"id":1,"text":" Jasne.","start":3.0,"end":3.6,"tokens":[3],"words":[{"word":" Jasne.","start":3.0,"end":3.6,"t_dtw":-1,"probability":0.9}]}
     ],
     "detected_language":"polish","detected_language_probability":0.99,"language_probabilities":{"pl":0.99,"ru":0.01}}
    """

    /// Failures below the limit send the chunk to whisper-cli; at the limit chunks fail until the retry pause ends.
    func testServerStopsFallingBackAfterRepeatedFailures() {
        var health = WhisperServer.Health()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for attempt in 1..<WhisperServer.Health.maxConsecutiveFailures {
            guard case .fallBack = health.failed(at: start) else { return XCTFail("attempt \(attempt) should fall back") }
            XCTAssertFalse(health.waiting(now: start))
        }
        guard case .broken(let failures) = health.failed(at: start) else { return XCTFail("the last failure breaks it") }
        XCTAssertEqual(failures, WhisperServer.Health.maxConsecutiveFailures)
        XCTAssertTrue(health.waiting(now: start + 60))
        XCTAssertFalse(health.waiting(now: start + WhisperServer.retryAfter + 1), "tried again after the pause")
        health.succeeded()
        XCTAssertEqual(health, WhisperServer.Health())
    }

    func testTimeoutScalesWithTheChunk() {
        XCTAssertEqual(Transcriber.timeout(forSeconds: 30), 60)
        XCTAssertEqual(Transcriber.timeout(forSeconds: 2), 30)
        XCTAssertEqual(Transcriber.timeout(forSeconds: 120), 240)
    }

    func testServerReplyReadsLikeCLIOutput() throws {
        let json = try XCTUnwrap(WhisperServer.cliJSON(fromServer: Data(serverReply.utf8), requestedLanguage: "auto"))
        XCTAssertEqual(Transcriber.detectedLanguage(json: json), "pl")
        let speech = try Transcriber.parse(json: json, language: "pl")
        XCTAssertEqual(speech.map(\.text), ["Dobra, zaczynamy.", "Jasne."])
        XCTAssertEqual(speech[0].start, 0.31, accuracy: 0.001)
        XCTAssertEqual(speech[0].end, 2.5, accuracy: 0.001)
        XCTAssertEqual(speech[0].words.map(\.text), ["Dobra,", "zaczynamy."])
        XCTAssertEqual(speech[0].words[1].start, 0.9, accuracy: 0.001)
    }

    func testPinnedLanguageAndErrors() throws {
        let json = try XCTUnwrap(WhisperServer.cliJSON(fromServer: Data(serverReply.utf8), requestedLanguage: "en"))
        XCTAssertEqual(Transcriber.detectedLanguage(json: json), "en", "a pinned language is reported as is, like whisper-cli")
        XCTAssertNil(WhisperServer.cliJSON(fromServer: Data(#"{"error":"failed to read audio"}"#.utf8), requestedLanguage: "auto"))
        XCTAssertNil(WhisperServer.cliJSON(fromServer: Data("not json".utf8), requestedLanguage: "auto"))
    }

    func testArgumentsMatchTheCLI() {
        let withVAD = WhisperServer.arguments(.init(model: "/m.bin", vadModel: "/vad.bin", threads: 4), port: 5000)
        XCTAssertEqual(withVAD[withVAD.firstIndex(of: "-bs")! + 1], "5", "the server defaults to greedy decoding; whisper-cli uses beam search")
        XCTAssertEqual(withVAD[withVAD.firstIndex(of: "--port")! + 1], "5000")
        XCTAssertEqual(withVAD[withVAD.firstIndex(of: "-vm")! + 1], "/vad.bin")
        XCTAssertTrue(withVAD.contains("--carry-initial-prompt"))
        XCTAssertFalse(WhisperServer.arguments(.init(model: "/m.bin", vadModel: nil, threads: 4), port: 5000).contains("--vad"))
    }

    func testFreePort() throws {
        let port = try XCTUnwrap(WhisperServer.freePort())
        XCTAssertGreaterThan(port, 1024)
    }

    /// Opt in with CHRUPIO_E2E=1; needs whisper-server and a downloaded model.
    func testServerTranscribesAndStops() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHRUPIO_E2E"] == "1", "set CHRUPIO_E2E=1")
        try XCTSkipIf(WhisperServer.findWhisperServer() == nil, "whisper-server not installed")
        let model = try XCTUnwrap(WhisperModel.all.first { $0.name == "small" && $0.isDownloaded } ?? WhisperModel.all.first { $0.isDownloaded })

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chrupio-server-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("speech.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", wav.path, "--data-format=LEI16@16000", "We decided to ship the new billing page on Friday."]
        try say.run()
        say.waitUntilExit()

        let server = WhisperServer()
        let configuration = WhisperServer.Configuration(model: model.localURL.path, vadModel: nil, threads: 4)
        guard case .served(let json) = await server.transcribe(wav: wav, configuration: configuration, language: "en", prompt: nil, timeout: 120) else {
            return XCTFail("whisper-server didn't answer")
        }
        let text = try Transcriber.parse(json: json, language: "en").map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("billing"), text)
        server.terminate()
    }
}
