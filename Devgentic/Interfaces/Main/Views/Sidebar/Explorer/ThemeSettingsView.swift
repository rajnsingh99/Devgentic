// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ThemeSettingsView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

struct ThemeSettingsView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                
                // MARK: - App Theme Section
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "paintbrush.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.accentColor)

                            Text("APP APPEARANCE")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(1.8)
                                .foregroundColor(theme.secondaryText)
                        }

                        Text("Select a color scheme for the application workspace.")
                            .font(theme.fontSubheadline)
                            .foregroundColor(theme.secondaryText)
                    }

                    HStack(alignment: .top, spacing: 14) {
                        ForEach(themeManager.availableThemes, id: \.id) { appTheme in
                            ThemePreviewCard(
                                previewTheme: appTheme,
                                isSelected: themeManager.currentTheme.id == appTheme.id,
                                currentTheme: theme
                            ) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                    themeManager.applyTheme(appTheme)
                                }
                            }
                        }
                    }
                }

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.25))
                    .frame(height: 1)

                // MARK: - Accent Color Section
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "circle.dotted")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.accentColor)

                            Text("ACCENT COLOR")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(1.8)
                                .foregroundColor(theme.secondaryText)
                        }
                        
                        Text("Personalize interactive controls and active indicators across the app.")
                            .font(theme.fontSubheadline)
                            .foregroundColor(theme.secondaryText)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) {
                            ForEach(AppAccentColor.allCases, id: \.self) { accent in
                                AccentColorCircle(
                                    accent: accent,
                                    isSelected: themeManager.selectedAccentColor == accent,
                                    baseAccentColor: themeManager.baseTheme.accentColor,
                                    appTheme: theme
                                ) {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        themeManager.applyAccentColor(accent)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                    }
                }

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.25))
                    .frame(height: 1)

                // MARK: - Surface Style Section
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.accentColor)

                            Text("SURFACE PRESENTATION")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(1.8)
                                .foregroundColor(theme.secondaryText)
                        }

                        Text("Choose between translucent glass with accent buttons, or solid material with high-contrast buttons.")
                            .font(theme.fontSubheadline)
                            .foregroundColor(theme.secondaryText)
                    }

                    HStack(alignment: .top, spacing: 16) {
                        ForEach(SurfaceStyle.allCases) { style in
                            SurfaceStyleCard(
                                style: style,
                                isSelected: themeManager.surfaceStyle == style,
                                theme: theme
                            ) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                    themeManager.applySurfaceStyle(style)
                                }
                            }
                        }
                    }
                }

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.25))
                    .frame(height: 1)

                // MARK: - Chat Font Section
                // MARK: - Chat Typography Section
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "textformat.size")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.accentColor)

                            Text("CHAT TYPOGRAPHY")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(1.8)
                                .foregroundColor(theme.secondaryText)
                        }

                        Text("Select font family and adjust size for chat messages.")
                            .font(theme.fontSubheadline)
                            .foregroundColor(theme.secondaryText)
                    }

                    VStack(alignment: .leading, spacing: 20) {
                        // Font Family Selector (Equal Distance HStack)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Font Family")
                                .font(theme.fontSubheadline.weight(.semibold))
                                .foregroundColor(theme.primaryText)

                            HStack(alignment: .top, spacing: 14) {
                                ForEach(ChatFontFamily.allCases) { family in
                                    ChatFontFamilyCard(
                                        family: family,
                                        isSelected: themeManager.chatFontFamily == family,
                                        theme: theme
                                    ) {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                            themeManager.applyChatFontFamily(family)
                                        }
                                    }
                                }
                            }
                        }

                        // Premium Font Size Slider
                        PremiumFontSizeSlider(
                            value: Binding(
                                get: { themeManager.chatFontSize },
                                set: { themeManager.applyChatFontSize($0) }
                            ),
                            range: 11...20,
                            defaultValue: 14,
                            theme: theme
                        ) { newSize in
                            themeManager.applyChatFontSize(newSize)
                        }

                        // Reset Button & Preview Hint
                        HStack {
                            Text("Changes immediately update the live conversation preview below.")
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText.opacity(0.8))

                            Spacer()

                            TactileButton(
                                title: "Reset to Default",
                                icon: "arrow.counterclockwise",
                                variant: .subtle,
                                size: .compact,
                                isDisabled: themeManager.chatFontFamily == .system && themeManager.chatFontSize == 14
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    themeManager.applyChatFontFamily(.system)
                                    themeManager.applyChatFontSize(14)
                                }
                            }
                        }
                    }
                }

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.25))
                    .frame(height: 1)

                // MARK: - Code Viewer Section
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.accentColor)

                            Text("CODE SYNTAX THEME")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(1.8)
                                .foregroundColor(theme.secondaryText)
                        }
                        
                        Text("Select a specialized syntax highlighting theme for code blocks and the editor.")
                            .font(theme.fontSubheadline)
                            .foregroundColor(theme.secondaryText)
                    }

                    HStack(alignment: .top, spacing: 14) {
                        ForEach(CodeViewerThemeOverride.allCases, id: \.self) { override in
                            CodeViewerPreviewCard(
                                override: override,
                                isSelected: themeManager.codeViewerThemeOverride == override,
                                appTheme: theme
                            ) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                    themeManager.applyCodeViewerTheme(override)
                                }
                            }
                        }
                    }
                }

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.25))
                    .frame(height: 1)

                // MARK: - Live Preview Section
                InteractiveMiniChatPreviewView()
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }
}

