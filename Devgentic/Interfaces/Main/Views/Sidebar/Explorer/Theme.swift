//
//  Theme.swift
//  Devgentic
//
//  Created by Raj Singh on 25/07/25.
//
//  Centralized Design Token system. Every color, font, spacing, and corner-radius
//  value used by the app is defined here. Views read tokens through
//  `@Environment(\.appTheme)` and never hard-code colors.
//

import SwiftUI

// MARK: - Syntax Theme (for code editors)

/// A set of `NSColor` tokens for syntax-highlighted code editors.
struct SyntaxTheme {
    let background: NSColor
    let lineHighlight: NSColor
    let selection: NSColor
    let text: NSColor
    let keywords: NSColor
    let commands: NSColor
    let types: NSColor
    let attributes: NSColor
    let variables: NSColor
    let values: NSColor
    let numbers: NSColor
    let strings: NSColor
    let characters: NSColor
    let comments: NSColor
    let bracketHighlight: NSColor
}

// MARK: - Theme Protocol

/// A protocol that defines the blueprint for any theme in the application.
/// It ensures that every theme provides a consistent set of colors, typography,
/// spacing, and code-editor styling.
protocol Theme {

    // ── Metadata ──────────────────────────────────────────────────────

    /// A unique identifier for the theme, used for saving to UserDefaults.
    var id: String { get }

    /// The user-facing name of the theme, displayed in settings.
    var displayName: String { get }

    // ── Tier 1: Core Background Colors ────────────────────────────────

    var primaryBackground: Color { get }
    var secondaryBackground: Color { get }
    var tertiaryBackground: Color { get }

    // ── Tier 1: Text Colors ──────────────────────────────────────────

    var primaryText: Color { get }
    var secondaryText: Color { get }
    var tertiaryText: Color { get }

    // ── Tier 1: Control & Accent Colors ──────────────────────────────

    var accentColor: Color { get }
    var dividerColor: Color { get }
    var selectionColor: Color { get }

    // ── Tier 1: Semantic Colors ──────────────────────────────────────

    var errorColor: Color { get }
    var successColor: Color { get }
    var warningColor: Color { get }

    // ── Tier 2: Extended Color Tokens (defaults provided) ────────────

    /// Background for standard controls (input fields, popovers, chips).
    var controlBackground: Color { get }

    /// Background for text-editing surfaces.
    var textBackground: Color { get }

    /// Color for placeholder / hint text.
    var placeholderText: Color { get }

    /// Accent color for OS-level controls (toggles, checkboxes).
    var controlAccent: Color { get }

    /// Background for the current user's chat bubble.
    var userBubbleBackground: Color { get }

    /// Background for inline `code` spans inside markdown.
    var inlineCodeBackground: Color { get }

    /// Text color for inline `code` spans.
    var inlineCodeText: Color { get }

    /// A muted variant of the accent color.
    var accentMuted: Color { get }

    /// Header bar of a fenced code block.
    var codeBlockHeaderBackground: Color { get }

    /// Editor area of a fenced code block.
    var codeBlockEditorBackground: Color { get }

    /// Subtle overlay used for hover states and surface tints.
    var surfaceOverlay: Color { get }

    /// Stronger overlay for borders and active states.
    var surfaceOverlayStrong: Color { get }

    /// Color used for streaming / "thinking" indicators.
    var streamingIndicator: Color { get }

    /// Top gradient stop for the main chat background.
    var chatGPTGradientTop: Color { get }

    /// Bottom gradient stop for the main chat background.
    var chatGPTGradientBottom: Color { get }

    // ── Tier 3: Typography ───────────────────────────────────────────

    var fontLargeTitle: Font { get }
    var fontTitle1: Font { get }
    var fontTitle2: Font { get }
    var fontTitle3: Font { get }
    var fontHeadline: Font { get }
    var fontBody: Font { get }
    var fontCallout: Font { get }
    var fontSubheadline: Font { get }
    var fontFootnote: Font { get }
    var fontCaption: Font { get }
    var fontCaption2: Font { get }
    var fontCode: Font { get }
    var fontCodeCaption: Font { get }

