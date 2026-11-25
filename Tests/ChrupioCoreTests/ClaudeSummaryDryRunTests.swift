import XCTest
@testable import ChrupioCore

/// Summarizes copies of real meetings with the real Claude CLI, writing the Markdown next to them. Skipped unless
/// CHRUPIO_DRYRUN_DIR names a folder of meeting JSON files; CHRUPIO_DRYRUN_CONTEXT, _OUT and _MODEL are optional.
final class ClaudeSummaryDryRunTests: XCTestCase {
    func testDryRun() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["CHRUPIO_DRYRUN_DIR"] else { throw XCTSkip("set CHRUPIO_DRYRUN_DIR to run") }
        let out = URL(fileURLWithPath: env["CHRUPIO_DRYRUN_OUT"] ?? dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let context = env["CHRUPIO_DRYRUN_CONTEXT"].flatMap { MeetingContext.load(from: URL(fileURLWithPath: $0)) }
        let executable = try XCTUnwrap(ClaudeSummarizer.findExecutable())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".json") }.sorted()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for file in files {
                group.addTask {
                    let meeting = try decoder.decode(Meeting.self, from: Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(file)))
                    let transcript = TranscriptFormatter.plainText(meeting.segments)
                    let summarizer = ClaudeSummarizer(executable: executable, model: env["CHRUPIO_DRYRUN_MODEL"] ?? ClaudeSummarizer.defaultModel,
                                                      configDir: env["CHRUPIO_DRYRUN_CONFIG_DIR"],
                                                      context: context?.summaryPrompt(for: meeting, transcript: transcript))
                    let name = (file as NSString).deletingPathExtension
                    try summarizer.input(for: meeting).write(to: out.appendingPathComponent(name + ".prompt.txt"), atomically: true, encoding: .utf8)
                    let started = Date()
                    let summary = try await summarizer.summarize(meeting)
                    let seconds = Int(Date().timeIntervalSince(started))
                    try (summary.markdown + "\n\n<!-- \(summary.model), \(seconds) s -->\n")
                        .write(to: out.appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8)
                    XCTAssertTrue(summary.markdown.contains("\n## Action items\n"))
                }
            }
            try await group.waitForAll()
        }
    }
}