// MARK: - Subviews

struct ThemePreviewCard: View {
    let previewTheme: any Theme
    let isSelected: Bool
    let currentTheme: any Theme
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                // Mock UI Container
                ZStack(alignment: .topLeading) {
                    previewTheme.primaryBackground

                    VStack(alignment: .leading, spacing: 6) {
                        // macOS Window control dots
                        HStack(spacing: 5) {
                            Circle().fill(Color(hex: "#FF5F56")).frame(width: 6, height: 6)
                            Circle().fill(Color(hex: "#FFBD2E")).frame(width: 6, height: 6)
                            Circle().fill(Color(hex: "#27C93F")).frame(width: 6, height: 6)
                        }
                        .padding(.bottom, 4)

                        // Sidebar and content mock
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(previewTheme.secondaryBackground)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 5) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(previewTheme.accentColor)
                                    .frame(width: 44, height: 5)

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(previewTheme.primaryText.opacity(0.25))
                                    .frame(width: 54, height: 5)

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(previewTheme.primaryText.opacity(0.12))
                                    .frame(width: 64, height: 5)
                            }
                        }
                    }
                    .padding(10)
                }
                .aspectRatio(1.5, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isSelected
                                ? currentTheme.accentColor.opacity(0.85)
                                : (isHovered ? currentTheme.secondaryText.opacity(0.35) : currentTheme.secondaryText.opacity(0.15)),
                            lineWidth: isSelected ? 1.5 : 1.0
                        )
                )
                .shadow(
                    color: isSelected
                        ? currentTheme.accentColor.opacity(0.25)
                        : (isHovered ? Color.black.opacity(0.15) : .clear),
                    radius: isSelected ? 8 : 4, y: 2
                )
                .scaleEffect(isHovered ? 1.02 : 1.0)
                .onHover { hovering in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        isHovered = hovering
                    }
                }

                // Title & Selection Badge
                HStack(spacing: 6) {
                    Text(previewTheme.displayName)
                        .font(currentTheme.fontSubheadline.weight(isSelected ? .bold : .medium))
                        .foregroundColor(isSelected ? currentTheme.primaryText : currentTheme.secondaryText)
                    
                    if isSelected {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(currentTheme.accentColor)
                            .font(.system(size: 13, weight: .bold))
                            .shadow(color: currentTheme.accentColor.opacity(0.6), radius: 3)
                    }
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

struct CodeViewerPreviewCard: View {
    let override: CodeViewerThemeOverride
    let isSelected: Bool
    let appTheme: any Theme
    let action: () -> Void

    @State private var isHovered = false

    var previewTheme: any Theme {
        switch override {
        case .cosmicDark: return AppThemes.MaterialTheme()
        case .highContrast: return AppThemes.HighContrastTheme()
        case .oneLight: return AppThemes.OneLightTheme()
        case .solarizedLight: return AppThemes.SolarizedLightTheme()
        }
    }

    var syntaxTheme: SyntaxTheme {
        previewTheme.syntaxTheme
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack(alignment: .topLeading) {
                    Color(nsColor: syntaxTheme.background)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("1").foregroundColor(Color(nsColor: syntaxTheme.comments)).font(.system(size: 8, design: .monospaced))
                            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: syntaxTheme.keywords)).frame(width: 25, height: 5)
                            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: syntaxTheme.types)).frame(width: 35, height: 5)
                        }
                        HStack(spacing: 6) {
                            Text("2").foregroundColor(Color(nsColor: syntaxTheme.comments)).font(.system(size: 8, design: .monospaced))
                            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: syntaxTheme.commands)).frame(width: 30, height: 5)
                            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: syntaxTheme.strings)).frame(width: 50, height: 5)
                        }
                        HStack(spacing: 6) {
                            Text("3").foregroundColor(Color(nsColor: syntaxTheme.comments)).font(.system(size: 8, design: .monospaced))
                            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: syntaxTheme.attributes)).frame(width: 20, height: 5)
                            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: syntaxTheme.variables)).frame(width: 40, height: 5)
                        }
                    }
                    .padding(10)
                    .padding(.top, 4)
                }
                .aspectRatio(1.5, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isSelected
                                ? appTheme.accentColor.opacity(0.85)
                                : (isHovered ? appTheme.secondaryText.opacity(0.35) : appTheme.secondaryText.opacity(0.15)),
                            lineWidth: isSelected ? 1.5 : 1.0
                        )
                )
                .shadow(
                    color: isSelected
                        ? appTheme.accentColor.opacity(0.25)
                        : (isHovered ? Color.black.opacity(0.15) : .clear),
                    radius: isSelected ? 8 : 4, y: 2
                )
                .scaleEffect(isHovered ? 1.02 : 1.0)
                .onHover { hovering in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        isHovered = hovering
                    }
                }

                HStack(spacing: 6) {
                    Text(override.displayName)
                        .font(appTheme.fontSubheadline.weight(isSelected ? .bold : .medium))
                        .foregroundColor(isSelected ? appTheme.primaryText : appTheme.secondaryText)
                        .lineLimit(1)
                    
                    if isSelected {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(appTheme.accentColor)
                            .font(.system(size: 13, weight: .bold))
                            .shadow(color: appTheme.accentColor.opacity(0.6), radius: 3)
                    }
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

struct AccentColorCircle: View {
    let accent: AppAccentColor
    let isSelected: Bool
    let baseAccentColor: Color
    let appTheme: any Theme
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    if accent == .default {
                        Circle()
                            .fill(baseAccentColor)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle()
                                    .strokeBorder(appTheme.dividerColor.opacity(0.5), lineWidth: 0.75)
                            )
                        
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Circle()
                            .fill(accent.color ?? baseAccentColor)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle()
                                    .strokeBorder(appTheme.dividerColor.opacity(0.6), lineWidth: 0.75)
                            )
                            .shadow(color: (accent.color ?? baseAccentColor).opacity(isHovered ? 0.6 : 0.2), radius: isHovered ? 6 : 3)
                    }

                    if isSelected {
                        Circle()
                            .strokeBorder(appTheme.primaryText, lineWidth: 2)
                            .frame(width: 40, height: 40)
                            .shadow(color: appTheme.accentColor.opacity(0.5), radius: 4)
                    } else {
                        Circle()
                            .strokeBorder(
                                isHovered ? appTheme.accentColor.opacity(0.6) : appTheme.surfaceOverlayStrong,
                                lineWidth: isHovered ? 1.5 : 1.0
                            )
                            .frame(width: 40, height: 40)
                    }
                }
                .contentShape(Circle())
                .scaleEffect(isHovered ? 1.08 : 1.0)
                .onHover { hovering in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        isHovered = hovering
                    }
                }
                
                Text(accent.displayName)
                    .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? appTheme.primaryText : appTheme.secondaryText)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Interactive Mini-Chat Preview