    // ── Tier 3: Spacing ──────────────────────────────────────────────

    var spacingXXSmall: CGFloat { get }
    var spacingXSmall: CGFloat { get }
    var spacingSmall: CGFloat { get }
    var spacingMedium: CGFloat { get }
    var spacingLarge: CGFloat { get }
    var spacingXLarge: CGFloat { get }
    var spacingXXLarge: CGFloat { get }

    // ── Tier 3: Corner Radius ────────────────────────────────────────

    var cornerRadiusSmall: CGFloat { get }
    var cornerRadiusMedium: CGFloat { get }
    var cornerRadiusLarge: CGFloat { get }

    // ── Syntax Highlighting ──────────────────────────────────────────

    /// Colors used by the code editor (CodeEditSourceEditor).
    var syntaxTheme: SyntaxTheme { get }
}


// MARK: - Protocol Extension (Sensible Defaults)

/// Default values for all Tier 2 / Tier 3 tokens. Existing themes compile
/// with zero changes; any theme may selectively override.
extension Theme {

    // ── Tier 2 Color Defaults ────────────────────────────────────────

    var controlBackground: Color { Color(nsColor: .controlBackgroundColor) }
    var textBackground: Color { Color(nsColor: .textBackgroundColor) }
    var placeholderText: Color { Color(nsColor: .placeholderTextColor) }
    var controlAccent: Color { Color(nsColor: .controlAccentColor) }
    var userBubbleBackground: Color { Color(hex: "#388E8E") }
    var inlineCodeBackground: Color { Color(red: 0.2, green: 0.2, blue: 0.22) }
    var inlineCodeText: Color { Color(red: 0.9, green: 0.9, blue: 0.9) }
    var accentMuted: Color { accentColor.opacity(0.7) }
    var codeBlockHeaderBackground: Color { Color(red: 0.15, green: 0.15, blue: 0.17) }
    var codeBlockEditorBackground: Color { Color(red: 0.11, green: 0.11, blue: 0.13) }
    var surfaceOverlay: Color { Color.white.opacity(0.06) }
    var surfaceOverlayStrong: Color { Color.white.opacity(0.1) }
    var streamingIndicator: Color { .blue }
    var chatGPTGradientTop: Color { Color(red: 0.15, green: 0.15, blue: 0.16) }
    var chatGPTGradientBottom: Color { Color(red: 0.1, green: 0.1, blue: 0.11) }

    // ── Tier 3 Typography Defaults ───────────────────────────────────

    var fontLargeTitle: Font { .system(size: 32, weight: .bold) }
    var fontTitle1: Font { .system(size: 26, weight: .bold) }
    var fontTitle2: Font { .system(size: 20, weight: .semibold) }
    var fontTitle3: Font { .system(size: 18, weight: .semibold) }
    var fontHeadline: Font { .system(size: 16, weight: .semibold) }
    var fontBody: Font { .system(size: 15, weight: .regular) }
    var fontCallout: Font { .system(size: 14, weight: .regular) }
    var fontSubheadline: Font { .system(size: 14, weight: .regular) }
    var fontFootnote: Font { .system(size: 13, weight: .regular) }
    var fontCaption: Font { .system(size: 12, weight: .regular) }
    var fontCaption2: Font { .system(size: 11, weight: .regular) }
    var fontCode: Font { .system(size: 13, weight: .regular, design: .monospaced) }
    var fontCodeCaption: Font { .system(size: 10, weight: .medium, design: .monospaced) }

    // ── Tier 3 Spacing Defaults ──────────────────────────────────────

    var spacingXXSmall: CGFloat { 2 }
    var spacingXSmall: CGFloat { 4 }
    var spacingSmall: CGFloat { 8 }
    var spacingMedium: CGFloat { 10 }
    var spacingLarge: CGFloat { 14 }
    var spacingXLarge: CGFloat { 20 }
    var spacingXXLarge: CGFloat { 28 }

    // ── Tier 3 Corner Radius Defaults ────────────────────────────────

