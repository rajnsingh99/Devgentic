//
//  JarvisProfilePickerView.swift
//  Devgentic
//
//  [Jarvis MVP] Stage 1 of the HUD: choose which Bot/Agent profile powers the
//  session. Asked on every open (per MVP spec); the last-used profile is
//  pre-highlighted with a LAST USED tag.
//

import SwiftUI

struct JarvisProfilePickerView: View {
    let controller: JarvisSessionController

    var body: some View {
        VStack(spacing: 6) {
            Text("SELECT A PROFILE")
                .jarvisStatusStyle()

            Text("Choose which mind powers this session")
                .font(.system(size: 12))
                .foregroundColor(JarvisPalette.textSecondary)
                .padding(.bottom, 10)

            if controller.profiles.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(controller.profiles) { profile in
                            JarvisProfileCard(
                                profile: profile,
                                isRemembered: profile.id == controller.rememberedProfileID,
                                action: { controller.selectProfile(profile) }
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(maxWidth: .infinity)

                Text("Remembered for next time — switch from the orb's bubble")
                    .font(.system(size: 10))
                    .foregroundColor(JarvisPalette.textSecondary.opacity(0.75))
                    .padding(.top, 10)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 30))
                .foregroundColor(JarvisPalette.hologramDim)
            Text("No Bot or Agent profiles available.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(JarvisPalette.textPrimary)
            Text("Create one under Backend Profiles, then reopen Jarvis.")
                .font(.system(size: 12))
                .foregroundColor(JarvisPalette.textSecondary)
        }
        .padding(28)
        .background(panelBackground)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(JarvisPalette.panelFill)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(JarvisPalette.panelStroke, lineWidth: 1))
    }
}

// MARK: - Card

private struct JarvisProfileCard: View {
    let profile: BackendProfileModel
    let isRemembered: Bool
    let action: () -> Void

    @State private var isHovered = false

    /// Model subtitle, mirroring ProfileSelectorPopover.detailText's pattern.
    private var subtitle: String? {
        profile.resolvedLLMConfig.map { "\($0.apiProvider.rawValue) · \($0.modelName)" }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(JarvisPalette.hologram.opacity(isHovered ? 0.22 : 0.10))
                        .frame(width: 40, height: 40)
                        .shadow(color: isHovered ? JarvisPalette.hologram.opacity(0.4) : .clear, radius: 4)

                    Image(systemName: profile.profileType.iconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isHovered ? .white : JarvisPalette.hologram)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(profile.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(JarvisPalette.textPrimary)
                        if isRemembered {
                            Text("LAST USED")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .tracking(1.5)
                                .foregroundColor(JarvisPalette.gold)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(JarvisPalette.gold.opacity(0.12))
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(JarvisPalette.gold.opacity(0.55), lineWidth: 1)
                                )
                                .shadow(color: JarvisPalette.gold.opacity(0.3), radius: 3)
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(JarvisPalette.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(isHovered ? JarvisPalette.hologram : JarvisPalette.textSecondary.opacity(0.4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.09 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isHovered ? JarvisPalette.glassBorderGradient : LinearGradient(colors: [JarvisPalette.panelStroke], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            )
            .shadow(color: isHovered ? JarvisPalette.hologram.opacity(0.2) : .clear, radius: 8, y: 3)
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHovered = hovering }
        }
        .accessibilityLabel("Use profile \(profile.displayName)")
    }
}
