// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  DynamicIslandComponents.swift
//  Devgentic
//
//  Shared primitives used inside DynamicIslandBar:
//   - IslandSearchField : unified search field (one shape, one border, one font).
//   - IslandIconButton  : 28×28 circular affordance with hover, matches the back button.
//   - islandCircleAffordance(): modifier for non-Button affordances (Menu labels) to
//     pick up the same visual footprint without hover.
//

import SwiftUI

// MARK: - IslandSearchField

/// Unified search field for use inside DynamicIslandBar. Replaces the three divergent
/// implementations that previously lived in the Tool Library and Model Store containers.
struct IslandSearchField: View {

    @Binding var text: String
    let placeholder: String
    /// Maximum width the search field will occupy. Minimum 140pt so it stays usable
    /// on narrow windows without collapsing into an icon-only state.
    var maxWidth: CGFloat = 340
    /// When true, the field grabs keyboard focus on appear. Use for the primary
    /// search surface on a view (e.g. Tool Library, Model Stores).
    var autoFocus: Bool = false
    /// When true, the leading magnifying-glass icon is replaced with a progress
    /// spinner. Use to indicate an async search is in flight.
    var isSearching: Bool = false
    /// Stable identifier for UI tests and VoiceOver rotor navigation.
    var accessibilityIdentifier: String = "island.search"
    var onSubmit: (() -> Void)? = nil
    /// Optional collapse callback invoked when the user dismisses the search via Esc
    /// (when text is empty) or taps the trailing close button.
    var onCollapse: (() -> Void)? = nil

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isSearching {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(theme.secondaryText)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(.caption, weight: .bold))
                        .imageScale(.medium)
                        .foregroundColor(isFocused ? theme.accentColor : theme.secondaryText)
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)

            TextField(
                "",
                text: $text,
                prompt: Text(placeholder).foregroundColor(theme.placeholderText)
            )
            .textFieldStyle(.plain)
            .font(theme.fontSubheadline)
            .foregroundColor(theme.primaryText)
            .focused($isFocused)
            .onSubmit { onSubmit?() }
            .onExitCommand {
                if !text.isEmpty {
                    text = ""
                } else {
                    onCollapse?()
                }
            }
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityLabel(Text(placeholder))
            .accessibilityValue(isSearching ? Text("Searching") : Text(text))

            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(.caption))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            } else if let onCollapse {
                Button {
                    onCollapse()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close search (Esc)")
                .accessibilityLabel("Close search")
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28) // matches IslandIconButton height for rhythm
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surfaceOverlayStrong.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isFocused ? theme.accentColor : theme.surfaceOverlayStrong.opacity(0.7),
                    lineWidth: isFocused ? 1.5 : 0.5
                )
        )
        .shadow(
            color: isFocused ? theme.accentColor.opacity(0.25) : Color.clear,
            radius: isFocused ? 6 : 0,
            x: 0,
            y: 1
        )
        .frame(minWidth: 140, maxWidth: maxWidth)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: text.isEmpty)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isFocused)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isSearching)
        .background(focusShortcutButton)
        .onAppear {
            if autoFocus {
                DispatchQueue.main.async {
                    isFocused = true
                }
            }
        }
    }

    /// Invisible button that catches ⌘F and moves focus into the text field.
    /// `.hidden()` keeps it in the layout tree so the keyboard shortcut stays
    /// live, but it has zero visual footprint.
    @ViewBuilder
    private var focusShortcutButton: some View {
        Button("Focus search field") {
            isFocused = true
        }
        .keyboardShortcut("f", modifiers: .command)
        .hidden()
        .accessibilityHidden(true)
    }
}

// MARK: - IslandExpandableSearchHeader

/// Reusable center header for DynamicIslandBar that smoothly morphs between an
/// authoritative section title (`IslandTitleLabel`) in rest state and an enhanced
/// search input (`IslandSearchField`) in active state.
struct IslandExpandableSearchHeader: View {

