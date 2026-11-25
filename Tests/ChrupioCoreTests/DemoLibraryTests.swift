import ChrupioCore
import XCTest

/// Writes a fictional library for screenshots: CHRUPIO_DEMO_OUT=<dir>/meetings swift test --filter DemoLibraryTests
/// Every name, company and meeting here is made up.
final class DemoLibraryTests: XCTestCase {
    func testWriteDemoLibrary() throws {
        guard let out = ProcessInfo.processInfo.environment["CHRUPIO_DEMO_OUT"] else { throw XCTSkip("CHRUPIO_DEMO_OUT not set") }
        // Resolved and case-insensitive, as APFS is by default: a symlink or "chrupio" must not reach the real library.
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppPaths.folderName).resolvingSymlinksInPath().path.lowercased()
        guard !URL(fileURLWithPath: out).resolvingSymlinksInPath().path.lowercased().hasPrefix(real) else {
            return XCTFail("never the real library")
        }
        let store = MeetingStore(root: URL(fileURLWithPath: out, isDirectory: true))
        let now = Date()

        func meeting(_ title: String, _ platform: Platform, hoursAgo: Double, minutes: Double, attendees: [String],
                     lines: [(Speaker, String)], summary: String) -> Meeting {
            let start = now.addingTimeInterval(-hoursAgo * 3_600)
            let step = minutes * 60 / Double(max(lines.count, 1))
            // Who the call named as talking; without it the meeting page explains why voices are numbered.
            let events = lines.enumerated().compactMap { index, line -> SpeakerEvent? in
                guard case .remote(let name?) = line.0 else { return nil }
                return SpeakerEvent(time: Double(index) * step, names: [name])
            }
            return Meeting(
                title: title, platform: platform, startedAt: start, endedAt: start + minutes * 60,
                attendees: attendees, selfName: "Alex Kim", url: nil,
                segments: lines.enumerated().map { index, line in
                    TranscriptSegment(start: Double(index) * step, end: Double(index) * step + step * 0.8, speaker: line.0, text: line.1)
                },
                speakerEvents: events,
                summary: MeetingSummary(markdown: summary, model: "claude-haiku-4-5", createdAt: start + minutes * 60 + 120),
                status: .done
            )
        }