struct InteractiveMiniChatPreviewView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appTheme) private var theme

    @State private var selectedLanguage: PreviewLanguage = .swift
    @State private var customUserMessage: String? = nil
    @State private var inputDraft: String = ""

    enum PreviewLanguage: String, CaseIterable {
        case swift = "Swift"
        case python = "Python"
        case typescript = "TypeScript"

        var codeSnippet: String {
            switch self {
            case .swift:
                return """
                func formatCurrency(_ amount: Double) -> String {
                    let formatter = NumberFormatter()
                    formatter.numberStyle = .currency
                    return formatter.string(from: NSNumber(value: amount)) ?? "$0.00"
                }
                """
            case .python:
                return """
                def format_currency(amount: float) -> str:
                    \"\"\"Format numeric amount as localized currency.\"\"\"
                    return f"${amount:,.2f}"
                """
            case .typescript:
                return """
                function formatCurrency(amount: number): string {
                    return new Intl.NumberFormat('en-US', {
                        style: 'currency',
                        currency: 'USD'
                    }).format(amount);
                }
                """
            }
        }

        var defaultUserMessage: String {
            switch self {
            case .swift:
                return "How do I format currency and numbers in Swift?"
            case .python:
                return "How do I format numbers as currency in Python?"
            case .typescript:
                return "How do I format currency in TypeScript?"
            }
        }

        var assistantMessage: String {
            switch self {
            case .swift:
                return "Here is an idiomatic helper using NumberFormatter:"
            case .python:
                return "Here is a clean Python format string implementation:"
            case .typescript:
                return "You can use the native Intl.NumberFormat API:"
            }
        }

        var fileName: String {
            switch self {
            case .swift: return "CurrencyFormatter.swift"
            case .python: return "format_currency.py"
            case .typescript: return "formatCurrency.ts"
            }
        }
    }

    private var activeUserMessage: String {
        customUserMessage ?? selectedLanguage.defaultUserMessage
    }

    private var codeFontSize: CGFloat {
        ChatUIConstants.codeFontSize(forChatFontSize: themeManager.chatFontSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.accentColor)

                    Text("LIVE CONVERSATION PREVIEW")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.8)
                        .foregroundColor(theme.secondaryText)

                    Spacer()

                    // Language Selector Pills
                    HStack(spacing: 6) {
                        ForEach(PreviewLanguage.allCases, id: \.self) { lang in
                            Button {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                    selectedLanguage = lang
                                    customUserMessage = nil
                                }
                            } label: {
                                Text(lang.rawValue)
                                    .font(.system(size: 11, weight: selectedLanguage == lang ? .bold : .medium))
                                    .foregroundColor(selectedLanguage == lang ? theme.accentColor : theme.secondaryText)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(selectedLanguage == lang ? theme.accentColor.opacity(0.15) : theme.surfaceOverlay)
                                    )
                                    .overlay(
                                        Capsule()
                                            .stroke(selectedLanguage == lang ? theme.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Text("Interactive preview reflecting your theme, accent color, chat typography (\(themeManager.chatFontFamily.shortName), \(Int(themeManager.chatFontSize))pt), and code syntax palette.")
                    .font(theme.fontSubheadline)
                    .foregroundColor(theme.secondaryText)
            }

            // Preview Conversation Window Canvas
            VStack(spacing: 16) {
                // Top Mini Window Bar
                HStack(spacing: 6) {
                    Circle().fill(Color.red.opacity(0.7)).frame(width: 8, height: 8)
                    Circle().fill(Color.yellow.opacity(0.7)).frame(width: 8, height: 8)
                    Circle().fill(Color.green.opacity(0.7)).frame(width: 8, height: 8)
                    Spacer()
                    Text("Live Preview • \(theme.displayName) • \(themeManager.chatFontFamily.shortName) • \(selectedLanguage.rawValue)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.secondaryText.opacity(0.7))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                Divider()
                    .background(theme.dividerColor.opacity(0.3))

                // Chat Messages Canvas
                VStack(spacing: 16) {
                    // 1. User Message (Trailing)
                    HStack(alignment: .top, spacing: 10) {
                        Spacer(minLength: 40)

                        Text(activeUserMessage)
                            .font(themeManager.chatFont)
                            .lineSpacing(themeManager.chatLineSpacing)
                            .foregroundColor(theme.primaryText)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .appSurface(
                                in: .rect(cornerRadius: 16),
                                elevation: .card,
                                strokeColor: theme.accentColor.opacity(0.2),
                                solidFillOverride: theme.surfaceOverlayStrong
                            )
                    }

                    // 2. Assistant Message (Leading)
                    HStack(alignment: .top, spacing: 10) {
                        // Bot Avatar
                        ZStack {
                            Circle()
                                .fill(theme.accentColor.opacity(0.18))
                                .frame(width: 26, height: 26)

                            Image(systemName: "sparkles")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.accentColor)
                        }
                        .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Devgentic")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(theme.accentColor)

                            Text(selectedLanguage.assistantMessage)
                                .font(themeManager.chatFont)
                                .lineSpacing(themeManager.chatLineSpacing)
                                .foregroundColor(theme.primaryText)

                            // 3. Fenced Code Block
                            CodeBlockView(
                                language: selectedLanguage.rawValue.lowercased(),
                                content: selectedLanguage.codeSnippet,
                                fileName: selectedLanguage.fileName,
                                fontSize: codeFontSize
                            )
                        }

                        Spacer(minLength: 20)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()
                    .background(theme.dividerColor.opacity(0.3))

                // Interactive Test Composer
                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)

                    TextField("Type custom text to preview your font and bubble...", text: $inputDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(theme.primaryText)
                        .onSubmit(sendCustomMessage)

                    if customUserMessage != nil {
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                customUserMessage = nil
                                inputDraft = ""
                            }
                        } label: {
                            Text("Reset")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: sendCustomMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? theme.secondaryText.opacity(0.3) : theme.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.surfaceOverlay.opacity(0.4))
                .cornerRadius(10)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.secondaryBackground.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(theme.surfaceOverlayStrong, lineWidth: 1)
            )
            .shadow(color: theme.shadowColor.opacity(0.2), radius: 8, x: 0, y: 4)
        }
    }

    private func sendCustomMessage() {
        let trimmed = inputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            customUserMessage = trimmed
            inputDraft = ""
        }
    }
}

