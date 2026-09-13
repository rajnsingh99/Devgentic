// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    case spotify = "spotify"
    case purple = "purple"
    case orange = "orange"
    case pink = "pink"
    case modernSpotify = "modern_spotify"
    case white = "white"
    case grey = "grey"
    case black = "black"

    init?(rawValue: String) {
        switch rawValue {
        case "default": self = .default
        case "blue": self = .blue
        case "green": self = .green
        case "spotify", "spotify_green": self = .spotify
        case "purple": self = .purple
        case "orange": self = .orange
        case "pink": self = .pink
        case "modern_spotify", "cosmic_cyan", "cyan": self = .modernSpotify
        case "white", "pure_white", "studio_white": self = .white
        case "grey", "gray", "slate_grey", "slate_gray": self = .grey
        case "black", "onyx_black", "jet_black", "pure_black": self = .black
        default: return nil
        }
    }

    var color: Color? {
        switch self {
        case .default: return nil
        case .blue: return Color(hex: "#0A84FF")          // Electric Azure
        case .green: return Color(hex: "#10B981")         // Emerald Mint
        case .spotify: return Color(hex: "#1DB954")       // Spotify Green
        case .purple: return Color(hex: "#8B5CF6")        // Royal Violet
        case .orange: return Color(hex: "#F59E0B")        // Warm Amber
        case .pink: return Color(hex: "#EC4899")          // Rose Quartz
        case .modernSpotify: return Color(hex: "#06B6D4") // Cosmic Cyan
        case .white: return Color(hex: "#FFFFFF")         // Pure White
        case .grey: return Color(hex: "#8E8E93")          // Slate Grey
        case .black: return Color(hex: "#000000")         // Onyx Black
        }
    }

    var nsColor: NSColor? {
        switch self {
        case .default: return nil
        case .blue: return NSColor(hex: "#0A84FF")
        case .green: return NSColor(hex: "#10B981")
        case .spotify: return NSColor(hex: "#1DB954")
        case .purple: return NSColor(hex: "#8B5CF6")
        case .orange: return NSColor(hex: "#F59E0B")
        case .pink: return NSColor(hex: "#EC4899")
        case .modernSpotify: return NSColor(hex: "#06B6D4")
        case .white: return NSColor(hex: "#FFFFFF")
        case .grey: return NSColor(hex: "#8E8E93")
        case .black: return NSColor(hex: "#000000")
        }
    }

    var displayName: String {
        switch self {
        case .default: return "Default"
        case .blue: return "Ocean Blue"
        case .green: return "Emerald Mint"
        case .spotify: return "Spotify Green"
        case .purple: return "Royal Violet"
        case .orange: return "Warm Amber"
        case .pink: return "Rose Quartz"
        case .modernSpotify: return "Cosmic Cyan"
        case .white: return "Pure White"
        case .grey: return "Slate Grey"
        case .black: return "Onyx Black"
        }
    }
}

// MARK: - Theme Decorator (For Global Overrides)

/// A decorator that wraps a base theme and overrides specific properties,
/// such as the accent color, without modifying the base theme's definition.
struct ThemeDecorator: Theme {
    let base: any Theme
    let accentColorOverride: AppAccentColor
    let codeThemeOverride: CodeViewerThemeOverride

    init(base: any Theme, accentColorOverride: AppAccentColor, codeThemeOverride: CodeViewerThemeOverride = .default) {
        self.base = base
        self.accentColorOverride = accentColorOverride
        self.codeThemeOverride = codeThemeOverride
    }

    var accentOverride: Color? { accentColorOverride.color }

    /// The theme from which code blocks and syntax highlighting derive their styling.
    var effectiveCodeTheme: any Theme {
        switch codeThemeOverride {
        case .default: return base
        case .material: return AppThemes.MaterialTheme()
        case .cosmicDark: return AppThemes.CosmicDarkTheme()
        case .oneLight: return AppThemes.OneLightTheme()
        case .solarizedLight: return AppThemes.SolarizedLightTheme()
        }
    }

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
    var isAccentLight: Bool {
        switch accentColorOverride {
        case .white: return true
        default: return false
        }
    }
    var dividerColor: Color { base.dividerColor }
    var selectionColor: Color { base.selectionColor }

    // Tier 1 — Semantic
    var errorColor: Color { base.errorColor }
    var successColor: Color { base.successColor }
    var warningColor: Color { base.warningColor }
    var colorScheme: ColorScheme? { base.colorScheme }
    var isDark: Bool { base.isDark }

