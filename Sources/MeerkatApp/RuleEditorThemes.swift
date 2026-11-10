import AppKit
import CodeEditSourceEditor
import SwiftUI

/// The rule editor's color themes, chosen in Settings or the View menu.
/// Most have a light and a dark variant and follow the app's appearance;
/// the rest are dark in both (`isDarkOnly`).
enum RuleEditorTheme: String, CaseIterable, Identifiable {
    case system, catppuccin, dracula, github, gruvbox, nord, one, solarized, tokyoNight

    /// `UserDefaults` key; a stored value this build doesn't know reads as
    /// the default, `.system`.
    static let defaultsKey = "editorTheme"

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .catppuccin: "Catppuccin"
        case .dracula: "Dracula"
        case .github: "GitHub"
        case .gruvbox: "Gruvbox"
        case .nord: "Nord"
        case .one: "One"
        case .solarized: "Solarized"
        case .tokyoNight: "Tokyo Night"
        }
    }

    var isDarkOnly: Bool {
        switch self {
        case .dracula, .nord: true
        case .system, .catppuccin, .github, .gruvbox, .one, .solarized, .tokyoNight: false
        }
    }

    func palette(_ scheme: ColorScheme) -> RuleEditorPalette {
        let dark = scheme == .dark
        return switch self {
        case .system: .system(scheme)
        case .catppuccin: dark ? .catppuccinMocha : .catppuccinLatte
        case .dracula: .dracula
        case .github: dark ? .githubDark : .githubLight
        case .gruvbox: dark ? .gruvboxDark : .gruvboxLight
        case .nord: .nord
        case .one: dark ? .oneDark : .oneLight
        case .solarized: dark ? .solarizedDark : .solarizedLight
        case .tokyoNight: dark ? .tokyoNight : .tokyoNightDay
        }
    }
}

/// One variant's colors. Upstream's `EditorTheme` has more roles than a
/// palette has colors: `attributes`, `characters` and `invisibles` share
/// `type`, `string` and `comment`, and `variables` are plain text.
struct RuleEditorPalette {
    let background: NSColor
    let text: NSColor
    let comment: NSColor
    let keyword: NSColor
    let function: NSColor
    let type: NSColor
    let constant: NSColor
    let number: NSColor
    let string: NSColor
    let insertionPoint: NSColor
    let selection: NSColor
    let lineHighlight: NSColor
    var boldKeywords = false

    var editorTheme: EditorTheme {
        func attribute(_ color: NSColor, bold: Bool = false, italic: Bool = false) -> EditorTheme.Attribute {
            EditorTheme.Attribute(color: color, bold: bold, italic: italic)
        }
        return EditorTheme(
            text: attribute(text),
            insertionPoint: insertionPoint,
            invisibles: attribute(comment),
            background: background,
            lineHighlight: lineHighlight,
            selection: selection,
            keywords: attribute(keyword, bold: boldKeywords),
            commands: attribute(function),
            types: attribute(type),
            attributes: attribute(type),
            variables: attribute(text),
            values: attribute(constant),
            numbers: attribute(number),
            strings: attribute(string),
            characters: attribute(string),
            comments: attribute(comment, italic: true))
    }
}

extension RuleEditorPalette {
    /// Colors as written in each theme's own definition, 0xRRGGBB.
    private init(
        background: UInt32, text: UInt32, comment: UInt32, keyword: UInt32, function: UInt32, type: UInt32,
        constant: UInt32, number: UInt32, string: UInt32, insertionPoint: UInt32, selection: UInt32,
        lineHighlight: UInt32
    ) {
        func color(_ rgb: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        }
        self.init(
            background: color(background), text: color(text), comment: color(comment), keyword: color(keyword),
            function: color(function), type: color(type), constant: color(constant), number: color(number),
            string: color(string), insertionPoint: color(insertionPoint), selection: color(selection),
            lineHighlight: color(lineHighlight))
    }

