//
//  ThemeSettingsView.swift
//  Devgentic
//
//  Created by Raj Singh on 25/07/25.
//

import SwiftUI

struct ThemeSettingsView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appTheme) private var theme

    let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 24)]

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

                    LazyVGrid(columns: columns, spacing: 20) {
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

                // MARK: - Chat Font Section
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "textformat.size")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.accentColor)

                            Text("CHAT FONT")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(1.8)
                                .foregroundColor(theme.secondaryText)
                        }

                        Text("Adjust font size and line spacing for chat messages.")
                            .font(theme.fontSubheadline)
                            .foregroundColor(theme.secondaryText)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        // Font Size Slider
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Font Size")
                                    .font(theme.fontSubheadline.weight(.semibold))
                                    .foregroundColor(theme.primaryText)
                                Spacer()
                                Text("\(Int(themeManager.chatFontSize)) pt")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(theme.accentColor)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule().fill(theme.accentColor.opacity(0.14))
                                    )
                            }
                            HStack(spacing: 10) {
                                Text("A")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(theme.tertiaryText)
                                Slider(
                                    value: Binding(
                                        get: { themeManager.chatFontSize },
                                        set: { themeManager.applyChatFontSize($0) }
                                    ),
                                    in: 12...22,
                                    step: 1
                                )
                                .tint(theme.accentColor)
                                Text("A")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(theme.tertiaryText)
                            }
                        }

                        // Line Spacing Slider
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Line Spacing")
                                    .font(theme.fontSubheadline.weight(.semibold))
                                    .foregroundColor(theme.primaryText)
                                Spacer()
                                Text(String(format: "%.0f pt", themeManager.chatLineSpacing))
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(theme.accentColor)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule().fill(theme.accentColor.opacity(0.14))
                                    )
                            }
                            Slider(
                                value: Binding(
                                    get: { themeManager.chatLineSpacing },
                                    set: { themeManager.applyChatLineSpacing($0) }
                                ),
                                in: 0...12,
                                step: 1
                            )
                            .tint(theme.accentColor)
                        }

                        // Live Preview
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PREVIEW")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(1.4)
                                .foregroundColor(theme.tertiaryText)

                            Text("The quick brown fox jumps over the lazy dog. This is how your chat messages will look with the current font settings.")
                                .font(.system(size: themeManager.chatFontSize, weight: .regular))
                                .foregroundColor(theme.primaryText)
                                .lineSpacing(themeManager.chatLineSpacing)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(theme.surfaceOverlay.opacity(0.5))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(theme.secondaryText.opacity(0.18), lineWidth: 1)
                                )
                        }

                        // Reset Button
                        HStack {
                            Spacer()
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    themeManager.applyChatFontSize(15)
                                    themeManager.applyChatLineSpacing(4)
                                }
                            } label: {
                                Text("Reset to Default")
                                    .font(.system(.caption, weight: .medium))
                                    .foregroundColor(theme.secondaryText)
                            }
                            .buttonStyle(.plain)
                            .disabled(themeManager.chatFontSize == 15 && themeManager.chatLineSpacing == 4)
                            .opacity(themeManager.chatFontSize == 15 && themeManager.chatLineSpacing == 4 ? 0.4 : 1)
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

                            Text("CODE VIEWER THEME")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(1.8)
                                .foregroundColor(theme.secondaryText)
                        }
                        
                        Text("Select a specialized syntax highlighting theme for the code editor.")
                            .font(theme.fontSubheadline)
                            .foregroundColor(theme.secondaryText)
                    }

                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(CodeViewerThemeOverride.allCases, id: \.self) { override in
                            CodeViewerPreviewCard(
                                override: override,
                                currentAppTheme: themeManager.currentTheme,
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
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

struct CodeViewerPreviewCard: View {
    let override: CodeViewerThemeOverride
    let currentAppTheme: any Theme
    let isSelected: Bool
    let appTheme: any Theme
    let action: () -> Void

    @State private var isHovered = false

    var previewTheme: any Theme {
        switch override {
        case .default: return currentAppTheme
        case .oneLight: return AppThemes.OneLightTheme()
        case .oneDark: return AppThemes.OneDarkTheme()
        case .cosmicDark: return AppThemes.CosmicDarkTheme()
        case .dracula: return AppThemes.DraculaTheme()
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
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

struct AccentColorCircle: View {
    let accent: AppAccentColor
    let isSelected: Bool
    let appTheme: any Theme
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    if accent == .default {
                        Circle()
                            .fill(appTheme.accentColor)
                            .frame(width: 32, height: 32)
                        
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Circle()
                            .fill(accent.color ?? appTheme.accentColor)
                            .frame(width: 32, height: 32)
                            .shadow(color: (accent.color ?? appTheme.accentColor).opacity(isHovered ? 0.6 : 0.2), radius: isHovered ? 6 : 3)
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

// MARK: - Preview Provider
struct ThemeSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ThemeSettingsView()
            .environment(ThemeManager())
    }
}