    let title: LocalizedStringKey
    var icon: String? = nil
    @Binding var text: String
    let placeholder: String
    @Binding var isExpanded: Bool
    var maxWidth: CGFloat = 340
    var isSearching: Bool = false
    var accessibilityIdentifier: String = "island.search"
    var onSubmit: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        title: LocalizedStringKey,
        icon: String? = nil,
        text: Binding<String>,
        placeholder: String,
        isExpanded: Binding<Bool>,
        maxWidth: CGFloat = 340,
        isSearching: Bool = false,
        accessibilityIdentifier: String = "island.search",
        onSubmit: (() -> Void)? = nil
    ) {
        self.title = title
        self.icon = icon
        self._text = text
        self.placeholder = placeholder
        self._isExpanded = isExpanded
        self.maxWidth = maxWidth
        self.isSearching = isSearching
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onSubmit = onSubmit
    }

    init(
        title: String,
        icon: String? = nil,
        text: Binding<String>,
        placeholder: String,
        isExpanded: Binding<Bool>,
        maxWidth: CGFloat = 340,
        isSearching: Bool = false,
        accessibilityIdentifier: String = "island.search",
        onSubmit: (() -> Void)? = nil
    ) {
        self.init(
            title: LocalizedStringKey(title),
            icon: icon,
            text: text,
            placeholder: placeholder,
            isExpanded: isExpanded,
            maxWidth: maxWidth,
            isSearching: isSearching,
            accessibilityIdentifier: accessibilityIdentifier,
            onSubmit: onSubmit
        )
    }

    var body: some View {
        Group {
            if isExpanded {
                IslandSearchField(
                    text: $text,
                    placeholder: placeholder,
                    maxWidth: maxWidth,
                    autoFocus: true,
                    isSearching: isSearching,
                    accessibilityIdentifier: accessibilityIdentifier,
                    onSubmit: onSubmit,
                    onCollapse: {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82)) {
                            isExpanded = false
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.95)),
                    removal: .opacity.combined(with: .scale(scale: 0.95))
                ))
            } else {
                IslandTitleLabel(title: title, icon: icon)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.95)),
                        removal: .opacity.combined(with: .scale(scale: 0.95))
                    ))
            }
        }
    }
}

// MARK: - IslandSearchToggleButton

/// Circular 28×28 action button for DynamicIslandBar trailing rows.
/// Appears when search is collapsed and provides both click and ⌘F activation to expand search.
struct IslandSearchToggleButton: View {

    @Binding var isExpanded: Bool
    var help: String = "Search (⌘F)"
    var accessibilityLabel: String = "Search"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !isExpanded {
            IslandIconButton(
                symbol: "magnifyingglass",
                help: help,
                accessibilityLabel: accessibilityLabel,
                keyboardShortcut: KeyboardShortcut("f", modifiers: .command)
            ) {
                withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82)) {
                    isExpanded = true
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }
}

// MARK: - IslandPillButton

/// Visual variant for IslandPillButton.
enum IslandPillStyle {
    /// Solid accent capsule, white label — primary CTA (Save, Confirm).
    case primary
    /// `surfaceOverlay` background, `primaryText` label — standard action (Revert, Edit).
    case secondary
    /// Accent-tinted background with accent label — prominent but soft (Analyze, Clear History).
    case subtle
    /// Solid success (green) capsule — on-brand confirmation CTA.
    case success
}

/// Text-based action button for DynamicIslandBar trailing slots. Replaces the
/// hand-rolled `Text + padding + Capsule().fill(theme.…)` pattern duplicated
/// across ~7 views. Icon is optional and leads the label. Supports `isLoading`
/// to swap the icon for a spinner without shifting layout dramatically.
struct IslandPillButton: View {

