import AppKit
import CoreText
import ChrupioCore
import SwiftUI

/// D1 brutalist tokens, light only: white, black and one orange, plus greys for secondary text.
/// Orange is a fill behind black text, or a mark on black; never orange text on white.
/// The nested `Color` enum below shadows SwiftUI's `Color` inside `Theme`, so tokens here spell out `SwiftUI.Color`.
enum Theme {
    static let ink = SwiftUI.Color(hex: 0x000000)
    static let surface = SwiftUI.Color.white
    /// Fills only: chips, toggles, the recording panel, button shadows on black.
    static let accent = SwiftUI.Color(hex: 0xFF5B1F)
    /// Secondary text, 7.5:1 on white.
    static let muted = SwiftUI.Color(hex: 0x555555)
    /// Tertiary text (timestamps, footnotes), 4.54:1 on white.
    static let faint = SwiftUI.Color(hex: 0x767676)
    /// Done and pressed rows.
    static let tile = SwiftUI.Color(hex: 0xF3F3F3)
    /// Unlit meter segments.
    static let track = ink.opacity(0.13)

    /// The one allowed exception to the D1 palette: red, for errors and the recording markers only.
    /// Used as text or icon colour on white (6.6:1), never as a fill.
    enum Color {
        static let error = SwiftUI.Color(hex: 0xB42318)
    }

    enum Border {
        static let regular: CGFloat = 3
        static let heavy: CGFloat = 4
        static let frame: CGFloat = 5
    }

    enum Shadow {
        static let small: CGFloat = 3
        static let regular: CGFloat = 4
        static let large: CGFloat = 8
    }

    // MARK: Type: IBM Plex Mono everywhere, Regular and Bold.

    static let regularFontName = "IBMPlexMono"
    static let boldFontName = "IBMPlexMono-Bold"

    /// Registers the bundled faces once; false means every font falls back to the system monospaced face.
    static let hasPlex: Bool = {
        for folder in fontFolders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension.lowercased() == "ttf" {
                CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
            }
        }
        return NSFont(name: regularFontName, size: 12) != nil && NSFont(name: boldFontName, size: 12) != nil
    }()

    /// Inside the .app (scripts/build-app.sh copies Fonts to Contents/Resources) or next to a `swift build` binary.
    /// Not `Bundle.module`: its accessor stops the app when the SwiftPM bundle isn't beside the executable.
    static var fontFolders: [URL] {
        let main = Bundle.main
        return [
            main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true),
            main.bundleURL.appendingPathComponent("Chrupio_Chrupio.bundle/Contents/Resources/Fonts", isDirectory: true),
            main.bundleURL.appendingPathComponent("Chrupio_Chrupio.bundle/Fonts", isDirectory: true),
        ]
        .compactMap { $0 }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func registerFonts() { _ = hasPlex }

    /// Semibold and heavier map to Bold; everything else to Regular.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let bold = [Font.Weight.semibold, .bold, .heavy, .black].contains(weight)
        guard hasPlex else { return .system(size: size, weight: bold ? .bold : .regular, design: .monospaced) }
        return .custom(bold ? boldFontName : regularFontName, fixedSize: size)
    }

    static func heading(_ size: CGFloat) -> Font { font(size, .bold) }

    static let body = font(14)
    static let label = font(12, .bold)
    static let caption = font(12)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

// MARK: - Surfaces

extension View {
    /// A square panel: fill, black border, hard offset shadow with no blur. Pads trailing and bottom by the shadow
    /// so the shadow is part of the layout and never clipped.
    func brutalistPanel(fill: Color = Theme.surface, border: CGFloat = Theme.Border.heavy, shadow: CGFloat = Theme.Shadow.regular,
                        shadowColor: Color = Theme.ink, padding: CGFloat = 20) -> some View {
        self.padding(padding)
            .background(fill)
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: border))
            .background(Rectangle().fill(shadowColor).offset(x: shadow, y: shadow))
            .padding(.trailing, shadow)
            .padding(.bottom, shadow)
    }

    /// White bold capitals on a black strip: section headings such as "Recent" or "Today".
    func sectionLabel() -> some View {
        font(Theme.font(11, .bold))
            .textCase(.uppercase)
            .tracking(1)
            .foregroundStyle(Theme.surface)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.ink)
    }

    /// Bold capitals inside a bordered box: status words, platform names, check results.
    /// `uppercase: false` keeps names in normal case (the "You" speaker chip).
    func tagChip(_ kind: TagChip.Kind = .plain, size: CGFloat = 11, uppercase: Bool = true) -> some View {
        font(Theme.font(size, .bold))
            .textCase(uppercase ? .uppercase : nil)
            .tracking(0.5)
            .lineLimit(1)
            .foregroundStyle(kind == .ink ? Theme.surface : Theme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(kind == .ink ? Theme.ink : kind == .accent ? Theme.accent : Theme.surface)
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.regular))
            .fixedSize()
    }

    /// A white box with a 3 pt black border, for text editors.
    func fieldBox() -> some View {
        padding(8)
            .background(Theme.surface)
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.regular))
    }

    /// The D1 keyboard focus indicator: a 3 pt orange outline 2 pt outside the border, drawn while the enclosing
    /// button or control has keyboard focus. Use inside a ButtonStyle body or a Button label, and turn off the
    /// system ring on that control (`.focusEffectDisabled()`). `inset` draws it inside the border instead, for cells
    /// that sit flush against something.
    func focusRing(inset: Bool = false) -> some View { modifier(FocusRing(inset: inset)) }

    func cardTitle() -> some View { font(Theme.heading(16)).textCase(.uppercase).foregroundStyle(Theme.ink) }
    func secondaryText() -> some View { modifier(SecondaryText()) }
}