        let priya = Speaker.remote("Priya Shah"), tom = Speaker.remote("Tom Berg"), dana = Speaker.remote("Dana Wu")
        var billing = meeting("Billing launch sync", .meet, hoursAgo: 1, minutes: 42,
                              attendees: ["Alex Kim", "Priya Shah", "Tom Berg", "Dana Wu"],
                              lines: [(.me, "Morning everyone. The one question today: can we ship the new invoices on Monday?"),
                                      (priya, "Yes, if the tax rounding is fixed by Friday. That's the only blocker on my list."),
                                      (tom, "I'll take the rounding fix. It's rounding per invoice instead of per line."),
                                      (.me, "How big is the change?"),
                                      (tom, "Small. One function and its tests. The risk is old invoices, so I'll leave those alone."),
                                      (dana, "Support will want to know what changes for customers who already paid."),
                                      (priya, "Nothing changes for paid invoices. Only new ones use the new layout."),
                                      (.me, "Good. Can we keep the old PDF layout around for a while?"),
                                      (priya, "One more month, behind a setting. Then we remove it."),
                                      (dana, "I can write the help article this week if someone sends me screenshots."),
                                      (tom, "I'll send them once the fix is on staging."),
                                      (.me, "What about the pricing page? It still shows the old totals."),
                                      (priya, "Already updated. It went out yesterday afternoon."),
                                      (dana, "Do we email customers about the new invoices?"),
                                      (.me, "A short note in the monthly update is enough. No separate email."),
                                      (tom, "One more thing: the export to the accounting tool uses the same rounding."),
                                      (priya, "Then the export needs the fix too, or the totals won't match."),
                                      (tom, "Same function, so it's covered. I'll add a test for the export."),
                                      (.me, "Great. Anything that could still push us past Monday?"),
                                      (dana, "Only if the help article isn't reviewed in time. I'll ask for a review on Thursday."),
                                      (priya, "I can review it Thursday afternoon."),
                                      (tom, "Staging deploy is Wednesday evening, so screenshots on Thursday morning."),
                                      (.me, "So: rounding fix by Friday, help article Thursday, launch Monday."),
                                      (priya, "And the old layout stays for one month."),
                                      (dana, "I'll tell the support team in tomorrow's stand-up."),
                                      (.me, "Then Monday it is. I'll brief support on the launch myself as well."),
                                      (tom, "I'll post in the channel when the fix is merged."),
                                      (.me, "Thanks, everyone. Short call today.")],
                              summary: """
                              ## Summary
                              The team agreed to launch the new invoices on Monday, provided the tax rounding fix lands by Friday.

                              ## Decisions
                              - Launch new invoices on Monday
                              - Keep the old PDF layout for one more month

                              ## Action items
                              - [ ] Tom Berg: fix tax rounding, including the accounting export (Friday)
                              - [ ] Dana Wu: write the help article (Thursday)
                              - [ ] Alex Kim: brief support on the launch
                              - [x] Priya Shah: update the pricing page
                              """)
        billing.notes = [MeetingNote(createdAt: now.addingTimeInterval(-20 * 60), author: "Claude Code", text: """
            Rounding fix is up for review: invoice totals now round per line, not per invoice.

            - [x] Reproduced the rounding bug on staging
            - [ ] Merge after review

            [Pull request 212](https://example.com/billing/pull/212)
            """)]
        try store.save(billing)
        try store.save(meeting("Pricing review", .zoom, hoursAgo: 26, minutes: 35, attendees: ["Alex Kim", "Dana Wu"],
                               lines: [(dana, "Annual plans need a clearer discount."), (.me, "Let's test 15 percent.")],
                               summary: "## Summary\nTesting a 15% annual discount.\n\n## Action items\n- [ ] Dana Wu: set up the pricing test"))
        try store.save(meeting("Hiring loop debrief", .slack, hoursAgo: 50, minutes: 18, attendees: ["Alex Kim", "Sam Ortiz"],
                               lines: [(.remote("Sam Ortiz"), "Strong systems interview."), (.me, "Agreed, let's move to an offer.")],
                               summary: "## Summary\nMoving the backend candidate to an offer.\n\n## Action items\n- [ ] Sam Ortiz: draft the offer"))
        try store.save(meeting("Weekly product sync with a long title that must truncate in narrow places", .teams, hoursAgo: 75, minutes: 55,
                               attendees: ["Alex Kim", "Priya Shah", "Dana Wu", "Tom Berg"],
                               lines: [(.me, "Roadmap check."), (priya, "Billing is on track.")],
                               summary: "## Summary\nRoadmap on track; billing first.\n\n## Action items\n- [x] Alex Kim: share the roadmap"))
        try store.save(meeting("Supplier check-in", .other, hoursAgo: 24 * 6, minutes: 22, attendees: ["Alex Kim", "Lena Fischer"],
                               lines: [(.remote("Lena Fischer"), "The new paper stock arrives next week."), (.me, "Then we print on Tuesday.")],
                               summary: "## Summary\nPaper stock arrives next week; printing moves to Tuesday.\n\n## Action items\n- [ ] Lena Fischer: confirm the delivery date"))
        try store.save(meeting("Customer call: Harbor & Pine", .meet, hoursAgo: 24 * 12, minutes: 30, attendees: ["Alex Kim", "Omar Haddad"],
                               lines: [(.remote("Omar Haddad"), "We need single sign-on before rollout."), (.me, "Single sign-on ships next month.")],
                               summary: "## Summary\nHarbor & Pine waits for single sign-on.\n\n## Action items\n- [ ] Alex Kim: send the single sign-on timeline"))
        XCTAssertEqual(store.loadAll().count, 6)
    }
}