    let title: String
    var icon: String? = nil
    var style: IslandPillStyle = .secondary
    var help: String? = nil
    var accessibilityLabel: String? = nil
    var keyboardShortcut: KeyboardShortcut? = nil
    /// When true, replaces the leading icon/label with a progress spinner and
    /// disables interaction.
    var isLoading: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @State private var feedbackTick: Int = 0
    @FocusState private var isFocused: Bool
    @Environment(\.appTheme) private var theme
    @Environment(\.buttonAccentStyle) private var buttonAccentStyle
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            feedbackTick &+= 1
            action()
        } label: {
            HStack(spacing: 5) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(foregroundColor)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(.caption2, weight: .bold))
                        .imageScale(.small)
                }
                Text(title)
                    .font(.system(.caption, weight: fontWeight))
                    .lineLimit(1)
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: strokeColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isFocused ? 1.5 : 0.5
                    )
            )
            .shadow(color: theme.shadowColor.opacity(isHovered ? 0.3 : 0.15), radius: 6, y: 2)
            .opacity(isEnabled ? 1.0 : 0.45)
            .scaleEffect(shouldScale ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovered)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isFocused)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .disabled(isLoading)
        .modifier(ConditionalHelpModifier(help: help))
        .modifier(ConditionalKeyboardShortcutModifier(shortcut: keyboardShortcut))
        .accessibilityLabel(resolvedAccessibilityLabel)
        .sensoryFeedback(.selection, trigger: feedbackTick)
    }

    private var shouldScale: Bool {
        isHovered && isEnabled && !reduceMotion && !isLoading
    }

    private var resolvedAccessibilityLabel: Text {
        if let accessibilityLabel { return Text(accessibilityLabel) }
        return Text(title)
    }

    private var fontWeight: Font.Weight {
        switch style {
        case .primary, .success: return .semibold
        case .secondary, .subtle: return .medium
        }
    }

    private var horizontalPadding: CGFloat {
        switch style {
        case .primary, .success: return 14
        case .secondary, .subtle: return 12
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:
            if buttonAccentStyle == .themeContrast {
                return theme.isDark ? Color(red: 0.08, green: 0.08, blue: 0.08) : .white
            }
            return theme.isAccentLight ? Color(red: 0.08, green: 0.08, blue: 0.08) : .white
        case .success:
            return .white
        case .secondary:
            return isHovered ? (buttonAccentStyle == .themeContrast ? theme.primaryText : theme.accentColor) : theme.primaryText
        case .subtle:
            return buttonAccentStyle == .themeContrast ? (isHovered ? theme.primaryText : theme.secondaryText) : theme.accentColor
        }
    }

    private var strokeColors: [Color] {
        switch style {
        case .primary:
            if buttonAccentStyle == .themeContrast {
                return theme.isDark
                    ? [Color.white.opacity(isHovered ? 0.4 : 0.2), Color.white.opacity(0.1)]
                    : [Color.black.opacity(isHovered ? 0.3 : 0.15), Color.black.opacity(0.08)]
            }
            if theme.isAccentLight {
                return [theme.dividerColor.opacity(isHovered ? 0.8 : 0.4), theme.dividerColor.opacity(0.3)]
            }
            return [Color.white.opacity(isHovered ? 0.4 : 0.25), theme.accentColor.opacity(0.4)]
        case .success:
            return [Color.white.opacity(isHovered ? 0.4 : 0.25), theme.successColor.opacity(0.4)]
        case .secondary:
            if buttonAccentStyle == .themeContrast {
                return [isHovered ? theme.primaryText.opacity(0.4) : theme.surfaceOverlayStrong, theme.surfaceOverlay]
            }
            return [isHovered ? theme.accentColor.opacity(0.3) : theme.surfaceOverlayStrong, theme.surfaceOverlay]
        case .subtle:
            if buttonAccentStyle == .themeContrast {
                return [isHovered ? theme.secondaryText.opacity(0.3) : Color.clear, Color.clear]
            }
            return [theme.accentColor.opacity(0.4), theme.accentColor.opacity(0.15)]
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary:
            if buttonAccentStyle == .themeContrast {
                return theme.isDark
                    ? Color.white.opacity(isHovered ? 1.0 : 0.95)
                    : Color(red: 0.12, green: 0.12, blue: 0.14).opacity(isHovered ? 1.0 : 0.95)
            }
            return theme.accentColor.opacity(isHovered ? 1.0 : 0.9)
        case .success:
            return theme.successColor.opacity(isHovered ? 1.0 : 0.9)
        case .secondary:
            return isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay
        case .subtle:
            if buttonAccentStyle == .themeContrast {
                return isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay
            }
            return theme.accentColor.opacity(isHovered ? 0.22 : 0.12)
        }
    }
}

// MARK: - IslandIconButton

/// Visual variant for IslandIconButton.
enum IslandIconButtonStyle {
    /// Transparent background that tints on hover. Default for trailing actions.
    case ghost
    /// Persistent accent tint. Used for the always-present back button or primary CTAs.
    case prominent
    /// Semantic error treatment. Used for Delete / destructive actions.
    case destructive
}

/// 28×28 circular icon button with hover affordance. Unifies the tap-target size
/// across all trailing actions and the back button.
struct IslandIconButton: View {

