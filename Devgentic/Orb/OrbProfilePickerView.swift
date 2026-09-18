// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbProfilePickerView.swift
//  Devgentic
//
//  [Orb] Stage 1 of the HUD: choose which Bot/Agent profile powers the
//  session. Redesigned with Tactile Dark Glass card components, provider chips,
//  and smooth hover feedback.
//

import SwiftUI

struct OrbProfilePickerView: View {
    let controller: OrbSessionController

    var body: some View {
        VStack(spacing: 12) {
            // Header
            VStack(spacing: 4) {
                Text("Choose Assistant Profile")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.bottom, 4)

            // Content List
            if controller.profiles.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(controller.profiles) { profile in
                            OrbProfileCard(
                                profile: profile,
                                isRemembered: profile.id == controller.rememberedProfileID,
                                action: { controller.selectProfile(profile) }
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 280)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.04),
                            .init(color: .black, location: 0.96),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // Footer Footnote
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                        .foregroundColor(Color.white.opacity(0.35))
                    Text("Choice remembered · Switch anytime via orb bubble")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color.white.opacity(0.40))
                }
                .padding(.top, 4)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 30))
                .foregroundColor(OrbPalette.hologramDim)
            Text("No Bot or Agent profiles available.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(OrbPalette.textPrimary)
            Text("Create one under Backend Profiles, then reopen Orb.")
                .font(.system(size: 12))
                .foregroundColor(OrbPalette.textSecondary)
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
    }
}

// MARK: - Minimalist Tactile Profile Card

private struct OrbProfileCard: View {
    let profile: BackendProfileModel
    let isRemembered: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var cardBorderGradient: LinearGradient {
        if isHovered {
            return LinearGradient(
                colors: [Color.white.opacity(0.24), Color.white.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else if isRemembered {
            return LinearGradient(
                colors: [Color.white.opacity(0.15), Color.white.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [Color.white.opacity(0.08), Color.white.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var cardBackgroundColor: Color {
        if isHovered {
            return Color.white.opacity(0.07)
        } else if isRemembered {
            return Color.white.opacity(0.04)
        } else {
            return Color.white.opacity(0.025)
        }
    }

    private var cardShadowColor: Color {
        if isHovered {
            return Color.black.opacity(0.35)
        } else {
            return Color.black.opacity(0.15)
        }
    }

    private var avatarContainer: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.08 : 0.04))
                .frame(width: 38, height: 38)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(isHovered ? 0.18 : 0.08), lineWidth: 1)
                )

            ProfileTypeIcon(
                type: profile.profileType,
                size: 18,
                color: Color.white.opacity(isHovered ? 0.95 : 0.70),
                isFilled: true,
                isHovered: isHovered
            )
        }
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(profile.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(profile.profileType.rawValue.uppercased())
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.55))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))

                if isRemembered {
                    HStack(spacing: 3.5) {
                        Circle()
                            .fill(Color.white.opacity(0.70))
                            .frame(width: 3.5, height: 3.5)
                        Text("LAST USED")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .tracking(0.8)
                            .foregroundColor(Color.white.opacity(0.65))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.6))
                }
            }

            if let config = profile.resolvedLLMConfig {
                HStack(spacing: 6) {
                    Text(config.apiProvider.rawValue)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.75))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Capsule())

                    Text(config.modelName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.45))
                        .lineLimit(1)
                }
            } else {
                Text(profile.profileType.rawValue)
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                avatarContainer
                infoColumn

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(isHovered ? 0.70 : 0.25))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(cardBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(cardBorderGradient, lineWidth: 1)
            )
            .shadow(color: cardShadowColor, radius: isHovered ? 8 : 4, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { isHovered = hovering }
        }
        .accessibilityLabel("Use profile \(profile.displayName)")
    }
}