private struct FocusRing: ViewModifier {
    let inset: Bool
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.overlay {
            if isFocused {
                Rectangle()
                    .strokeBorder(Theme.accent, lineWidth: 3)
                    .padding(inset ? Theme.Border.regular : -5)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Grey secondary text; black under Increase Contrast.
private struct SecondaryText: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.font(Theme.caption).foregroundStyle(contrast == .increased ? Theme.ink : Theme.muted)
    }
}

struct TagChip: View {
    enum Kind { case plain, ink, accent }
    let text: String
    var kind: Kind = .plain
    var size: CGFloat = 11

    var body: some View { Text(text).tagChip(kind, size: size) }
}

/// A titled settings panel.
struct SettingsCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title { Text(title).font(Theme.heading(20)).textCase(.uppercase).foregroundStyle(Theme.ink) }
            content
        }
        .font(Theme.body)
        .foregroundStyle(Theme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brutalistPanel()
    }
}

/// Label on the left, control on the right. `uppercase: false` keeps tool names and file paths in normal case.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    var uppercase = true
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.label).textCase(uppercase ? .uppercase : nil).foregroundStyle(Theme.ink)
                if let detail { Text(detail).secondaryText().fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            control
        }
    }
}

// MARK: - Controls

/// Square button with a 3 pt border and a hard shadow that shrinks while pressed.
struct BrutalistButtonStyle: ButtonStyle {
    enum Kind { case plain, ink, accent }
    var kind: Kind = .plain
    var fullWidth = false
    var compact = false
    /// Defaults to orange behind black buttons and black behind the others.
    var shadowColor: Color?

    func makeBody(configuration: Configuration) -> some View {
        ButtonFace(configuration: configuration, style: self)
    }

    fileprivate var shadow: CGFloat { compact ? Theme.Shadow.small : kind == .ink ? Theme.Shadow.regular + 1 : Theme.Shadow.regular }
    fileprivate var resolvedShadowColor: Color { shadowColor ?? (kind == .ink ? Theme.accent : Theme.ink) }

    private struct ButtonFace: View {
        let configuration: Configuration
        let style: BrutalistButtonStyle
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            let shadow = pressed ? 1 : style.shadow
            configuration.label
                .font(Theme.font(style.compact ? 12 : 13, .bold))
                .textCase(.uppercase)
                .tracking(0.5)
                .lineLimit(1)
                .foregroundStyle(style.kind == .ink ? Theme.surface : Theme.ink)
                .padding(.horizontal, style.compact ? 12 : 16)
                .frame(minHeight: style.compact ? 30 : 38)
                .frame(maxWidth: style.fullWidth ? .infinity : nil)
                .background(fill(pressed: pressed))
                .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.regular))
                .focusRing()
                .background(Rectangle().fill(style.resolvedShadowColor).offset(x: shadow, y: shadow))
                .padding(.trailing, style.shadow)
                .padding(.bottom, style.shadow)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .focusEffectDisabled()
        }

        private func fill(pressed: Bool) -> Color {
            switch style.kind {
            case .plain: pressed ? Theme.tile : Theme.surface
            case .ink: Theme.ink
            case .accent: Theme.accent
            }
        }
    }
}

