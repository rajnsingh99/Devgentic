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


// MARK: - Accent Color Palette

enum AppAccentColor: String, CaseIterable {
    case `default` = "default"
    case blue = "blue"
    case green = "green"
    case purple = "purple"
    case orange = "orange"
    case pink = "pink"
    case modernSpotify = "modern_spotify"

    var color: Color? {
        switch self {
        case .default: return nil
        case .blue: return Color(hex: "#0A84FF")          // Electric Azure
        case .green: return Color(hex: "#10B981")         // Emerald Mint
        case .purple: return Color(hex: "#8B5CF6")        // Royal Violet
        case .orange: return Color(hex: "#F59E0B")        // Warm Amber
        case .pink: return Color(hex: "#EC4899")          // Rose Quartz
        case .modernSpotify: return Color(hex: "#06B6D4") // Cosmic Cyan
        }
    }

    var nsColor: NSColor? {
        switch self {
        case .default: return nil
        case .blue: return NSColor(hex: "#0A84FF")
        case .green: return NSColor(hex: "#10B981")
        case .purple: return NSColor(hex: "#8B5CF6")
        case .orange: return NSColor(hex: "#F59E0B")
        case .pink: return NSColor(hex: "#EC4899")
        case .modernSpotify: return NSColor(hex: "#06B6D4")
        }
    }

    var displayName: String {
        switch self {
        case .default: return "Default"
        case .blue: return "Ocean Blue"
        case .green: return "Emerald Mint"
        case .purple: return "Royal Violet"
        case .orange: return "Warm Amber"
        case .pink: return "Rose Quartz"
        case .modernSpotify: return "Cosmic Cyan"
        }
    }
}

// MARK: - Theme Decorator (For Global Overrides)

/// A decorator that wraps a base theme and overrides specific properties,
/// such as the accent color, without modifying the base theme's definition.
struct ThemeDecorator: Theme {
    let base: any Theme
    let accentColorOverride: AppAccentColor

    var accentOverride: Color? { accentColorOverride.color }

    // Metadata
    var id: String { base.id }
    var displayName: String { base.displayName }

    // Tier 1 — Core Backgrounds
    var primaryBackground: Color { base.primaryBackground }
    var secondaryBackground: Color { base.secondaryBackground }
    var tertiaryBackground: Color { base.tertiaryBackground }

    // Tier 1 — Text
    var primaryText: Color { base.primaryText }
    var secondaryText: Color { base.secondaryText }
    var tertiaryText: Color { base.tertiaryText }

    // Tier 1 — Controls & Accent (The heart of the decorator)
    var accentColor: Color { accentOverride ?? base.accentColor }
    var dividerColor: Color { base.dividerColor }
    var selectionColor: Color { base.selectionColor }

    // Tier 1 — Semantic
    var errorColor: Color { base.errorColor }
    var successColor: Color { base.successColor }
    var warningColor: Color { base.warningColor }
    var colorScheme: ColorScheme? { base.colorScheme }

    // Tier 2 — Extended (Defaults provided by protocol extension, but we forward base)
    var controlBackground: Color { base.controlBackground }
    var textBackground: Color { base.textBackground }
    var placeholderText: Color { base.placeholderText }
    var controlAccent: Color { accentOverride ?? base.controlAccent }
    var userBubbleBackground: Color { accentOverride ?? base.userBubbleBackground }
    var inlineCodeHighlight: Color { accentColor }
    var accentMuted: Color { accentColor.opacity(0.7) }
    var codeBlockHeaderBackground: Color { base.codeBlockHeaderBackground }
    var codeBlockEditorBackground: Color { base.codeBlockEditorBackground }
    var surfaceOverlay: Color { base.surfaceOverlay }
    var surfaceOverlayStrong: Color { base.surfaceOverlayStrong }
    var streamingIndicator: Color { accentOverride ?? base.streamingIndicator }
    var chatGPTGradientTop: Color { base.chatGPTGradientTop }
    var chatGPTGradientBottom: Color { base.chatGPTGradientBottom }
    var shadowColor: Color { base.shadowColor }
    var searchHighlight: Color { base.searchHighlight }
    var searchHighlightActive: Color { base.searchHighlightActive }

