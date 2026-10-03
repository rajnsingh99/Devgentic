// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingContainerView.swift
//  Devgentic
//
//  Created by Raj Singh on 17/09/26.
//

import SwiftUI
import AppKit

struct OnboardingContainerView: View {
    let onComplete: () -> Void

    @State private var viewModel = OnboardingViewModel()
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            // Window Header with step indicator (seamless single coloring scheme, clearing traffic lights)
            windowHeaderBar

            // Step Content
            ZStack {
                switch viewModel.currentStep {
                case .welcome:
                    OnboardingWelcomeSlideView(viewModel: viewModel)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.98)),
                            removal: .opacity.combined(with: .scale(scale: 1.02))
                        ))
                case .profileSetup:
                    OnboardingProfileSetupView(viewModel: viewModel)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 20)),
                            removal: .opacity.combined(with: .offset(x: -20))
                        ))
                case .modelDownload:
                    OnboardingModelDownloadView(viewModel: viewModel)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 20)),
                            removal: .opacity.combined(with: .offset(x: -20))
                        ))
                case .themeCustomization:
                    OnboardingThemeView(viewModel: viewModel)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 20)),
                            removal: .opacity.combined(with: .offset(x: -20))
                        ))
                case .ready:
                    OnboardingReadyView(viewModel: viewModel, onComplete: onComplete)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.98)),
                            removal: .opacity.combined(with: .scale(scale: 1.02))
                        ))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.currentStep)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Height increased by 30% (from 610pt to 800pt)
        .frame(minWidth: 840, idealWidth: 880, maxWidth: 940,
               minHeight: 720, idealHeight: 800, maxHeight: 860)
        .background(theme.primaryBackground)
        .background(OnboardingWindowAccessor())
        .navigationTitle("")
    }

    // MARK: - Window Header Bar (Single Color, Clean UI, Traffic Light Safe)
    private var windowHeaderBar: some View {
        HStack(spacing: 16) {
            // Brand & Title (Starts cleanly after macOS traffic lights)
            HStack(spacing: 8) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Color.accentColor)

                Text("Devgentic Setup Assistant")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(theme.primaryText)
            }

            Spacer()

            // Stage Navigation Bubble Capsule
            stageBubblesGroup
        }
        .frame(height: 52)
        .padding(.leading, 82) // Safe clearance for macOS traffic lights (red, yellow, green)
        .padding(.trailing, 24)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Stage Bubbles Group
    private var stageBubblesGroup: some View {
        HStack(spacing: 2) {
            ForEach(OnboardingViewModel.Step.allCases) { step in
                stageBubbleItem(step: step)
            }
        }
        .padding(3)
        .background(theme.secondaryBackground.opacity(0.6))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(theme.dividerColor.opacity(0.4), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func stageBubbleItem(step: OnboardingViewModel.Step) -> some View {
        let isCurrent = viewModel.currentStep == step
        let isPast = viewModel.currentStep.rawValue > step.rawValue

        if isCurrent {
            // Prominent Active Stage Bubble
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 5, height: 5)
                Text(step.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .shadow(color: Color.accentColor.opacity(0.4), radius: 6, x: 0, y: 2)
        } else if isPast {
            // Clickable Completed Stage with Hover Feedback
            PastStageBubbleButton(step: step) {
                viewModel.goToStep(step)
            }
        } else {
            // Inactive / Upcoming Stage
            Text(step.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText.opacity(0.6))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
    }
}

// MARK: - Window Accessor for Onboarding
private struct OnboardingWindowAccessor: NSViewRepresentable {
    let targetWidth: CGFloat = 880
    let targetHeight: CGFloat = 800

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            configureWindow(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            configureWindow(window)
        }
    }

    private func configureWindow(_ window: NSWindow) {
        window.minSize = NSSize(width: 840, height: 720)

        let currentSize = window.frame.size
        // If current window is significantly different from target size, animate to target size and center
        if abs(currentSize.height - targetHeight) > 15 || abs(currentSize.width - targetWidth) > 15 {
            if let screen = window.screen ?? NSScreen.main {
                let screenRect = screen.visibleFrame
                let newX = screenRect.origin.x + (screenRect.width - targetWidth) / 2
                let newY = screenRect.origin.y + (screenRect.height - targetHeight) / 2
                let newFrame = NSRect(x: newX, y: newY, width: targetWidth, height: targetHeight)
                window.setFrame(newFrame, display: true, animate: true)
            } else {
                window.setContentSize(NSSize(width: targetWidth, height: targetHeight))
            }
        }
    }
}

// MARK: - Past Stage Bubble Button with Hover Effect
private struct PastStageBubbleButton: View {
    let step: OnboardingViewModel.Step
    let action: () -> Void
    @Environment(\.appTheme) private var theme
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.green)
                Text(step.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isHovered ? Color.green.opacity(0.18) : Color.green.opacity(0.08))
            .clipShape(Capsule())
            .scaleEffect(isHovered ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