    // Tier 2 — Extended (Defaults provided by protocol extension, but we forward base)
    var controlBackground: Color { base.controlBackground }
    var textBackground: Color { base.textBackground }
    var placeholderText: Color { base.placeholderText }
    var controlAccent: Color { accentOverride ?? base.controlAccent }
    var userBubbleBackground: Color { accentOverride ?? base.userBubbleBackground }
    var inlineCodeHighlight: Color { accentColor }
    var accentMuted: Color { accentColor.opacity(0.7) }
    var codeBlockHeaderBackground: Color { effectiveCodeTheme.codeBlockHeaderBackground }
    var codeBlockEditorBackground: Color { effectiveCodeTheme.codeBlockEditorBackground }
    var codeBlockHeaderText: Color { effectiveCodeTheme.codeBlockHeaderText }
    var codeBlockHeaderSecondaryText: Color { effectiveCodeTheme.codeBlockHeaderSecondaryText }
    var surfaceOverlay: Color { base.surfaceOverlay }
    var surfaceOverlayStrong: Color { base.surfaceOverlayStrong }
    var streamingIndicator: Color { accentOverride ?? base.streamingIndicator }
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
    // ⚠️ Required for CORRECTNESS, not compilation: `ThemeDecorator` is hand-forwarded per token,
    // and an unforwarded token still COMPILES (the protocol extension covers it) while silently
    // serving the DEFAULT instead of the base theme's override.
    func nodeIdentityColor(for role: WorkflowNodeRole) -> Color { base.nodeIdentityColor(for: role) }

    // Syntax Highlighting
    var syntaxTheme: SyntaxTheme {
        effectiveCodeTheme.syntaxTheme.patched(with: accentColorOverride.nsColor)
    }

    /// Routed through effectiveCodeTheme so code blocks in chat and the code viewer match.
    var codeHighlightThemeName: String { effectiveCodeTheme.codeHighlightThemeName }
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

    /// Returns a new SyntaxTheme with the bracket highlight color overridden by the accent color,
    /// preserving the language's authentic keyword palette.
    func patched(with accent: NSColor?) -> SyntaxTheme {
        guard let accent = accent else { return self }
        return SyntaxTheme(
            background: background,
            lineHighlight: lineHighlight,
            selection: selection,
            text: text,
            keywords: keywords,
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
    /// Whether the effective accent color is light (e.g. Pure White), requiring dark foreground text on CTAs.
    var isAccentLight: Bool { get }
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
    var isDark: Bool { get }

    /// Accent color for an agent-capability surface (planning / reflection / delegation /
    /// compaction). Single source of truth for the capability hues used by the timeline
    /// milestone chips and the plan/reflection progress cards.
    func capabilityColor(for category: CapabilityMilestoneKind.MilestoneColor) -> Color

    /// Identity colour for a structural workflow node kind. Single source for the canvas card, its
    /// ports, its edges, the Add-node palette and the guideline legend (WF-CU10).
    ///
    /// ⚠️ Deliberately NOT derived from `errorColor` / `warningColor` / `successColor` /
    /// `accentColor`: those already carry RUN STATUS on the same cards, so reusing them would make
    /// "this is a Gate" and "this failed" the same colour on the same card.
    func nodeIdentityColor(for role: WorkflowNodeRole) -> Color

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

    /// Foreground text color for the code block header bar.
    var codeBlockHeaderText: Color { get }

    /// Secondary text color for the code block header bar (e.g. line count, metadata).
    var codeBlockHeaderSecondaryText: Color { get }

    /// Subtle overlay used for hover states and surface tints.
    var surfaceOverlay: Color { get }

    /// Stronger overlay for borders and active states.
    var surfaceOverlayStrong: Color { get }

    /// Color used for streaming / "thinking" indicators.
    var streamingIndicator: Color { get }

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

// MARK: - Workflow Node Identity Ramp (WF-CU10)

/// The hues behind `Theme.nodeIdentityColor(for:)`.
///
/// ⚠️ THIS CANNOT BE ONE FIXED SET OF HUES, and that is the whole of WF-CU10. The node card's fill
/// is `controlBackground`, and the themes put it at opposite ends of the luminance range: OneLight
/// `#f0f0f0` (relative luminance 0.871) versus Dracula `#383A59` (0.046), with DefaultTheme's
/// `.controlBackgroundColor` following the system appearance.
///
/// REASON for the split, measured: a colour clearing the WCAG 1.4.11 3:1 component bar against
/// Dracula's card needs relative luminance L ≥ 0.238; clearing 3:1 against OneLight's needs
/// L ≤ 0.257. That ~0.02-wide window also conflicts with the L ≤ 0.183 a white glyph drawn ON the
/// colour would need. So there is no single ramp, and the branch below is not a preference.
///
/// ⚠️ The DARK arm is today's five values VERBATIM. Dracula, OneDark, CosmicDark and DefaultTheme
/// in Dark Mode must not move — those hues already clear 3:1 on their own cards. Only the light arm
/// is new, which is exactly where the defect lives: SwiftUI's `.yellow` on `#f0f0f0` measures
/// **1.33:1**, i.e. an unselected Router's only edge was effectively invisible.
enum WorkflowNodeIdentityRamp {

    /// Today's hues. Do not "improve" these without re-checking Dracula's `#383A59` card.
    static func dark(_ role: WorkflowNodeRole) -> Color {
        switch role {
        case .router:  return .yellow
        case .code:    return .cyan
        case .gate:    return .red
        case .trigger: return .gray
        case .action:  return .teal
        }
    }

    /// Light-surface ramp. Every hue clears the 4.5:1 TEXT bar against OneLight's `#f0f0f0` card —
    /// the stricter of the two bars, needed because some of these are drawn as small text, not only
    /// as strokes and glyphs.
    ///
    /// Measured against `#f0f0f0`: router 6.22:1 · code 4.70:1 · gate 5.68:1 · action 4.80:1 ·
    /// trigger 6.65:1. Against pure white each is higher still.
    static func lightHex(_ role: WorkflowNodeRole) -> String {
        switch role {
        case .router:  return "#92400E"   // amber
        case .code:    return "#0E7490"   // cyan
        case .gate:    return "#B91C1C"   // red
        case .action:  return "#0F766E"   // teal
        case .trigger: return "#475569"   // slate — an inert marker, deliberately neutral
        }
    }

    /// For a theme with NO declared light/dark intent (`colorScheme == nil`), which follows the
    /// system appearance. A dynamic `NSColor` is the only mechanism that re-resolves when the user
    /// flips Light/Dark without the app rebuilding its themes.
    static func systemAdaptive(_ role: WorkflowNodeRole) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark(role))
                : NSColor(Color(hex: lightHex(role)))
        })
    }
}