    let symbol: String
    var style: IslandIconButtonStyle = .ghost
    /// When true, forces the foreground/background to the accent "on" state (e.g. toggle selected).
    var isActive: Bool = false
    /// Tooltip (mouse hover). If `accessibilityLabel` is nil, also used as the VoiceOver label.
    var help: String? = nil
    /// Explicit VoiceOver label. Falls back to `help` when nil. Set when the button
    /// symbol is not self-explanatory and the tooltip is not descriptive enough.
    var accessibilityLabel: String? = nil
    /// Optional keyboard shortcut (e.g. `.defaultAction` for ⌘Return, `.cancelAction` for esc).
    var keyboardShortcut: KeyboardShortcut? = nil
    /// When true, replaces the icon with a progress spinner and disables interaction.
    /// Use for refresh/sync buttons that trigger async work.
    var isLoading: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @State private var feedbackTick: Int = 0
    @FocusState private var isFocused: Bool
    @Environment(\.appTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            feedbackTick &+= 1
            action()
        } label: {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(foregroundColor)
                } else {
                    Image(systemName: symbol)
                        .font(.system(.caption, weight: .bold))
                        .imageScale(.medium)
                        .foregroundColor(foregroundColor)
                }
            }
            .frame(width: 28, height: 28)
            .background(Circle().fill(backgroundColor))
            .overlay(
                // Focus ring takes precedence; active state shows a subtle accent border.
                Circle().strokeBorder(overlayStrokeColor, lineWidth: overlayStrokeWidth)
            )
            .scaleEffect(shouldScale ? 1.08 : 1.0)
            .opacity(isEnabled ? 1.0 : 0.4)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .focusEffectDisabled() // we draw our own focus ring above
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovered)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isFocused)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isActive)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .disabled(isLoading)
        .modifier(ConditionalHelpModifier(help: help))
        .modifier(ConditionalKeyboardShortcutModifier(shortcut: keyboardShortcut))
        .accessibilityLabel(resolvedAccessibilityLabel)
        .accessibilityValue(isLoading ? Text("Loading") : Text(""))
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .sensoryFeedback(style == .destructive ? .warning : .selection, trigger: feedbackTick)
    }

    private var overlayStrokeColor: Color {
        if isFocused { return theme.accentColor }
        if isActive && style == .ghost { return theme.accentColor.opacity(0.45) }
        return .clear
    }

    private var overlayStrokeWidth: CGFloat {
        if isFocused { return 2 }
        if isActive && style == .ghost { return 1 }
        return 0
    }

    private var resolvedAccessibilityLabel: Text {
        if let accessibilityLabel { return Text(accessibilityLabel) }
        if let help { return Text(help) }
        return Text(symbol)
    }

    private var shouldScale: Bool { isHovered && isEnabled && !reduceMotion && !isLoading }

    private var foregroundColor: Color {
        switch style {
        case .ghost:
            if isActive { return theme.accentColor }
            return isHovered ? theme.accentColor : theme.primaryText
        case .prominent:
            return theme.accentColor
        case .destructive:
            return isHovered ? .white : theme.errorColor
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .ghost:
            // Active > hover > rest; each step is a clear visual increment.
            if isActive { return theme.accentColor.opacity(isHovered ? 0.30 : 0.24) }
            return isHovered ? theme.accentColor.opacity(0.12) : .clear
        case .prominent:
            return theme.accentColor.opacity(isHovered ? 0.22 : 0.14)
        case .destructive:
            return isHovered ? theme.errorColor : theme.errorColor.opacity(0.14)
        }
    }
}

// MARK: - Conditional help modifier

private struct ConditionalHelpModifier: ViewModifier {
    let help: String?

    func body(content: Content) -> some View {
        if let help = help {
            content.help(help)
        } else {
            content
        }
    }
}

private struct ConditionalKeyboardShortcutModifier: ViewModifier {
    let shortcut: KeyboardShortcut?

    func body(content: Content) -> some View {
        if let shortcut = shortcut {
            content.keyboardShortcut(shortcut)
        } else {
            content
        }
    }
}

// MARK: - GlassActionButton

/// A sleek, elevated glass action pill button for detail card headers and section controls.
struct GlassActionButton: View {
    let title: String
    var icon: String? = nil
    var isAccent: Bool = true
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(theme.accentColor)
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isHovered ? theme.accentColor.opacity(0.45) : theme.secondaryText.opacity(0.18),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isHovered ? theme.accentColor.opacity(0.15) : Color.black.opacity(0.08),
                radius: isHovered ? 4 : 2,
                x: 0,
                y: 1
            )
            .scaleEffect(isHovered ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - islandCircleAffordance

/// Applies the same 28×28 circular visual footprint used by IslandIconButton to
/// non-Button content (e.g. a Menu label). No hover animation — this is purely
/// the static visual so affordances line up next to real buttons.
extension View {
    func islandCircleAffordance(active: Bool = false) -> some View {
        modifier(IslandCircleAffordanceModifier(active: active))
    }
}

private struct IslandCircleAffordanceModifier: ViewModifier {
    let active: Bool
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content
            .font(.system(.caption, weight: .bold))
            .imageScale(.medium)
            .foregroundColor(active ? theme.accentColor : theme.primaryText)
            .frame(width: 28, height: 28)
            .background(Circle().fill(active ? theme.accentColor.opacity(0.24) : .clear))
            .overlay(
                Circle().strokeBorder(
                    active ? theme.accentColor.opacity(0.45) : .clear,
                    lineWidth: active ? 1 : 0
                )
            )
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}