    var cornerRadiusSmall: CGFloat { 4 }
    var cornerRadiusMedium: CGFloat { 8 }
    var cornerRadiusLarge: CGFloat { 16 }

    // ── Syntax Theme Default ─────────────────────────────────────────

    var syntaxTheme: SyntaxTheme {
        SyntaxTheme(
            background: NSColor(hex: "#1e1e1e"),
            lineHighlight: NSColor(hex: "#2c2c2c"),
            selection: NSColor(hex: "#264f78"),
            text: .white,
            keywords: NSColor(hex: "#569cd6"),
            commands: NSColor(hex: "#dcdcaa"),
            types: NSColor(hex: "#4ec9b0"),
            attributes: NSColor(hex: "#c586c0"),
            variables: .white,
            values: NSColor(hex: "#b5cea8"),
            numbers: NSColor(hex: "#b5cea8"),
            strings: NSColor(hex: "#ce9178"),
            characters: NSColor(hex: "#d7ba7d"),
            comments: NSColor(hex: "#6a9955"),
            bracketHighlight: NSColor(hex: "#569cd6").withAlphaComponent(0.4)
        )
    }
}


// MARK: - AppThemes

enum AppThemes {}


// MARK: - Default Theme

extension AppThemes {
    struct DefaultTheme: Theme {
        let id = "default"
        let displayName = "Default (System)"

        // Uses SwiftUI's semantic colors which adapt automatically.
        let primaryBackground: Color = Color(nsColor: .windowBackgroundColor)
        let secondaryBackground: Color = Color(nsColor: .controlBackgroundColor)
        let tertiaryBackground: Color = Color(nsColor: .underPageBackgroundColor)

        let primaryText: Color = .primary
        let secondaryText: Color = .secondary
        let tertiaryText: Color = Color(nsColor: .tertiaryLabelColor)

        let accentColor: Color = .accentColor
        let dividerColor: Color = Color(nsColor: .separatorColor)
        let selectionColor: Color = Color(nsColor: .selectedContentBackgroundColor)

        let errorColor: Color = .red
        let successColor: Color = .green
        let warningColor: Color = .orange
    }
}


// MARK: - Dracula Theme

extension AppThemes {
    struct DraculaTheme: Theme {
        let id = "dracula"
        let displayName = "Dracula"

        // Tier 1 — Core
        let primaryBackground: Color = Color(hex: "#282a36")
        let secondaryBackground: Color = Color(hex: "#383A59")
        let tertiaryBackground: Color = Color(hex: "#44475a")

        let primaryText: Color = Color(hex: "#f8f8f2")
        let secondaryText: Color = Color(hex: "#6272a4")
        let tertiaryText: Color = Color(hex: "#44475a")

        let accentColor: Color = Color(hex: "#bd93f9")
        let dividerColor: Color = Color(hex: "#44475a")
        let selectionColor: Color = Color(hex: "#44475a")

        let errorColor: Color = Color(hex: "#ff5555")
        let successColor: Color = Color(hex: "#50fa7b")
        let warningColor: Color = Color(hex: "#f1fa8c")

        // Tier 2 — Dracula-specific overrides
        var controlBackground: Color { Color(hex: "#383A59") }
        var textBackground: Color { Color(hex: "#282a36") }
        var placeholderText: Color { Color(hex: "#6272a4") }
        var controlAccent: Color { Color(hex: "#bd93f9") }
        var userBubbleBackground: Color { Color(hex: "#bd93f9") }
        var inlineCodeBackground: Color { Color(hex: "#44475a") }
        var inlineCodeText: Color { Color(hex: "#f8f8f2") }
        var codeBlockHeaderBackground: Color { Color(hex: "#282a36") }
        var codeBlockEditorBackground: Color { Color(hex: "#1e1e2e") }
        var surfaceOverlay: Color { Color.white.opacity(0.08) }
        var surfaceOverlayStrong: Color { Color.white.opacity(0.12) }
        var streamingIndicator: Color { Color(hex: "#8be9fd") }
        var chatGPTGradientTop: Color { Color(hex: "#282a36") }
        var chatGPTGradientBottom: Color { Color(hex: "#1e1e2e") }