/// A 16 pt square radio mark: black when selected. Shows the D1 focus ring when it has keyboard focus.
/// Disabled, the border and fill turn `Theme.faint` grey (4.54:1 on white, above the 3:1 needed for a control edge).
struct SquareRadioButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        RadioMark(isSelected: isSelected)
    }

    private struct RadioMark: View {
        let isSelected: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let edge = isEnabled ? Theme.ink : Theme.faint
            Rectangle()
                .fill(isSelected ? edge : Theme.surface)
                .frame(width: 16, height: 16)
                .overlay(Rectangle().strokeBorder(edge, lineWidth: Theme.Border.regular))
                .focusRing()
                .contentShape(Rectangle())
                .focusEffectDisabled()
        }
    }
}

extension ButtonStyle where Self == BrutalistButtonStyle {
    static var brutalist: BrutalistButtonStyle { BrutalistButtonStyle() }
    static var brutalistInk: BrutalistButtonStyle { BrutalistButtonStyle(kind: .ink) }
    static var brutalistAccent: BrutalistButtonStyle { BrutalistButtonStyle(kind: .accent) }
    static var brutalistCompact: BrutalistButtonStyle { BrutalistButtonStyle(compact: true) }
}

/// Square icon button for footers.
struct SquareIconButtonStyle: ButtonStyle {
    var size: CGFloat = 38

    func makeBody(configuration: Configuration) -> some View {
        let shadow = configuration.isPressed ? 1 : Theme.Shadow.small
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Theme.ink)
            .frame(width: size, height: size)
            .background(configuration.isPressed ? Theme.tile : Theme.surface)
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.regular))
            .focusRing()
            .background(Rectangle().fill(Theme.ink).offset(x: shadow, y: shadow))
            .padding(.trailing, Theme.Shadow.small)
            .padding(.bottom, Theme.Shadow.small)
            .contentShape(Rectangle())
            .focusEffectDisabled()
    }
}

/// Square switch: orange with the black knob on the right when on, white with the knob on the left when off.
/// Like a native Toggle, the whole row (label and switch) flips it, Space flips it when it has keyboard focus,
/// and VoiceOver reads it as a switch with its on/off value.
struct BrutalistToggleStyle: ToggleStyle {
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        BrutalistToggle(configuration: configuration, small: small)
    }

    private struct BrutalistToggle: View {
        let configuration: Configuration
        let small: Bool
        @FocusState private var focused: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let width: CGFloat = small ? 38 : 46
            let height: CGFloat = small ? 22 : 26
            let knob: CGFloat = small ? 12 : 16
            HStack(spacing: 10) {
                configuration.label
                Spacer(minLength: 0)
                Rectangle()
                    .fill(configuration.isOn ? Theme.accent : Theme.surface)
                    .frame(width: width, height: height)
                    .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.regular))
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Rectangle().fill(Theme.ink).frame(width: knob, height: knob).padding(.horizontal, (height - knob) / 2)
                    }
                    .overlay {
                        if focused {
                            Rectangle().strokeBorder(Theme.accent, lineWidth: 3).padding(-5).allowsHitTesting(false)
                        }
                    }
                    .animation(.easeOut(duration: 0.12), value: configuration.isOn)
            }
            .contentShape(Rectangle())
            .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
            .focusable(isEnabled, interactions: .activate)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.space) {
                guard isEnabled else { return .ignored }
                configuration.isOn.toggle()
                return .handled
            }
            .accessibilityRepresentation {
                // A system style here: this style in the representation would build its own representation again.
                Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
            }
        }
    }
}

extension ToggleStyle where Self == BrutalistToggleStyle {
    static var brutalist: BrutalistToggleStyle { BrutalistToggleStyle() }
}

/// Bordered tabs; the selected one is black with white capitals.
struct SegmentedSwitch<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.value) { index, option in
                let isOn = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(Theme.font(13, .bold))
                        .textCase(.uppercase)
                        .foregroundStyle(isOn ? Theme.surface : Theme.ink)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 34)
                        .frame(maxWidth: .infinity)
                        .background(isOn ? Theme.ink : Theme.surface)
                        // Inset: segments sit flush against each other and the outer border.
                        .focusRing(inset: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityAddTraits(isOn ? .isSelected : [])
                if index < options.count - 1 {
                    Rectangle().fill(Theme.ink).frame(width: Theme.Border.regular)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.regular))
    }
}

/// A menu picker drawn as a square field.
struct MenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button(option.title) { selection = option.value }
            }
        } label: {
            HStack(spacing: 8) {
                Text(options.first { $0.value == selection }?.title ?? "\(selection)")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(Theme.font(13, .bold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(Theme.surface)
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.regular))
            .focusRing()
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .focusEffectDisabled()
        .fixedSize()
    }
}