    /// The system's semantic colors, resolved for one appearance: the editor
    /// draws with fixed colors, so this is built per color scheme.
    static func system(_ scheme: ColorScheme) -> RuleEditorPalette {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        func resolved(_ color: NSColor) -> NSColor {
            var result = color
            appearance?.performAsCurrentDrawingAppearance {
                result = color.usingColorSpace(.sRGB) ?? color
            }
            return result
        }
        return RuleEditorPalette(
            background: resolved(.textBackgroundColor),
            text: resolved(.labelColor),
            comment: resolved(.secondaryLabelColor),
            keyword: resolved(.systemPink),
            // Light teal is too pale on a white page (2.2:1).
            function: resolved(scheme == .dark ? .systemTeal : .systemTeal.shadow(withLevel: 0.25) ?? .systemTeal),
            type: resolved(.systemPurple),
            constant: resolved(.systemIndigo),
            number: resolved(.systemBlue),
            string: resolved(.systemRed),
            insertionPoint: resolved(.controlAccentColor),
            selection: resolved(.selectedTextBackgroundColor),
            lineHighlight: resolved(.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.5)),
            boldKeywords: true)
    }

    static var catppuccinLatte: RuleEditorPalette {
        RuleEditorPalette(
            background: 0xEFF1F5, text: 0x4C4F69, comment: 0x6C6F85, keyword: 0x8839EF, function: 0x1E66F5,
            type: 0xD20F39, constant: 0xFE640B, number: 0xFE640B, string: 0x40A02B, insertionPoint: 0xDC8A78,
            selection: 0xCCD0DA, lineHighlight: 0xE6E9EF)
    }

    static var catppuccinMocha: RuleEditorPalette {
        RuleEditorPalette(
            background: 0x1E1E2E, text: 0xCDD6F4, comment: 0x9399B2, keyword: 0xCBA6F7, function: 0x89B4FA,
            type: 0xF9E2AF, constant: 0xFAB387, number: 0xFAB387, string: 0xA6E3A1, insertionPoint: 0xF5E0DC,
            selection: 0x45475A, lineHighlight: 0x313244)
    }

    static var dracula: RuleEditorPalette {
        RuleEditorPalette(
            background: 0x282A36, text: 0xF8F8F2, comment: 0x6272A4, keyword: 0xFF79C6, function: 0x50FA7B,
            type: 0x8BE9FD, constant: 0xBD93F9, number: 0xBD93F9, string: 0xF1FA8C, insertionPoint: 0xF8F8F2,
            selection: 0x44475A, lineHighlight: 0x343746)
    }

    static var githubLight: RuleEditorPalette {
        RuleEditorPalette(
            background: 0xFFFFFF, text: 0x1F2328, comment: 0x59636E, keyword: 0xCF222E, function: 0x8250DF,
            type: 0x953800, constant: 0x0550AE, number: 0x0550AE, string: 0x0A3069, insertionPoint: 0x0969DA,
            selection: 0xB6E3FF, lineHighlight: 0xF6F8FA)
    }

    static var githubDark: RuleEditorPalette {
        RuleEditorPalette(
            background: 0x0D1117, text: 0xE6EDF3, comment: 0x8B949E, keyword: 0xFF7B72, function: 0xD2A8FF,
            type: 0xFFA657, constant: 0x79C0FF, number: 0x79C0FF, string: 0xA5D6FF, insertionPoint: 0x2F81F7,
            selection: 0x264F78, lineHighlight: 0x161B22)
    }

    static var gruvboxLight: RuleEditorPalette {
        RuleEditorPalette(
            background: 0xFBF1C7, text: 0x3C3836, comment: 0x7C6F64, keyword: 0x9D0006, function: 0x79740E,
            type: 0xB57614, constant: 0x8F3F71, number: 0x8F3F71, string: 0x427B58, insertionPoint: 0x3C3836,
            selection: 0xD5C4A1, lineHighlight: 0xEBDBB2)
    }

    static var gruvboxDark: RuleEditorPalette {
        RuleEditorPalette(
            background: 0x282828, text: 0xEBDBB2, comment: 0x928374, keyword: 0xFB4934, function: 0xB8BB26,
            type: 0xFABD2F, constant: 0xD3869B, number: 0xD3869B, string: 0x8EC07C, insertionPoint: 0xEBDBB2,
            selection: 0x504945, lineHighlight: 0x3C3836)
    }

    static var nord: RuleEditorPalette {
        RuleEditorPalette(
            background: 0x2E3440, text: 0xD8DEE9, comment: 0x7B88A1, keyword: 0x81A1C1, function: 0x88C0D0,
            type: 0x8FBCBB, constant: 0xB48EAD, number: 0xB48EAD, string: 0xA3BE8C, insertionPoint: 0xD8DEE9,
            selection: 0x434C5E, lineHighlight: 0x3B4252)
    }

    static var oneLight: RuleEditorPalette {
        RuleEditorPalette(
            background: 0xFAFAFA, text: 0x383A42, comment: 0x7F8088, keyword: 0xA626A4, function: 0x4078F2,
            type: 0xC18401, constant: 0x986801, number: 0x986801, string: 0x50A14F, insertionPoint: 0x526FFF,
            selection: 0xE5E5E6, lineHighlight: 0xF0F0F0)
    }

    static var oneDark: RuleEditorPalette {
        RuleEditorPalette(
            background: 0x282C34, text: 0xABB2BF, comment: 0x7F848E, keyword: 0xC678DD, function: 0x61AFEF,
            type: 0xE5C07B, constant: 0xD19A66, number: 0xD19A66, string: 0x98C379, insertionPoint: 0x528BFF,
            selection: 0x3E4451, lineHighlight: 0x2C313C)
    }

    static var solarizedLight: RuleEditorPalette {
        RuleEditorPalette(
            background: 0xFDF6E3, text: 0x586E75, comment: 0x93A1A1, keyword: 0x859900, function: 0x268BD2,
            type: 0xB58900, constant: 0x6C71C4, number: 0xD33682, string: 0x2AA198, insertionPoint: 0x586E75,
            selection: 0xEEE8D5, lineHighlight: 0xEEE8D5)
    }

    static var solarizedDark: RuleEditorPalette {
        RuleEditorPalette(
            background: 0x002B36, text: 0x93A1A1, comment: 0x657B83, keyword: 0x859900, function: 0x268BD2,
            type: 0xB58900, constant: 0x6C71C4, number: 0xD33682, string: 0x2AA198, insertionPoint: 0x93A1A1,
            selection: 0x073642, lineHighlight: 0x073642)
    }

    static var tokyoNightDay: RuleEditorPalette {
        RuleEditorPalette(
            background: 0xE1E2E7, text: 0x3760BF, comment: 0x68709A, keyword: 0x9854F1, function: 0x2E7DE9,
            type: 0x188092, constant: 0xB15C00, number: 0xB15C00, string: 0x587539, insertionPoint: 0x3760BF,
            selection: 0xB7C1E3, lineHighlight: 0xD0D5E3)
    }

    static var tokyoNight: RuleEditorPalette {
        RuleEditorPalette(
            background: 0x1A1B26, text: 0xC0CAF5, comment: 0x737AA2, keyword: 0xBB9AF7, function: 0x7AA2F7,
            type: 0x2AC3DE, constant: 0xFF9E64, number: 0xFF9E64, string: 0x9ECE6A, insertionPoint: 0xC0CAF5,
            selection: 0x283457, lineHighlight: 0x1F2335)
    }
}

/// A few lines of a rule in one theme, for Settings.
struct RuleEditorThemePreview: View {
    let theme: RuleEditorTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = theme.palette(colorScheme)
        func run(_ text: String, _ color: NSColor) -> Text {
            Text(text).foregroundStyle(Color(nsColor: color))
        }
        return VStack(alignment: .leading, spacing: 2) {
            run("// Logs every five minutes", palette.comment).italic()
            Text(
                "\(run("export const", palette.keyword)) \(run("every", palette.text)) \(run("=", palette.text)) \(run("300", palette.number));"
            )
            Text(
                "\(run("ctx", palette.text)).\(run("log", palette.function))(\(run("\"tick\"", palette.string)) \(run("as", palette.keyword)) \(run("Label", palette.type)));"
            )
        }
        .font(.callout.monospaced())
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: palette.background), in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .accessibilityHidden(true)
    }
}