// MARK: - Chat Font Family Card

private struct ChatFontFamilyCard: View {
    let family: ChatFontFamily
    let isSelected: Bool
    let theme: any Theme
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(family.sampleGlyph)
                        .font(.system(size: 13, weight: .bold, design: family.design))
                        .foregroundColor(isSelected ? theme.accentColor : theme.primaryText)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? theme.accentColor.opacity(0.15) : theme.surfaceOverlay)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(isSelected ? theme.accentColor.opacity(0.3) : theme.dividerColor.opacity(0.4), lineWidth: 0.75)
                        )

                    Text(family.shortName)
                        .font(theme.fontFootnote.weight(isSelected ? .bold : .semibold))
                        .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.accentColor)
                    }
                }

                Text(family.subtitle)
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? theme.accentColor.opacity(0.08) : (isHovering ? theme.surfaceOverlay : theme.secondaryBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? theme.accentColor.opacity(0.5)
                            : (isHovering ? theme.secondaryText.opacity(0.25) : theme.dividerColor.opacity(0.5)),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Premium Font Size Slider

private struct PremiumFontSizeSlider: View {
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let defaultValue: CGFloat
    let theme: any Theme
    let onCommit: (CGFloat) -> Void

    @State private var isDragging = false
    @State private var isHovering = false

    private var steps: [Int] {
        Array(Int(range.lowerBound)...Int(range.upperBound))
    }

    private var progress: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return (value - range.lowerBound) / span
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header Row: Title & Active Value Pill
            HStack(alignment: .center) {
                Text("Font Size")
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                HStack(spacing: 5) {
                    Text("\(Int(value)) pt")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.accentColor)

                    if Int(value) == Int(defaultValue) {
                        Text("• DEFAULT")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.accentColor.opacity(0.85))
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(
                    Capsule().fill(theme.accentColor.opacity(0.12))
                )
                .overlay(
                    Capsule().strokeBorder(theme.accentColor.opacity(0.25), lineWidth: 0.75)
                )
            }

            // Slider Track Row
            HStack(spacing: 12) {
                // Decrement Button (Small 'A')
                Button {
                    let next = max(range.lowerBound, value - 1)
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        value = next
                    }
                    onCommit(next)
                } label: {
                    Text("A")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(value > range.lowerBound ? theme.secondaryText : theme.tertiaryText.opacity(0.35))
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.surfaceOverlay)
                        )
                }
                .buttonStyle(.plain)
                .disabled(value <= range.lowerBound)
                .help("Decrease font size (\(Int(max(range.lowerBound, value - 1))) pt)")

                // Custom Tactile Track
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let thumbDiameter: CGFloat = isDragging ? 19 : (isHovering ? 17 : 16)
                    let availableWidth = max(1, width - thumbDiameter)
                    let thumbX = progress * availableWidth + (thumbDiameter / 2)

                    ZStack(alignment: .leading) {
                        // Background Track
                        Capsule()
                            .fill(theme.secondaryBackground)
                            .frame(height: 6)
                            .overlay(
                                Capsule()
                                    .strokeBorder(theme.dividerColor.opacity(0.4), lineWidth: 0.75)
                            )

                        // Filled Accent Track
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [theme.accentColor.opacity(0.85), theme.accentColor],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, min(width, thumbX)), height: 6)

                        // Discrete Step Tick Dots
                        HStack(spacing: 0) {
                            ForEach(steps, id: \.self) { step in
                                let isPast = CGFloat(step) <= value
                                let isDef = step == Int(defaultValue)

                                if step != steps.first {
                                    Spacer()
                                }

                                Circle()
                                    .fill(
                                        isDef
                                            ? (isPast ? Color.white : theme.accentColor)
                                            : (isPast ? Color.white.opacity(0.7) : theme.dividerColor.opacity(0.8))
                                    )
                                    .frame(width: isDef ? 4.5 : 2.5, height: isDef ? 4.5 : 2.5)

                                if step == steps.last {
                                    // End spacer
                                }
                            }
                        }
                        .padding(.horizontal, thumbDiameter / 2)
                        .frame(height: 6)

                        // Tactile Knob (Thumb)
                        Circle()
                            .fill(Color.white)
                            .frame(width: thumbDiameter, height: thumbDiameter)
                            .overlay(
                                Circle()
                                    .fill(theme.accentColor)
                                    .frame(width: 5.5, height: 5.5)
                            )
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                            )
                            .shadow(color: Color.black.opacity(0.28), radius: isDragging ? 4 : 2.5, y: 1.5)
                            .shadow(color: theme.accentColor.opacity(isDragging || isHovering ? 0.35 : 0), radius: 5)
                            .scaleEffect(isDragging ? 1.15 : (isHovering ? 1.08 : 1.0))
                            .position(x: thumbX, y: geometry.size.height / 2)
                    }
                    .frame(height: geometry.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                isDragging = true
                                let clampedX = max(thumbDiameter / 2, min(width - thumbDiameter / 2, gesture.location.x))
                                let fraction = (clampedX - thumbDiameter / 2) / availableWidth
                                let raw = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                                let snapped = round(raw)
                                if snapped != value {
                                    value = snapped
                                    onCommit(snapped)
                                }
                            }
                            .onEnded { _ in
                                isDragging = false
                            }
                    )
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.15)) {
                            isHovering = hovering
                        }
                    }
                }
                .frame(height: 24)

                // Increment Button (Large 'A')
                Button {
                    let next = min(range.upperBound, value + 1)
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        value = next
                    }
                    onCommit(next)
                } label: {
                    Text("A")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(value < range.upperBound ? theme.secondaryText : theme.tertiaryText.opacity(0.35))
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.surfaceOverlay)
                        )
                }
                .buttonStyle(.plain)
                .disabled(value >= range.upperBound)
                .help("Increase font size (\(Int(min(range.upperBound, value + 1))) pt)")
            }
        }
    }
}

// MARK: - Surface Style Option Card

private struct SurfaceStyleCard: View {
    let style: SurfaceStyle
    let isSelected: Bool
    let theme: any Theme
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: style.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(isSelected ? theme.accentColor.opacity(0.15) : theme.surfaceOverlay)
                        )

                    Text(style.displayName)
                        .font(theme.fontFootnote.weight(isSelected ? .bold : .semibold))
                        .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.accentColor)
                    }
                }

                Text(style.subtitle)
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? theme.accentColor.opacity(0.08) : (isHovering ? theme.surfaceOverlay : theme.secondaryBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? theme.accentColor.opacity(0.5)
                            : (isHovering ? theme.secondaryText.opacity(0.25) : theme.dividerColor.opacity(0.5)),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovering = $0 }
    }
}

// MARK: - Preview Provider
struct ThemeSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ThemeSettingsView()
            .environment(ThemeManager())
    }
}