        // Syntax — Dracula palette
        var syntaxTheme: SyntaxTheme {
            SyntaxTheme(
                background: NSColor(hex: "#282a36"),
                lineHighlight: NSColor(hex: "#44475a"),
                selection: NSColor(hex: "#44475a"),
                text: NSColor(hex: "#f8f8f2"),
                keywords: NSColor(hex: "#ff79c6"),
                commands: NSColor(hex: "#f1fa8c"),
                types: NSColor(hex: "#8be9fd"),
                attributes: NSColor(hex: "#ff79c6"),
                variables: NSColor(hex: "#f8f8f2"),
                values: NSColor(hex: "#bd93f9"),
                numbers: NSColor(hex: "#bd93f9"),
                strings: NSColor(hex: "#f1fa8c"),
                characters: NSColor(hex: "#f1fa8c"),
                comments: NSColor(hex: "#6272a4"),
                bracketHighlight: NSColor(hex: "#ff79c6").withAlphaComponent(0.4)
            )
        }
    }

    struct OneLightTheme: Theme {
        let id = "one_light"
        let displayName = "One Light"

        // Tier 1 — Core (Light Mode)
        let primaryBackground: Color = Color(hex: "#fafafa")
        let secondaryBackground: Color = Color(hex: "#f0f0f0")
        let tertiaryBackground: Color = Color(hex: "#e5e5e6")

        let primaryText: Color = Color(hex: "#383a42")
        let secondaryText: Color = Color(hex: "#696c77")
        let tertiaryText: Color = Color(hex: "#a0a1a7")

        let accentColor: Color = Color(hex: "#4078f2")
        let dividerColor: Color = Color(hex: "#d0d0d0")
        let selectionColor: Color = Color(hex: "#e5e5e6")

        let errorColor: Color = Color(hex: "#e45649")
        let successColor: Color = Color(hex: "#50a14f")
        let warningColor: Color = Color(hex: "#c18401")

        // Tier 2 — Overrides
        var controlBackground: Color { Color(hex: "#f0f0f0") }
        var textBackground: Color { Color(hex: "#fafafa") }
        var placeholderText: Color { Color(hex: "#a0a1a7") }
        var controlAccent: Color { Color(hex: "#4078f2") }
        var userBubbleBackground: Color { Color(hex: "#4078f2") }
        var inlineCodeBackground: Color { Color(hex: "#f0f0f0") }
        var inlineCodeText: Color { Color(hex: "#383a42") }
        var codeBlockHeaderBackground: Color { Color(hex: "#f0f0f0") }
        var codeBlockEditorBackground: Color { Color(hex: "#fafafa") }
        var surfaceOverlay: Color { Color.black.opacity(0.04) }
        var surfaceOverlayStrong: Color { Color.black.opacity(0.08) }
        var streamingIndicator: Color { Color(hex: "#0184bc") }
        var chatGPTGradientTop: Color { Color(hex: "#fafafa") }
        var chatGPTGradientBottom: Color { Color(hex: "#f0f0f0") }

        // Syntax — One Light palette
        var syntaxTheme: SyntaxTheme {
            SyntaxTheme(
                background: NSColor(hex: "#fafafa"),
                lineHighlight: NSColor(hex: "#f0f0f0"),
                selection: NSColor(hex: "#e5e5e6"),
                text: NSColor(hex: "#383a42"),
                keywords: NSColor(hex: "#a626a4"),
                commands: NSColor(hex: "#0184bc"),
                types: NSColor(hex: "#c18401"),
                attributes: NSColor(hex: "#d19a66"),
                variables: NSColor(hex: "#e45649"),
                values: NSColor(hex: "#986801"),
                numbers: NSColor(hex: "#d19a66"),
                strings: NSColor(hex: "#50a14f"),
                characters: NSColor(hex: "#50a14f"),
                comments: NSColor(hex: "#a0a1a7"),
                bracketHighlight: NSColor(hex: "#4078f2").withAlphaComponent(0.4)
            )
        }
    }
}


// MARK: - Color Hex Initializer

/// An extension to allow creating SwiftUI Colors from a hex string.
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