/// A text field drawn as a square field.
struct FieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(Theme.font(13))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(Theme.surface)
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.regular))
    }
}

/// Status with a word, never colour alone. Same API as before; drawn as a chip.
struct StatusPill: View {
    enum Kind { case ok, warning, error, neutral }
    let text: String
    var kind: Kind = .neutral
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            } else {
                Text(marker)
            }
            Text(text)
        }
        // Set before tagChip: the innermost foreground wins, so errors stay red inside the black border.
        .foregroundStyle(kind == .error ? Theme.Color.error : Theme.ink)
        .tagChip(chip)
    }

    private var marker: String {
        switch kind {
        case .ok: "■"
        case .warning: "!"
        case .error: "×"
        case .neutral: "–"
        }
    }

    private var chip: TagChip.Kind {
        switch kind {
        case .ok: .accent
        case .warning, .neutral, .error: .plain
        }
    }
}

/// A short message in a bordered box. Errors keep red text and icon on white.
struct NoteView: View {
    enum Kind { case info, warning, error }
    let text: String
    var kind: Kind = .info
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind == .error ? "exclamationmark.circle" : kind == .warning ? "exclamationmark.triangle" : "info.circle")
                .font(.system(size: 13, weight: .bold))
                .padding(.top, 1)
            Text(text)
                .font(Theme.font(13))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).focusRing() }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
            }
        }
        .foregroundStyle(kind == .error ? Theme.Color.error : Theme.ink)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.regular))
    }
}

/// A command the user copies into Terminal: white on black.
struct CommandText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.font(12))
            .foregroundStyle(Theme.surface)
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.ink)
    }
}

/// "Copy" puts the text on the clipboard and reads "Copied" for two seconds; another click restarts the two seconds.
/// Sits on black: a white cell with a black border and no shadow, so it reads as the COPY cell of d1-onboarding.
/// `fillsHeight` stretches the cell to the height of its row, for bars that wrap it flush.
struct CopyButton: View {
    let text: String
    var help = "Copy"
    var fillsHeight = false
    @State private var copies = 0

    var body: some View {
        Button(copies > 0 ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copies += 1
            AccessibilityNotification.Announcement("Copied").post()
        }
        .buttonStyle(CopyCellStyle(fillsHeight: fillsHeight))
        .help(help)
        .task(id: copies) {
            guard copies > 0 else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copies = 0
        }
    }

    private struct CopyCellStyle: ButtonStyle {
        let fillsHeight: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(Theme.font(12, .bold))
                .textCase(.uppercase)
                .tracking(0.5)
                .lineLimit(1)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .frame(minHeight: 30, maxHeight: fillsHeight ? .infinity : nil)
                .background(configuration.isPressed ? Theme.tile : Theme.surface)
                .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.Border.regular))
                .focusRing(inset: true)
                .contentShape(Rectangle())
                .focusEffectDisabled()
        }
    }
}

/// A Terminal command in white on black after an orange "$", with a Copy cell flush at the right (d1-onboarding).
/// The "$" is not part of the copied or selectable text.
struct CopyableCommand: View {
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("$")
                    .font(Theme.font(13, .bold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(text)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.surface)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 12)
            .padding(.vertical, 10)
            Spacer(minLength: 10)
            CopyButton(text: text, help: "Copy the command", fillsHeight: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ink)
    }
}

/// Segmented meter or progress bar: black segments lit, grey unlit.
struct LevelBar: View {
    let value: Double
    var segments = 12
    var track: Color = Theme.track
    var fill: Color = Theme.ink
    var height: CGFloat = 8

    var body: some View {
        let lit = Int((min(1, max(0, value)) * Double(segments)).rounded(.up))
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                Rectangle().fill(index < lit ? fill : track)
            }
        }
        .frame(height: height)
    }
}

extension Date {
    /// The Mac's region may default to another calendar (Thailand: Buddhist year 2569); notes always show Gregorian years.
    static let displayCalendar = Calendar(identifier: .gregorian)

    func shown(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        var style = Date.FormatStyle(date: date, time: time)
        style.calendar = Self.displayCalendar
        return formatted(style)
    }

    /// "Mon 13, 14:30": day and time for rows under a month heading, which already names month and year.
    var shownDayAndTime: String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().hour().minute()
        style.calendar = Self.displayCalendar
        return formatted(style)
    }

    var shownMonthYear: String {
        var style = Date.FormatStyle.dateTime.month(.wide).year()
        style.calendar = Self.displayCalendar
        return formatted(style)
    }
}
