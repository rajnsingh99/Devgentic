// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingWelcomeSlideView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

struct OnboardingWelcomeSlideView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.appTheme) private var theme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var orbPulsing: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.indigo)
                        .frame(width: 6, height: 6)
                    Text("WELCOME TO DEVGENTIC")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.indigo.opacity(0.9))
                        .tracking(1.2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.indigo.opacity(0.12))
                .clipShape(Capsule())

                Text("Build & Run Local AI Agents")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(theme.primaryText)

                Text("Private, native macOS intelligence with local inference and autonomous tools.")
                    .font(theme.fontBody)
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 12)
            .padding(.bottom, 18)

            // Slideshow Card Container (Height balanced to 390pt)
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(theme.secondaryBackground.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(theme.dividerColor.opacity(0.6), lineWidth: 1)
                    )

                // Current Slide Content
                let currentSlide = viewModel.featureSlides[viewModel.currentSlideIndex]
                slideContent(for: currentSlide)
                    .id(currentSlide.id)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 20)),
                        removal: .opacity.combined(with: .offset(x: -20))
                    ))

                // Left Arrow
                HStack {
                    CarouselArrowButton(icon: "chevron.left", label: "Previous feature") {
                        previousSlide()
                    }
                    .padding(.leading, 16)

                    Spacer()

                    // Right Arrow
                    CarouselArrowButton(icon: "chevron.right", label: "Next feature") {
                        nextSlide()
                    }
                    .padding(.trailing, 16)
                }

                // Bottom Indicator Dots
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        ForEach(viewModel.featureSlides) { slide in
                            Circle()
                                .fill(slide.id == viewModel.currentSlideIndex ? Color.accentColor : theme.secondaryText.opacity(0.35))
                                .frame(width: slide.id == viewModel.currentSlideIndex ? 22 : 7, height: 7)
                                .clipShape(Capsule())
                                .animation(.spring(response: 0.3), value: viewModel.currentSlideIndex)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.35)) {
                                        viewModel.currentSlideIndex = slide.id
                                    }
                                }
                                .accessibilityElement()
                                .accessibilityLabel(slide.title)
                                .accessibilityAddTraits(slide.id == viewModel.currentSlideIndex ? [.isButton, .isSelected] : .isButton)
                                .accessibilityAction { viewModel.currentSlideIndex = slide.id }
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
            .frame(maxWidth: 720)
            .frame(height: 390)

            Spacer(minLength: 16)

            // Pinned Footer Action
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.green)
                    Text("100% On-Device & Private by Default")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                OnboardingPrimaryButton("Continue to Setup") {
                    viewModel.goToStep(.profileSetup)
                }
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 32)
            .padding(.bottom, 22)
        }
        .onAppear {
            orbPulsing = !reduceMotion
        }
        // ← / → page the feature carousel.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { previousSlide(); return .handled }
        .onKeyPress(.rightArrow) { nextSlide(); return .handled }
    }

    // MARK: - Slide Content Layout
    @ViewBuilder
    private func slideContent(for slide: OnboardingViewModel.FeatureSlide) -> some View {
        HStack(spacing: 36) {
            // Visual Feature Graphic
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(
                        LinearGradient(
                            colors: slide.accentGradient.map { $0.opacity(0.22) },
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 190, height: 190)
                    .blur(radius: 14)

                if slide.id == 0 {
                    // Orb Voice Orb Graphic
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    gradient: Gradient(colors: [Color.cyan, Color.indigo, Color.purple]),
                                    center: .center,
                                    startRadius: 8,
                                    endRadius: 75
                                )
                            )
                            .frame(width: 120, height: 120)
                            .scaleEffect(orbPulsing ? 1.07 : 0.95)
                            .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: orbPulsing)
                            .shadow(color: Color.cyan.opacity(0.6), radius: 22)

                        Image(systemName: "waveform")
                            .font(.system(size: 46, weight: .bold))
                            .foregroundColor(.white)
                    }
                } else if slide.id == 1 {
                    // Quick Access Panel Graphic
                    VStack(spacing: 10) {
                        HStack(spacing: 5) {
                            Circle().fill(Color.red).frame(width: 7, height: 7)
                            Circle().fill(Color.yellow).frame(width: 7, height: 7)
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                            Spacer()
                            // The user's real shortcut, not a guess — "⌘ Space" here was Spotlight's.
                            Text(verbatim: QuickAccessConfigManager.shared.shortcutDescription)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(Color.orange)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 10)

                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.12))
                            .frame(height: 28)
                            .overlay(
                                Text("Ask Quick Access...")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.7)),
                                alignment: .leading
                            )
                            .padding(.horizontal, 10)

                        HStack {
                            Text("Screen Capture")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.6))
                            Spacer()
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }
                    .frame(width: 170, height: 110)
                    .background(Color.black.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.18), lineWidth: 1))
                } else if slide.id == 2 {
                    // Workflow Node Graph Graphic
                    VStack(spacing: 8) {
                        Text("Trigger Gate")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.indigo.opacity(0.75))
                            .foregroundColor(.white)
                            .clipShape(Capsule())

                        Rectangle()
                            .fill(Color.white.opacity(0.4))
                            .frame(width: 1.5, height: 14)

                        HStack(spacing: 10) {
                            Text("Agent A")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.teal.opacity(0.75))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))

                            Text("Agent B")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.purple.opacity(0.75))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }

                        Rectangle()
                            .fill(Color.white.opacity(0.4))
                            .frame(width: 1.5, height: 14)

                        Text("HITL Review")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.75))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .frame(width: 160, height: 150)
                } else {
                    // ChatOps Bridges Graphic
                    VStack(spacing: 8) {
                        HStack(spacing: 10) {
                            VStack(spacing: 2) {
                                Text("Slack")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.green)
                                Text("Socket")
                                    .font(.system(size: 8))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .frame(width: 72, height: 46)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                            VStack(spacing: 2) {
                                Text("Discord")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.indigo)
                                Text("Gateway")
                                    .font(.system(size: 8))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .frame(width: 72, height: 46)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        VStack(spacing: 2) {
                            Text("Telegram Bot")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.cyan)
                            Text("Remote Agent Execution")
                                .font(.system(size: 8))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .frame(width: 154, height: 42)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .frame(width: 170, height: 120)
                }
            }
            .frame(width: 200)

            // Description Column
            VStack(alignment: .leading, spacing: 12) {
                Text(slide.tag.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(slide.accentGradient.first ?? Color.accentColor)
                    .tracking(1.1)

                Text(slide.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(theme.primaryText)

                Text(slide.description)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(4)

                // Badges
                HStack(spacing: 8) {
                    ForEach(slide.badges, id: \.self) { badge in
                        Text(badge)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(theme.primaryBackground.opacity(0.85))
                            .foregroundColor(theme.primaryText.opacity(0.9))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(theme.dividerColor, lineWidth: 1))
                    }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 48)
    }

    private func nextSlide() {
        withAnimation(.spring(response: 0.35)) {
            viewModel.currentSlideIndex = (viewModel.currentSlideIndex + 1) % viewModel.featureSlides.count
        }
    }

    private func previousSlide() {
        withAnimation(.spring(response: 0.35)) {
            viewModel.currentSlideIndex = (viewModel.currentSlideIndex - 1 + viewModel.featureSlides.count) % viewModel.featureSlides.count
        }
    }
}

// MARK: - Carousel Arrow Button with Hover Feedback
private struct CarouselArrowButton: View {
    let icon: String
    let label: LocalizedStringKey
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
                .frame(width: 36, height: 36)
                .background(isHovered ? theme.secondaryBackground.opacity(0.9) : theme.primaryBackground.opacity(0.8))
                .clipShape(Circle())
                .overlay(Circle().stroke(isHovered ? Color.accentColor.opacity(0.5) : theme.dividerColor, lineWidth: 1))
                .scaleEffect(isHovered ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityLabel(label)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
