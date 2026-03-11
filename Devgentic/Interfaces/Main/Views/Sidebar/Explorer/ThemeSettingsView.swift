//
//  ThemeSettingsView.swift
//  Devgentic
//
//  Created by Raj Singh on 25/07/25.
//

import SwiftUI

struct ThemeSettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.appTheme) private var theme

    let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 24)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                
                // MARK: - App Theme Section
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 8) {
                        Image(systemName: "paintbrush.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(theme.accentColor)
                        Text("App Appearance")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                    }

                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(themeManager.availableThemes, id: \.id) { appTheme in
                            ThemePreviewCard(
                                previewTheme: appTheme,
                                isSelected: themeManager.currentTheme.id == appTheme.id,
                                currentTheme: theme
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    themeManager.applyTheme(appTheme)
                                }
                            }
                        }
                    }
                }

                Divider().background(theme.dividerColor)

                // MARK: - Accent Color Section
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "circle.dotted")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(theme.accentColor)
                            Text("Accent Color")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                        }
                        
                        Text("Choose a personal touch that applies to interactive elements across the entire app.")
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryText)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
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

                Divider().background(theme.dividerColor)

                // MARK: - Code Viewer Section
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(theme.accentColor)
                            Text("Code Viewer")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                        }
                        
                        Text("When set to Default, the code viewer follows the app theme. Select a specific theme to override it.")
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryText)
                    }

                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(CodeViewerThemeOverride.allCases, id: \.self) { override in
                            CodeViewerPreviewCard(
                                override: override,
                                currentAppTheme: themeManager.currentTheme,
                                isSelected: themeManager.codeViewerThemeOverride == override,
                                appTheme: theme
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    themeManager.applyCodeViewerTheme(override)
                                }
                            }
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(theme.primaryBackground)
    }
}

// MARK: - Subviews

struct ThemePreviewCard: View {
    let previewTheme: any Theme
    let isSelected: Bool
    let currentTheme: any Theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                // Mock UI Container
                ZStack(alignment: .topLeading) {
                    previewTheme.primaryBackground

                    VStack(alignment: .leading, spacing: 6) {
                        // macOS Window header mock
                        HStack(spacing: 4) {
                            Circle().fill(Color.gray.opacity(0.4)).frame(width: 6, height: 6)
                            Circle().fill(Color.gray.opacity(0.4)).frame(width: 6, height: 6)
                            Circle().fill(Color.gray.opacity(0.4)).frame(width: 6, height: 6)
                        }
                        .padding(.bottom, 4)

                        // Sidebar and content mock
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(previewTheme.secondaryBackground)
                                .frame(width: 30)

                            VStack(alignment: .leading, spacing: 5) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(previewTheme.accentColor)
                                    .frame(width: 40, height: 5)

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(previewTheme.primaryText.opacity(0.2))
                                    .frame(maxWidth: .infinity, maxHeight: 5)

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(previewTheme.primaryText.opacity(0.1))
                                    .frame(maxWidth: .infinity, maxHeight: 5)
                            }
                        }
                    }
                    .padding(10)
                }
                .aspectRatio(1.5, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? currentTheme.accentColor : currentTheme.surfaceOverlayStrong, lineWidth: isSelected ? 3 : 1)
                )
                .shadow(color: Color.black.opacity(0.1), radius: 4, y: 2)

                // Title
                HStack {
                    Text(previewTheme.displayName)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? currentTheme.primaryText : currentTheme.secondaryText)
                    
                    if isSelected {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(currentTheme.accentColor)
                            .font(.system(size: 14))
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
            VStack(spacing: 12) {
                // Mock Code Container
                ZStack(alignment: .topLeading) {
                    Color(nsColor: syntaxTheme.background)

                    VStack(alignment: .leading, spacing: 6) {
                        // Code block mock lines
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
                        .stroke(isSelected ? appTheme.accentColor : appTheme.surfaceOverlayStrong, lineWidth: isSelected ? 3 : 1)
                )
                .shadow(color: Color.black.opacity(0.1), radius: 4, y: 2)

                // Title
                HStack {
                    Text(override.displayName)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? appTheme.primaryText : appTheme.secondaryText)
                        .lineLimit(1)
                    
                    if isSelected {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(appTheme.accentColor)
                            .font(.system(size: 14))
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

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    if accent == .default {
                        Circle()
                            .fill(appTheme.accentColor)
                            .frame(width: 32, height: 32)
                        
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Circle()
                            .fill(accent.color ?? appTheme.accentColor)
                            .frame(width: 32, height: 32)
                    }

                    if isSelected {
                        Circle()
                            .strokeBorder(appTheme.primaryText, lineWidth: 2)
                            .frame(width: 40, height: 40)
                    } else {
                        Circle()
                            .strokeBorder(appTheme.surfaceOverlayStrong, lineWidth: 1)
                            .frame(width: 40, height: 40)
                    }
                }
                .contentShape(Circle())
                
                Text(accent.displayName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
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
            .environmentObject(ThemeManager())
    }
}