    // Tier 3 — Typography
    var fontLargeTitle: Font { base.fontLargeTitle }
    var fontTitle1: Font { base.fontTitle1 }
    var fontTitle2: Font { base.fontTitle2 }
    var fontTitle3: Font { base.fontTitle3 }
    var fontHeadline: Font { base.fontHeadline }
    var fontBody: Font { base.fontBody }
    var fontCallout: Font { base.fontCallout }
    var fontSubheadline: Font { base.fontSubheadline }
    var fontFootnote: Font { base.fontFootnote }
    var fontCaption: Font { base.fontCaption }
    var fontCaption2: Font { base.fontCaption2 }
    var fontCode: Font { base.fontCode }
    var fontCodeCaption: Font { base.fontCodeCaption }

    // Tier 3 — Spacing
    var spacingXXSmall: CGFloat { base.spacingXXSmall }
    var spacingXSmall: CGFloat { base.spacingXSmall }
    var spacingSmall: CGFloat { base.spacingSmall }
    var spacingMedium: CGFloat { base.spacingMedium }
    var spacingLarge: CGFloat { base.spacingLarge }
    var spacingXLarge: CGFloat { base.spacingXLarge }
    var spacingXXLarge: CGFloat { base.spacingXXLarge }

    // Tier 3 — Corner Radius
    var cornerRadiusSmall: CGFloat { base.cornerRadiusSmall }
    var cornerRadiusMedium: CGFloat { base.cornerRadiusMedium }
    var cornerRadiusLarge: CGFloat { base.cornerRadiusLarge }
    var cornerRadiusChip: CGFloat { base.cornerRadiusChip }
    var cornerRadiusRow: CGFloat { base.cornerRadiusRow }
    var cornerRadiusPanel: CGFloat { base.cornerRadiusPanel }

    // Tier 3 — Spacing (extra steps)
    var spacing6: CGFloat { base.spacing6 }
    var spacing12: CGFloat { base.spacing12 }
    var spacing16: CGFloat { base.spacing16 }
    var spacing24: CGFloat { base.spacing24 }

    // Capability Accent Color (forwarded so a base theme may override the hues)
    func capabilityColor(for category: CapabilityMilestoneKind.MilestoneColor) -> Color { base.capabilityColor(for: category) }

    // Syntax Highlighting
    var syntaxTheme: SyntaxTheme {
        base.syntaxTheme.patched(with: accentColorOverride.nsColor)
    }

    /// Not patched with the accent override: a highlight.js theme is a whole CSS palette,
    /// not a token we can recolour one entry of.
    var codeHighlightThemeName: String { base.codeHighlightThemeName }
}


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

    /// Returns a new SyntaxTheme with the keywords and bracket highlight color overridden.
    func patched(with accent: NSColor?) -> SyntaxTheme {
        guard let accent = accent else { return self }
        return SyntaxTheme(
            background: background,
            lineHighlight: lineHighlight,
            selection: selection,
            text: text,
            keywords: accent,
            commands: commands,
            types: types,
            attributes: attributes,
            variables: variables,
            values: values,
            numbers: numbers,
            strings: strings,
            characters: characters,
            comments: comments,
            bracketHighlight: accent.withAlphaComponent(0.4)
        )
    }
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

    /// Hint to SwiftUI / AppKit about whether this theme is intended for
    /// light or dark contexts — used by detached `NSWindow` editors that
    /// can't infer the app's light/dark state from the parent environment.
    /// `nil` defers to the system appearance.
    var colorScheme: ColorScheme? { get }

    /// Accent color for an agent-capability surface (planning / reflection / delegation /
    /// compaction). Single source of truth for the capability hues used by the timeline
    /// milestone chips and the plan/reflection progress cards.
    func capabilityColor(for category: CapabilityMilestoneKind.MilestoneColor) -> Color

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

    /// Foreground color for inline `code` spans, so they stand out from body text.
    ///
    /// Colour is the ONLY treatment: the filled background chip was retired 2026-07-27
    /// (it read as noise in a paragraph naming several symbols, and competed with the
    /// search highlight, which is the one background here that means something).
    var inlineCodeHighlight: Color { get }

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

    /// Drop-shadow color for elevated surfaces (sidebar pane, popovers, cards).
    /// Default is a dark-mode-friendly black@18%; light themes should override
    /// to a softer value since pure black reads too heavy on pale backgrounds.
    var shadowColor: Color { get }

    /// Background tint for a search match in chat text (find-in-conversation).
    /// Single source of truth so every chat surface highlights identically.
    var searchHighlight: Color { get }

    /// Stronger background tint for the *currently focused* search match.
    var searchHighlightActive: Color { get }

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

    /// Extra spacing steps for the values used most that the size ladder skips (audit: 6/12/16/24).
    var spacing6: CGFloat { get }
    var spacing12: CGFloat { get }
    var spacing16: CGFloat { get }
    var spacing24: CGFloat { get }

    // ── Tier 3: Corner Radius ────────────────────────────────────────

    var cornerRadiusSmall: CGFloat { get }
    var cornerRadiusMedium: CGFloat { get }
    var cornerRadiusLarge: CGFloat { get }

    /// Role-based radii for the values the app uses most (audit: 6/10/12 had no token).
    var cornerRadiusChip: CGFloat { get }   // pills, badges, tags
    var cornerRadiusRow: CGFloat { get }    // canonical rows / buttons / standard cards
    var cornerRadiusPanel: CGFloat { get }  // larger cards, panels, sheets

    // ── Syntax Highlighting ──────────────────────────────────────────

    /// Colors used by the code editor (CodeEditSourceEditor).
    var syntaxTheme: SyntaxTheme { get }

    /// Name of the highlight.js CSS theme used for code blocks in chat bubbles.
    ///
    /// Separate from `syntaxTheme` because Highlightr can't be driven by it: `setTheme(to:)`
    /// only loads a CSS file from Highlightr's OWN bundle, and `Theme(themeString:)` is
    /// internal to that package — so our 15 colour tokens cannot be handed to it. Picking
    /// the closest of its 271 bundled themes is the available lever, and it's the one that
    /// matters: every theme used to get `atom-one-*`, so Dracula rendered Atom's palette.
    var codeHighlightThemeName: String { get }
}


