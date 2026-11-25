import Foundation
@testable import ChrupioCore
import XCTest

final class SafeLinkTests: XCTestCase {
    func testOnlyWebLinksWithAHostAreAllowed() {
        for good in ["https://meet.google.com/abc-defg-hij", "http://example.com", "HTTPS://Teams.Microsoft.com/l/x",
                     "  https://zoom.us/j/1 \n", "HtTp://example.com/a?b=c#d"] {
            XCTAssertNotNil(SafeLink.url(good), good)
        }
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "JavaScript:alert(1)", " javascript:alert(1)",
                    "data:text/html,<script>alert(1)</script>", "x-apple.systempreferences:com.apple.preference",
                    "zoommtg://zoom.us/join", "chrupio://open", "ssh://host", "ftp://example.com", "https://", "http:example.com",
                    "mailto:a@b.c", "", "   ", "not a url", "/Users/x/a.txt"] {
            XCTAssertNil(SafeLink.url(bad), bad)
        }
        XCTAssertNil(SafeLink.url(nil))
    }

    func testIsAllowedChecksSchemeAndHost() {
        XCTAssertTrue(SafeLink.isAllowed(URL(string: "https://example.com")!))
        XCTAssertFalse(SafeLink.isAllowed(URL(string: "file:///tmp/a")!))
        XCTAssertFalse(SafeLink.isAllowed(URL(string: "x-apple.systempreferences:com.apple.preference.security")!))
        XCTAssertFalse(SafeLink.isAllowed(URL(fileURLWithPath: "/tmp/a")))
    }

    func testUserOrPasswordInTheLinkIsRefused() {
        for bad in ["https://google.com@evil.com", "https://google.com:443@evil.com/login", "https://user:pass@example.com",
                    "https://:pass@example.com", "https://@example.com", "http://a%40b@evil.com"] {
            XCTAssertNil(SafeLink.url(bad), bad)
            if let url = URL(string: bad) { XCTAssertFalse(SafeLink.isAllowed(url), bad) }
        }
    }

    func testBackslashFormsAreRefused() {
        for bad in [#"http:\\evil.com"#, #"https:/\evil.com"#, #"https:\/evil.com"#, #"http:\evil.com"#] {
            XCTAssertNil(SafeLink.url(bad), bad)
        }
    }

    func testInvisiblePrefixesNeverLetAnotherSchemeThrough() {
        for bad in ["\u{200B}javascript:alert(1)", "\u{FEFF}javascript:alert(1)", "\u{00A0}javascript:alert(1)",
                    "\u{200B}file:///etc/passwd", "java\u{200B}script:alert(1)"] {
            XCTAssertNil(SafeLink.url(bad), bad.debugDescription)
        }
        // A zero-width character in front of a web link either fails or still yields a plain web link; never something else.
        for odd in ["\u{200B}https://example.com", "\u{00A0}https://example.com"] {
            if let url = SafeLink.url(odd) {
                XCTAssertEqual(url.scheme?.lowercased(), "https", odd.debugDescription)
                XCTAssertEqual(url.host, "example.com", odd.debugDescription)
            }
        }
    }

    func testPercentEncodedSchemeIsRefused() {
        for bad in ["%6Aavascript:alert(1)", "%68ttps://evil.com", "https%3A%2F%2Fevil.com", "javascript%3Aalert(1)"] {
            XCTAssertNil(SafeLink.url(bad), bad)
        }
    }

    func testIPv6AndPortsAreAllowed() {
        XCTAssertNotNil(SafeLink.url("http://[::1]:8080/"))
        XCTAssertNotNil(SafeLink.url("https://[2001:db8::1]/path"))
        XCTAssertNotNil(SafeLink.url("https://example.com:8443/x"))
    }

    // MARK: - Links inside rendered Markdown

    private func links(_ markdown: String) -> [(text: String, url: URL)] {
        let parsed = try! AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let clean = SafeLink.sanitized(parsed)
        return clean.runs[\.link].compactMap { link, range in link.map { (String(clean[range].characters), $0) } }
    }

    func testSanitizedKeepsWebLinksAndDropsOtherSchemes() {
        let kept = links("See [the doc](https://docs.example.com/a) and [notes](file:///etc/passwd) and [x](javascript:alert(1)).")
        XCTAssertEqual(kept.map(\.text), ["the doc"])
        XCTAssertEqual(kept.first?.url.absoluteString, "https://docs.example.com/a")
        XCTAssertTrue(links("[login](https://google.com@evil.com)").isEmpty)
    }

    func testSanitizedKeepsTheVisibleText() {
        let parsed = try! AttributedString(markdown: "Open [settings](x-apple.systempreferences:com.apple) now",
                                           options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let clean = SafeLink.sanitized(parsed)
        XCTAssertEqual(String(clean.characters), "Open settings now")
        XCTAssertTrue(clean.runs[\.link].allSatisfy { $0.0 == nil })
    }

    func testTextThatLooksLikeAnotherAddressLosesItsLink() {
        for spoof in ["[https://bank.com](https://evil.com)", "[bank.com](https://evil.com)", "[www.bank.com](https://evil.com)",
                      "[https://bank.com/login](https://bank.com.evil.com/login)", "[BANK.COM/login](http://evil.com)",
                      "[**bank**.com](https://evil.com)", "[bank.com:443](https://evil.com)"] {
            XCTAssertTrue(links(spoof).isEmpty, spoof)
        }
    }

    func testFileNamesAndDottedNamesKeepTheirLink() {
        for fine in ["[Node.js](https://nodejs.org)", "[README.md](https://github.com/x/y/blob/main/README.md)",
                     "[design.pdf](https://drive.example.com/d/1)", "[main.swift](https://example.com/a)", "[setup.sh](https://example.com/s)",
                     "[report.docx](https://example.com/r)", "[data.csv](https://example.com/c)", "[clip.mp4](https://example.com/v)",
                     "[Vue.js](https://vuejs.org)", "[notes.txt.](https://example.com/n)",
                     // Known trade-off: a bare name with an ending outside the list reads as text.
                     "[bank.local](https://evil.com)"] {
            XCTAssertEqual(links(fine).count, 1, fine)
        }
    }

    func testAddressShapedTextLosesItsLink() {
        // A known top-level domain on its own, or any ending once there's a path, port, `www.` or `://`.
        for spoof in ["[example.io](https://evil.com)", "[bank.pl](https://evil.com)", "[gov.uk](https://evil.com)",
                      "[bank.xyz/login](https://evil.com)", "[bank.xyz:8443](https://evil.com)", "[www.bank.xyz](https://evil.com)",
                      "[ftp://bank.xyz](https://evil.com)"] {
            XCTAssertTrue(links(spoof).isEmpty, spoof)
        }
    }

    func testPunctuationAndInvisibleCharactersDontHideAnAddress() {
        for spoof in ["[bank.com.](https://evil.com)", "[(bank.com)](https://evil.com)", "[\"bank.com\"](https://evil.com)",
                      "[bank.com!](https://evil.com)", "[[bank.com]](https://evil.com)", "[bank\u{200B}.com](https://evil.com)",
                      "[\u{FEFF}bank.com](https://evil.com)", "[bank\u{2060}.com](https://evil.com)", "[bank。com](https://evil.com)",
                      "[bank．com](https://evil.com)", "[bank｡com](https://evil.com)"] {
            XCTAssertTrue(links(spoof).isEmpty, spoof.debugDescription)
        }
        for fine in ["[bank.com.](https://bank.com)", "[(bank。com)](https://bank.com)", "[bank\u{200B}.com](https://bank.com)"] {
            XCTAssertEqual(links(fine).count, 1, fine.debugDescription)
        }
    }

    func testNoKnownDomainEndingIsAlsoACommonFileExtension() {
        XCTAssertTrue(SafeLink.addressEndings.isDisjoint(with: SafeLink.fileExtensions))
    }

    func testMatchingOrPlainTextKeepsItsLink() {
        for fine in ["[https://bank.com/login](https://bank.com/other)", "[bank.com](https://bank.com)",
                     "[www.bank.com](https://bank.com)", "[Bank.COM](https://www.bank.com/x)", "<https://example.com/a>",
                     "[the agenda](https://docs.example.com/a)", "[Q3 plan v1.2](https://example.com)", "[e.g. this](https://example.com)"] {
            XCTAssertEqual(links(fine).count, 1, fine)
        }
    }
}