/// Default values for all Tier 2 / Tier 3 tokens. Existing themes compile
/// with zero changes; any theme may selectively override.
extension Theme {

    // ── Light/Dark Default ───────────────────────────────────────────

    /// Default to system appearance — concrete themes with a clear
    /// light/dark intent (Dracula, OneDark, OneLight, etc.) override this.
    var colorScheme: ColorScheme? { nil }
    var isDark: Bool { colorScheme != .light }
    var isAccentLight: Bool { false }

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
    var codeBlockHeaderText: Color {
        codeHighlightThemeName.contains("light") ? Color(hex: "#383a42") : Color(hex: "#f8f8f2")
    }
    var codeBlockHeaderSecondaryText: Color {
        codeHighlightThemeName.contains("light") ? Color(hex: "#696c77") : Color(hex: "#8b949e")
    }
    var surfaceOverlay: Color { Color.white.opacity(0.06) }
    var surfaceOverlayStrong: Color { Color.white.opacity(0.1) }
    var streamingIndicator: Color { .blue }
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

    /// Defaults branch on the theme's own light/dark intent — see `WorkflowNodeIdentityRamp` for
    /// why one fixed ramp is not available. A theme may still override to substitute its palette.
    func nodeIdentityColor(for role: WorkflowNodeRole) -> Color {
        if colorScheme == .light { return Color(hex: WorkflowNodeIdentityRamp.lightHex(role)) }
        if colorScheme == .dark  { return WorkflowNodeIdentityRamp.dark(role) }
        return WorkflowNodeIdentityRamp.systemAdaptive(role)
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




// MARK: - Material Theme

extension AppThemes {
    struct MaterialTheme: Theme {
        let id = "material"
        let displayName = "Material Darker"
        let colorScheme: ColorScheme? = .dark
        /// Highlightr bundles the real Material Darker palette.
        let codeHighlightThemeName = "material-darker"

        // Tier 1 — Core (Material Darker Charcoal Palette)
        let primaryBackground: Color = Color(hex: "#212121")
        let secondaryBackground: Color = Color(hex: "#1a1a1a")
        let tertiaryBackground: Color = Color(hex: "#2c2c2c")

        let primaryText: Color = Color(hex: "#eeffff")
        let secondaryText: Color = Color(hex: "#b0bec5")
        let tertiaryText: Color = Color(hex: "#546e7a")

        let accentColor: Color = Color(hex: "#80cbc4") // Material Teal
        let dividerColor: Color = Color(hex: "#303030")
        let selectionColor: Color = Color(hex: "#353535")

        let errorColor: Color = Color(hex: "#ff5370")
        let successColor: Color = Color(hex: "#c3e88d")
        let warningColor: Color = Color(hex: "#ffcb6b")

        // Tier 2 — Material-specific overrides
        var controlBackground: Color { Color(hex: "#2c2c2c") }
        var textBackground: Color { Color(hex: "#212121") }
        var placeholderText: Color { Color(hex: "#546e7a") }
        var controlAccent: Color { Color(hex: "#80cbc4") }
        var userBubbleBackground: Color { Color(hex: "#80cbc4") }
        var inlineCodeHighlight: Color { Color(hex: "#c792ea") }    // Material Lilac
        var codeBlockHeaderBackground: Color { Color(hex: "#1a1a1a") }
        var codeBlockEditorBackground: Color { Color(hex: "#212121") }
        var surfaceOverlay: Color { Color.white.opacity(0.06) }
        var surfaceOverlayStrong: Color { Color.white.opacity(0.1) }
        var streamingIndicator: Color { Color(hex: "#80cbc4") }

        // Syntax — Material Darker palette (matching highlight.js material-darker)
        var syntaxTheme: SyntaxTheme {
            SyntaxTheme(
                background: NSColor(hex: "#212121"),
                lineHighlight: NSColor(hex: "#1a1a1a"),
                selection: NSColor(hex: "#353535"),
                text: NSColor(hex: "#eeffff"),
                keywords: NSColor(hex: "#c792ea"),
                commands: NSColor(hex: "#82aaff"),
                types: NSColor(hex: "#ffcb6b"),
                attributes: NSColor(hex: "#c792ea"),
                variables: NSColor(hex: "#eeffff"),
                values: NSColor(hex: "#f78c6c"),
                numbers: NSColor(hex: "#f78c6c"),
                strings: NSColor(hex: "#c3e88d"),
                characters: NSColor(hex: "#c3e88d"),
                comments: NSColor(hex: "#546e7a"),
                bracketHighlight: NSColor(hex: "#80cbc4").withAlphaComponent(0.4)
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


// MARK: - One Light Theme

extension AppThemes {
    struct OneLightTheme: Theme {
        let id = "one_light"
        let displayName = "One Light"
        let colorScheme: ColorScheme? = .light
        let codeHighlightThemeName = "github"

        // Tier 1 — Core (GitHub Light Palette)
        let primaryBackground: Color = Color(hex: "#ffffff")
        let secondaryBackground: Color = Color(hex: "#f6f8fa")
        let tertiaryBackground: Color = Color(hex: "#eaeef2")

        let primaryText: Color = Color(hex: "#1f2328")
        let secondaryText: Color = Color(hex: "#656d76")
        let tertiaryText: Color = Color(hex: "#8c959f")

        let accentColor: Color = Color(hex: "#0969da")        // GitHub Blue
        let dividerColor: Color = Color(hex: "#d0d7de")
        let selectionColor: Color = Color(hex: "#ddf4ff")

        let errorColor: Color = Color(hex: "#cf222e")
        let successColor: Color = Color(hex: "#1a7f37")
        let warningColor: Color = Color(hex: "#9a6700")

        // Tier 2 — Overrides
        var controlBackground: Color { Color(hex: "#eaeef2") }
        var textBackground: Color { Color(hex: "#ffffff") }
        var placeholderText: Color { Color(hex: "#8c959f") }
        var controlAccent: Color { Color(hex: "#0969da") }
        var userBubbleBackground: Color { Color(hex: "#0969da") }
        var inlineCodeHighlight: Color { Color(hex: "#0969da") }
        var codeBlockHeaderBackground: Color { Color(hex: "#f6f8fa") }
        var codeBlockEditorBackground: Color { Color(hex: "#ffffff") }
        var codeBlockHeaderText: Color { Color(hex: "#1f2328") }
        var codeBlockHeaderSecondaryText: Color { Color(hex: "#656d76") }
        var surfaceOverlay: Color { Color.black.opacity(0.04) }
        var surfaceOverlayStrong: Color { Color.black.opacity(0.08) }
        var streamingIndicator: Color { Color(hex: "#0969da") }
        var shadowColor: Color { Color.black.opacity(0.06) }

        // Syntax — GitHub Light palette (matching highlight.js github.min.css)
        var syntaxTheme: SyntaxTheme {
            SyntaxTheme(
                background: NSColor(hex: "#ffffff"),
                lineHighlight: NSColor(hex: "#f6f8fa"),
                selection: NSColor(hex: "#c8c8fa"),
                text: NSColor(hex: "#24292f"),
                keywords: NSColor(hex: "#a71d5d"),          // Purple
                commands: NSColor(hex: "#795da3"),
                types: NSColor(hex: "#a71d5d"),
                attributes: NSColor(hex: "#795da3"),
                variables: NSColor(hex: "#ed6a43"),
                values: NSColor(hex: "#0086b3"),
                numbers: NSColor(hex: "#0086b3"),
                strings: NSColor(hex: "#183691"),          // Navy
                characters: NSColor(hex: "#183691"),
                comments: NSColor(hex: "#6e7781"),
                bracketHighlight: NSColor(hex: "#0969da").withAlphaComponent(0.4)
            )
        }
    }
}


// MARK: - Solarized Light Theme

extension AppThemes {
    struct SolarizedLightTheme: Theme {
        let id = "solarized_light"
        let displayName = "Solarized Light"
        let colorScheme: ColorScheme? = .light
        let codeHighlightThemeName = "solarized-light"

        // Tier 1 — Core (Solarized Light Cream Palette)
        let primaryBackground: Color = Color(hex: "#fdf6e3")
        let secondaryBackground: Color = Color(hex: "#eee8d5")
        let tertiaryBackground: Color = Color(hex: "#e0d8c3")

        let primaryText: Color = Color(hex: "#586e75")        // Base01
        let secondaryText: Color = Color(hex: "#839496")      // Base00
        let tertiaryText: Color = Color(hex: "#93a1a1")       // Base1

        let accentColor: Color = Color(hex: "#2aa198")        // Solarized Cyan
        let dividerColor: Color = Color(hex: "#d33682").opacity(0.18)
        let selectionColor: Color = Color(hex: "#eee8d5")

        let errorColor: Color = Color(hex: "#dc322f")         // Red
        let successColor: Color = Color(hex: "#859900")       // Green
        let warningColor: Color = Color(hex: "#b58900")       // Yellow

        // Tier 2 — Overrides
        var controlBackground: Color { Color(hex: "#eee8d5") }
        var textBackground: Color { Color(hex: "#fdf6e3") }
        var placeholderText: Color { Color(hex: "#93a1a1") }
        var controlAccent: Color { Color(hex: "#2aa198") }
        var userBubbleBackground: Color { Color(hex: "#2aa198") }
        var inlineCodeHighlight: Color { Color(hex: "#268bd2") }   // Blue
        var codeBlockHeaderBackground: Color { Color(hex: "#eee8d5") }
        var codeBlockEditorBackground: Color { Color(hex: "#fdf6e3") }
        var codeBlockHeaderText: Color { Color(hex: "#586e75") }
        var codeBlockHeaderSecondaryText: Color { Color(hex: "#839496") }
        var surfaceOverlay: Color { Color.black.opacity(0.04) }
        var surfaceOverlayStrong: Color { Color.black.opacity(0.08) }
        var streamingIndicator: Color { Color(hex: "#2aa198") }
        var shadowColor: Color { Color(hex: "#586e75").opacity(0.08) }

        // Syntax — Solarized Light palette (matching highlight.js solarized-light.min.css)
        var syntaxTheme: SyntaxTheme {
            SyntaxTheme(
                background: NSColor(hex: "#fdf6e3"),
                lineHighlight: NSColor(hex: "#eee8d5"),
                selection: NSColor(hex: "#93a1a1"),
                text: NSColor(hex: "#586e75"),
                keywords: NSColor(hex: "#6c71c4"),          // Violet
                commands: NSColor(hex: "#268bd2"),          // Blue
                types: NSColor(hex: "#b58900"),             // Yellow
                attributes: NSColor(hex: "#2aa198"),        // Cyan
                variables: NSColor(hex: "#586e75"),
                values: NSColor(hex: "#cb4b16"),            // Orange
                numbers: NSColor(hex: "#cb4b16"),
                strings: NSColor(hex: "#859900"),           // Green
                characters: NSColor(hex: "#859900"),
                comments: NSColor(hex: "#839496"),
                bracketHighlight: NSColor(hex: "#2aa198").withAlphaComponent(0.4)
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