// MARK: - Protocol Extension (Sensible Defaults)

/// Default values for all Tier 2 / Tier 3 tokens. Existing themes compile
/// with zero changes; any theme may selectively override.
extension Theme {

    // ── Light/Dark Default ───────────────────────────────────────────

    /// Default to system appearance — concrete themes with a clear
    /// light/dark intent (Dracula, OneDark, OneLight, etc.) override this.
    var colorScheme: ColorScheme? { nil }

    // ── Tier 2 Color Defaults ────────────────────────────────────────

    var controlBackground: Color { Color(nsColor: .controlBackgroundColor) }
    var textBackground: Color { Color(nsColor: .textBackgroundColor) }
    var placeholderText: Color { Color(nsColor: .placeholderTextColor) }
    var controlAccent: Color { Color(nsColor: .controlAccentColor) }
    var userBubbleBackground: Color { Color(hex: "#388E8E") }
    var inlineCodeHighlight: Color { accentColor }
    var accentMuted: Color { accentColor.opacity(0.7) }
    var codeBlockHeaderBackground: Color { Color(red: 0.15, green: 0.15, blue: 0.17) }
    var codeBlockEditorBackground: Color { Color(red: 0.11, green: 0.11, blue: 0.13) }
    var surfaceOverlay: Color { Color.white.opacity(0.06) }
    var surfaceOverlayStrong: Color { Color.white.opacity(0.1) }
    var streamingIndicator: Color { .blue }
    var chatGPTGradientTop: Color { Color(red: 0.15, green: 0.15, blue: 0.16) }
    var chatGPTGradientBottom: Color { Color(red: 0.1, green: 0.1, blue: 0.11) }
    var shadowColor: Color { Color.black.opacity(0.18) }
    // Find-in-conversation highlight hues (browser-find style). Kept in sync with
    // `SearchHighlighter.defaultBase`/`.defaultActive`, which the theme-less static
    // highlight entry points use.
    var searchHighlight: Color { Color.yellow.opacity(0.4) }
    var searchHighlightActive: Color { Color.orange.opacity(0.6) }

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

    var cornerRadiusChip: CGFloat { 6 }
    var cornerRadiusRow: CGFloat { 10 }
    var cornerRadiusPanel: CGFloat { 12 }

    // ── Tier 3 Spacing — Extra Steps (fill the ladder) ───────────────

    var spacing6: CGFloat { 6 }
    var spacing12: CGFloat { 12 }
    var spacing16: CGFloat { 16 }
    var spacing24: CGFloat { 24 }

