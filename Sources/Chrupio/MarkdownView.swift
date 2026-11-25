import ChrupioCore
import SwiftUI

/// Renders the small Markdown subset the summaries use: headings, bullets, checkboxes, paragraphs.
struct MarkdownView: View {
    let markdown: String
    /// Called with the action item's number (as `ActionItem` counts them) and its new state; nil makes checkboxes read-only.
    var onToggle: ((Int, Bool) -> Void)? = nil
    /// True on the orange note cards, where the muted greys don't read: done items stay ink.
    var onAccent = false

    var body: some View {
        let blocks = MarkdownBlock.parse(markdown)
        let numbers = MarkdownBlock.taskNumbers(blocks)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let level, let text):
                    Text(inline(text))
                        .font(Theme.heading(level <= 2 ? 15 : 14)).textCase(.uppercase).tracking(0.5)
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 12)
                case .bullet(let text, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Rectangle().fill(Theme.ink).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        Text(inline(text)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(indent) * 16)
                case .task(let text, let done):
                    let toggle: (() -> Void)? = onToggle.flatMap { onToggle in numbers[index].map { number in { onToggle(number, !done) } } }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let toggle {
                            Button(action: toggle) { checkbox(done).focusRing() }
                                .buttonStyle(.plain)
                                .focusEffectDisabled()
                                .help(done ? "Mark as open" : "Mark as done")
                        } else {
                            checkbox(done)
                        }
                        Text(inline(text))
                            .strikethrough(done, color: onAccent ? Theme.ink : Theme.faint)
                            .foregroundStyle(done && !onAccent ? Theme.muted : Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityRepresentation {
                        Toggle(isOn: Binding(get: { done }, set: { _ in toggle?() })) { Text(inline(text)) }
                            .disabled(toggle == nil)
                    }
                    .accessibilityHint(toggle == nil ? "" : (done ? "Mark as open" : "Mark as done"))
                case .paragraph(let text):
                    Text(inline(text)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(Theme.font(14))
        .lineSpacing(3)
        .foregroundStyle(Theme.ink)
        // Links are ink and underlined, so they read on white and on the orange note cards.
        .tint(Theme.ink)
        .textSelection(.enabled)
        // A second check where the click lands, so no other scheme opens even if a link slips past `inline`.
        .environment(\.openURL, OpenURLAction { SafeLink.isAllowed($0) ? .systemAction : .discarded })
    }

    private func checkbox(_ done: Bool) -> some View {
        Rectangle()
            .fill(done ? Theme.ink : Theme.surface)
            .frame(width: 16, height: 16)
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.regular))
            .overlay {
                if done { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.accent) }
            }
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
    }

    private func inline(_ text: String) -> AttributedString {
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        // Summaries and notes come from what people said: only web links whose text doesn't name another address
        // stay clickable, the rest read as plain text.
        var result = SafeLink.sanitized(parsed)
        for (link, range) in result.runs[\.link] where link != nil {
            result[range].underlineStyle = .single
        }
        return result
    }
}

enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case bullet(String, indent: Int)
    case task(String, done: Bool)
    case paragraph(String)

    /// Action item numbers by block index; empty checklist lines aren't items, matching `ActionItem.parse`.
    static func taskNumbers(_ blocks: [MarkdownBlock]) -> [Int: Int] {
        var numbers: [Int: Int] = [:]
        for (index, block) in blocks.enumerated() {
            if case .task(let text, _) = block, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                numbers[index] = numbers.count + 1
            }
        }
        return numbers
    }

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for rawLine in markdown.components(separatedBy: .newlines) {
            let indent = rawLine.prefix { $0 == " " }.count / 2
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let match = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                blocks.append(.heading(match.1.count, String(match.2)))
            } else if let match = line.firstMatch(of: /^[-*+]\s+\[([ xX])\]\s*(.*)$/) {
                blocks.append(.task(String(match.2), done: match.1 != " "))
            } else if let match = line.firstMatch(of: /^(?:[-*+]|\d+[.)])\s+(.*)$/) {
                blocks.append(.bullet(String(match.1), indent: indent))
            } else if case .paragraph(let previous) = blocks.last {
                blocks[blocks.count - 1] = .paragraph(previous + " " + line)
            } else {
                blocks.append(.paragraph(line))
            }
        }
        return blocks
    }
}
