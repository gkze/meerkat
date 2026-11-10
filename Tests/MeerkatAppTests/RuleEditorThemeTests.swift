import AppKit
import SwiftUI
import Testing

@testable import MeerkatApp

/// Palettes are hand-copied hex values, so these catch a bad digit or a
/// variant wired to the wrong appearance.
@MainActor
struct RuleEditorThemeTests {
    private static func luminance(_ color: NSColor) -> Double {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }

    private static func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The published themes set the floor: Solarized is deliberately low
    /// contrast, and these are its values, not an accessibility target.
    @Test(arguments: RuleEditorTheme.allCases, [ColorScheme.light, .dark])
    func everyColorReadsOnItsBackground(theme: RuleEditorTheme, scheme: ColorScheme) {
        let palette = theme.palette(scheme)
        #expect(Self.contrast(palette.text, palette.background) >= 4)
        #expect(Self.contrast(palette.text, palette.selection) >= 3)
        for color in [
            palette.comment, palette.keyword, palette.function, palette.type, palette.constant, palette.number,
            palette.string,
        ] {
            #expect(Self.contrast(color, palette.background) >= 2.2)
        }
    }

    /// What Settings says of a theme (`isDarkOnly`) is what it draws.
    @Test(arguments: RuleEditorTheme.allCases)
    func variantsMatchTheAppearance(theme: RuleEditorTheme) {
        #expect((Self.luminance(theme.palette(.light).background) < 0.1) == theme.isDarkOnly)
        if !theme.isDarkOnly { #expect(Self.luminance(theme.palette(.light).background) > 0.5) }
        #expect(Self.luminance(theme.palette(.dark).background) < 0.1)
    }

    /// Only the system theme bolds keywords, as Xcode's default does; the
    /// published themes are drawn as their authors wrote them.
    @Test(arguments: RuleEditorTheme.allCases, [ColorScheme.light, .dark])
    func onlyTheSystemThemeBoldsKeywords(theme: RuleEditorTheme, scheme: ColorScheme) {
        #expect(theme.palette(scheme).boldKeywords == (theme == .system))
    }

    /// The raw values are what `UserDefaults` keeps, so renaming a case
    /// would lose a person's choice.
    @Test func rawValuesAreStable() {
        #expect(
            RuleEditorTheme.allCases.map(\.rawValue) == [
                "system", "catppuccin", "dracula", "github", "gruvbox", "nord", "one", "solarized", "tokyoNight",
            ])
    }
}