    // ── Capability Accent Color ──────────────────────────────────────
    // (The backend-origin color token was REMOVED 2026-07-19 by user decision:
    // no profile/backend colors in the sidebar — its only consumer.)

    /// Defaults preserve the pre-token hardcoded hues (planning blue, reflection
    /// purple, delegation green, compaction orange). Themes may override.
    func capabilityColor(for category: CapabilityMilestoneKind.MilestoneColor) -> Color {
        switch category {
        case .planning:   return .blue
        case .reflection: return .purple
        case .delegation: return .green
        case .compaction: return .orange
        // A milestone from a newer build claims no capability family, so it takes the theme's
        // neutral secondary text colour rather than borrowing one of the four hues.
        case .unrecognised: return secondaryText
        }
    }

    // ── Code Highlight Theme Default ─────────────────────────────────

    /// Falls back to Atom One, matched to the theme's light/dark scheme. Themes with a
    /// closer match among Highlightr's bundled styles override this.
    var codeHighlightThemeName: String {
        colorScheme == .light ? "atom-one-light" : "atom-one-dark"
    }

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
        let colorScheme: ColorScheme? = .dark
        /// Highlightr bundles the real Dracula palette. Choosing Dracula and getting
        /// Atom's colours in every code block was the most visible case of the old
        /// light/dark-only fallback.
        let codeHighlightThemeName = "dracula"

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
        var inlineCodeHighlight: Color { Color(hex: "#ff79c6") }    // Dracula Pink
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
        let colorScheme: ColorScheme? = .light

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
        var inlineCodeHighlight: Color { Color(hex: "#a626a4") }    // One Light Purple
        var codeBlockHeaderBackground: Color { Color(hex: "#f0f0f0") }
        var codeBlockEditorBackground: Color { Color(hex: "#fafafa") }
        var surfaceOverlay: Color { Color.black.opacity(0.04) }
        var surfaceOverlayStrong: Color { Color.black.opacity(0.08) }
        var streamingIndicator: Color { Color(hex: "#0184bc") }
        var chatGPTGradientTop: Color { Color(hex: "#fafafa") }
        var chatGPTGradientBottom: Color { Color(hex: "#f0f0f0") }
        var shadowColor: Color { Color.black.opacity(0.08) }

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


// MARK: - One Dark Theme

extension AppThemes {
    struct OneDarkTheme: Theme {
        let id = "one_dark"
        let displayName = "One Dark"
        let colorScheme: ColorScheme? = .dark

        // Tier 1 — Core (Atom One Dark)
        let primaryBackground: Color = Color(hex: "#282c34")
        let secondaryBackground: Color = Color(hex: "#21252b")
        let tertiaryBackground: Color = Color(hex: "#2c313a")

        let primaryText: Color = Color(hex: "#abb2bf")
        let secondaryText: Color = Color(hex: "#5c6370")
        let tertiaryText: Color = Color(hex: "#4b5263")

        let accentColor: Color = Color(hex: "#61afef")
        let dividerColor: Color = Color(hex: "#181a1f")
        let selectionColor: Color = Color(hex: "#3e4451")

        let errorColor: Color = Color(hex: "#e06c75")
        let successColor: Color = Color(hex: "#98c379")
        let warningColor: Color = Color(hex: "#e5c07b")

        // Tier 2 — Overrides
        var controlBackground: Color { Color(hex: "#21252b") }
        var textBackground: Color { Color(hex: "#282c34") }
        var placeholderText: Color { Color(hex: "#5c6370") }
        var controlAccent: Color { Color(hex: "#61afef") }
        var userBubbleBackground: Color { Color(hex: "#61afef") }
        var inlineCodeHighlight: Color { Color(hex: "#d19a66") }    // One Dark Orange
        var codeBlockHeaderBackground: Color { Color(hex: "#21252b") }
        var codeBlockEditorBackground: Color { Color(hex: "#282c34") }
        var surfaceOverlay: Color { Color.white.opacity(0.06) }
        var surfaceOverlayStrong: Color { Color.white.opacity(0.1) }
        var streamingIndicator: Color { Color(hex: "#56b6c2") }
        var chatGPTGradientTop: Color { Color(hex: "#282c34") }
        var chatGPTGradientBottom: Color { Color(hex: "#21252b") }

