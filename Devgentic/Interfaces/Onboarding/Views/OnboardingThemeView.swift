// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingThemeView.swift
//  Devgentic
//
//  Created by Raj Singh on 17/09/26.
//

import SwiftUI

struct OnboardingThemeView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appTheme) private var theme

    private let availableAccentColors: [(accent: AppAccentColor, color: Color, name: String)] = [
        (.blue, Color(hex: "#0A84FF"), "Electric Azure"),
        (.green, Color(hex: "#10B981"), "Emerald Mint"),
        (.spotify, Color(hex: "#1DB954"), "Spotify Green"),
        (.purple, Color(hex: "#8B5CF6"), "Royal Violet"),
        (.modernSpotify, Color(hex: "#06B6D4"), "Cosmic Cyan"),
        (.orange, Color(hex: "#F59E0B"), "Warm Amber"),
        (.pink, Color(hex: "#EC4899"), "Rose Quartz"),
        (.white, Color(hex: "#FFFFFF"), "Pure White")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable Content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 18) {
                    // Header
                    VStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Text("STEP 3 OF 3")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.accentColor)
                                .tracking(1.0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())

                        Text("Tailor Your Workspace")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(theme.primaryText)

                        Text("Choose your preferred visual aesthetic. You can always change this later in Settings.")
                            .font(theme.fontBody)
                            .foregroundColor(theme.secondaryText)
                    }
                    .padding(.top, 12)

                    // Customization Options
                    VStack(spacing: 16) {

                        // 1. Application Theme
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Application Theme")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.primaryText)

                            HStack(spacing: 10) {
                                themeCard(id: "material", title: "Material Darker", subtitle: "Deep charcoal", icon: "moon.fill", previewColor: Color(hex: "#212121"))
                                themeCard(id: "cosmic_dark", title: "Cosmic Dark", subtitle: "Midnight navy", icon: "sparkles", previewColor: Color(hex: "#0F172A"))
                                themeCard(id: "one_light", title: "One Light", subtitle: "Clean contrast", icon: "sun.max.fill", previewColor: Color(hex: "#FAFAFA"))
                                themeCard(id: "solarized_light", title: "Solarized Light", subtitle: "Warm paper", icon: "doc.text.fill", previewColor: Color(hex: "#FDF6E3"))
                            }
                        }

                        // 2. Accent Color Palette
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Accent Color")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(theme.primaryText)
                                Spacer()
                                Text(availableAccentColors.first { $0.accent == viewModel.selectedAccentColor }?.name ?? "")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(viewModel.selectedAccentColor.color ?? Color.accentColor)
                            }

                            HStack(spacing: 14) {
                                ForEach(availableAccentColors, id: \.accent) { item in
                                    Button(action: {
                                        viewModel.selectedAccentColor = item.accent
                                        themeManager.applyAccentColor(item.accent)
                                    }) {
                                        Circle()
                                            .fill(item.color)
                                            .frame(width: 28, height: 28)
                                            .overlay(
                                                Circle()
                                                    .stroke(Color.white, lineWidth: viewModel.selectedAccentColor == item.accent ? 2.5 : 0)
                                            )
                                            .shadow(color: item.color.opacity(viewModel.selectedAccentColor == item.accent ? 0.65 : 0), radius: 6)
                                            .scaleEffect(viewModel.selectedAccentColor == item.accent ? 1.18 : 1.0)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(10)
                            .background(theme.secondaryBackground.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(theme.dividerColor, lineWidth: 1)
                            )
                        }

                        // 3. Surface Presentation Style
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Surface Presentation")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.primaryText)

                            HStack(spacing: 12) {
                                surfaceCard(
                                    style: .glassmorphic,
                                    title: "Liquid Glass",
                                    subtitle: "Acrylic blur and ambient glows",
                                    icon: "sparkles"
                                )

                                surfaceCard(
                                    style: .solid,
                                    title: "Solid Matte",
                                    subtitle: "Opaque surfaces & razor hairlines",
                                    icon: "square.fill"
                                )
                            }
                        }

                        // 4. Live Message Bubble Preview
                        livePreviewCard
                    }
                    .frame(maxWidth: 620)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
            }

            // Pinned Bottom Navigation Actions
            HStack {
                OnboardingSecondaryButton("Back", icon: "chevron.left") {
                    if viewModel.isModelInstalled {
                        viewModel.goToStep(.profileSetup)
                    } else {
                        viewModel.goToStep(.modelDownload)
                    }
                }

                Spacer()

                OnboardingPrimaryButton("Continue to Finalization") {
                    viewModel.goToStep(.ready)
                }
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 32)
            .padding(.top, 10)
            .padding(.bottom, 22)
        }
    }

    // MARK: - Theme Card
    @ViewBuilder
    private func themeCard(id: String, title: String, subtitle: String, icon: String, previewColor: Color) -> some View {
        let isSelected = viewModel.selectedThemeID == id

        Button(action: {
            viewModel.selectedThemeID = id
            if let matching = themeManager.availableThemes.first(where: { $0.id == id }) {
                themeManager.applyTheme(matching)
            }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(previewColor)
                            .frame(width: 24, height: 24)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.dividerColor, lineWidth: 1))
                        Image(systemName: icon)
                            .font(.system(size: 11))
                            .foregroundColor(id.contains("light") ? .black : .white)
                    }

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color.accentColor)
                            .font(.system(size: 14))
                    }
                }

                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.08) : theme.secondaryBackground.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : theme.dividerColor, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Surface Style Card
    @ViewBuilder
    private func surfaceCard(style: SurfaceStyle, title: String, subtitle: String, icon: String) -> some View {
        let isSelected = viewModel.selectedSurfaceStyle == style

        Button(action: {
            viewModel.selectedSurfaceStyle = style
            themeManager.applySurfaceStyle(style)
        }) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? Color.accentColor : theme.secondaryText)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(theme.primaryText)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color.accentColor)
                        .font(.system(size: 15))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.accentColor.opacity(0.08) : theme.secondaryBackground.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : theme.dividerColor, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Live Preview Card
    private var livePreviewCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 16))
                .foregroundColor(viewModel.selectedAccentColor.color ?? Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text("Theme Preview")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(theme.primaryText)
                Text("Hello! Your local AI workspace is customized and ready to assist.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Text("Active Accent")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background((viewModel.selectedAccentColor.color ?? Color.accentColor).opacity(0.15))
                .foregroundColor(viewModel.selectedAccentColor.color ?? Color.accentColor)
                .clipShape(Capsule())
        }
        .padding(12)
        .background(theme.primaryBackground.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.dividerColor.opacity(0.7), lineWidth: 1)
        )
    }
}