        // Syntax — One Dark palette (Atom)
        var syntaxTheme: SyntaxTheme {
            SyntaxTheme(
                background: NSColor(hex: "#282c34"),
                lineHighlight: NSColor(hex: "#2c313a"),
                selection: NSColor(hex: "#3e4451"),
                text: NSColor(hex: "#abb2bf"),
                keywords: NSColor(hex: "#c678dd"),
                commands: NSColor(hex: "#61afef"),
                types: NSColor(hex: "#e5c07b"),
                attributes: NSColor(hex: "#d19a66"),
                variables: NSColor(hex: "#e06c75"),
                values: NSColor(hex: "#d19a66"),
                numbers: NSColor(hex: "#d19a66"),
                strings: NSColor(hex: "#98c379"),
                characters: NSColor(hex: "#56b6c2"),
                comments: NSColor(hex: "#5c6370"),
                bracketHighlight: NSColor(hex: "#61afef").withAlphaComponent(0.4)
            )
        }
    }
}


// MARK: - Cosmic Dark Theme (Spotify Inspired)

extension AppThemes {
    struct CosmicDarkTheme: Theme {
        let id = "cosmic_dark"
        let displayName = "Cosmic Dark"
        let colorScheme: ColorScheme? = .dark
        /// No Cosmic style ships with Highlightr; Nord is the closest bundled match for
        /// its cool, desaturated palette.
        let codeHighlightThemeName = "nord"

        // Tier 1 — Core (Spotify Palette)
        let primaryBackground: Color = Color(hex: "#121212")        // Pure Spotify Dark
        let secondaryBackground: Color = Color(hex: "#181818")      // Slightly lighter for cards/menus
        let tertiaryBackground: Color = Color(hex: "#282828")       // Hover/Selection tint

        let primaryText: Color = .white                             // Crisp white for title
        let secondaryText: Color = Color(hex: "#b3b3b3")           // Soft gray for metadata
        let tertiaryText: Color = Color(hex: "#535353")            // Muted text

        let accentColor: Color = Color(hex: "#1DB954")              // Spotify Green
        let dividerColor: Color = Color(hex: "#282828")
        let selectionColor: Color = Color(hex: "#282828")

        let errorColor: Color = Color(hex: "#e91429")              // Spotify error red
        let successColor: Color = Color(hex: "#1DB954")
        let warningColor: Color = Color(hex: "#ffa500")

        // Tier 2 — Overrides
        var controlBackground: Color { Color(hex: "#181818") }
        var textBackground: Color { Color(hex: "#121212") }
        var placeholderText: Color { Color(hex: "#b3b3b3") }
        var controlAccent: Color { Color(hex: "#1DB954") }
        var userBubbleBackground: Color { Color(hex: "#1DB954") }
        var inlineCodeHighlight: Color { Color(hex: "#1DB954") }    // Spotify Green
        var codeBlockHeaderBackground: Color { Color(hex: "#181818") }
        var codeBlockEditorBackground: Color { Color(hex: "#0c0c0c") } // Even darker for contrast
        var surfaceOverlay: Color { Color.white.opacity(0.05) }
        var surfaceOverlayStrong: Color { Color.white.opacity(0.1) }
        var streamingIndicator: Color { Color(hex: "#1DB954") }
        var chatGPTGradientTop: Color { Color(hex: "#1e1e1e") }
        var chatGPTGradientBottom: Color { Color(hex: "#121212") }

        // Syntax — Modern Dark palette
        var syntaxTheme: SyntaxTheme {
            SyntaxTheme(
                background: NSColor(hex: "#0c0c0c"),
                lineHighlight: NSColor(hex: "#181818"),
                selection: NSColor(hex: "#282828"),
                text: NSColor(hex: "#f8f8f2"),
                keywords: NSColor(hex: "#1DB954"),          // Green for keywords
                commands: NSColor(hex: "#8be9fd"),
                types: NSColor(hex: "#50fa7b"),
                attributes: NSColor(hex: "#ff79c6"),
                variables: NSColor(hex: "#f8f8f2"),
                values: NSColor(hex: "#bd93f9"),
                numbers: NSColor(hex: "#bd93f9"),
                strings: NSColor(hex: "#f1fa8c"),
                characters: NSColor(hex: "#f1fa8c"),
                comments: NSColor(hex: "#b3b3b3"),          // Gray for comments
                bracketHighlight: NSColor(hex: "#1DB954").withAlphaComponent(0.4)
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
