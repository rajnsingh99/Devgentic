// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingContainerView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit

struct OnboardingContainerView: View {
    /// Called when the Setup Assistant closes, with the profile it created (nil when a re-run is
    /// cancelled). The app passes it to `OnboardingCompletion.apply`.
    let onComplete: (_ createdProfileID: UUID?) -> Void

    @State private var viewModel = OnboardingViewModel()
    @Environment(ThemeManager.self) private var themeManager
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
                case .behavior:
                    OnboardingBehaviorView(viewModel: viewModel)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 20)),
                            removal: .opacity.combined(with: .offset(x: -20))
                        ))
                case .features:
                    OnboardingFeaturesView(viewModel: viewModel)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 20)),
                            removal: .opacity.combined(with: .offset(x: -20))
                        ))
                case .permissions:
                    OnboardingPermissionsView(viewModel: viewModel)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 20)),
                            removal: .opacity.combined(with: .offset(x: -20))
                        ))
                case .privacy:
                    OnboardingPrivacyView(viewModel: viewModel)
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
        // A re-run must start the theme step from the user's current choices, not first-run defaults.
        .onAppear {
            viewModel.adoptCurrentTheme(from: themeManager)
            viewModel.adoptCurrentSettings()
        }
        // Read here, not only on the profile step: it decides whether Cancel is offered at all.
        .onAppear { viewModel.refreshExistingProfileNames() }
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

            // Stage Navigation Bubble Capsule. Nine labelled stages don't fit the minimum window
            // width, so it falls back to compact bubbles (current step labelled, others as dots).
            ViewThatFits(in: .horizontal) {
                stageBubblesGroup(compact: false)
                stageBubblesGroup(compact: true)
            }

            if viewModel.canCancelSetup {
                cancelSetupButton
            }
        }
        .frame(height: 52)
        .padding(.leading, 82) // Safe clearance for macOS traffic lights (red, yellow, green)
        .padding(.trailing, 24)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Cancel (re-runs only)
    private var cancelSetupButton: some View {
        Button {
            viewModel.cancelSetup(themeManager: themeManager, onComplete: onComplete)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(theme.secondaryText)
                .frame(width: 26, height: 26)
                .background(theme.secondaryBackground.opacity(0.6))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .pointingHandCursor()
        .help("Cancel setup and keep your current profiles and theme (Esc)")
        .accessibilityLabel("Cancel Setup")
    }

    // MARK: - Stage Bubbles Group
    private func stageBubblesGroup(compact: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(OnboardingViewModel.Step.allCases) { step in
                stageBubbleItem(step: step, compact: compact)
            }
        }
        .padding(3)
        .background(theme.secondaryBackground.opacity(0.6))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(theme.dividerColor.opacity(0.4), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Setup progress")
    }

    @ViewBuilder
    private func stageBubbleItem(step: OnboardingViewModel.Step, compact: Bool) -> some View {
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
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isSelected)
            .accessibilityHint("Current step")
        } else if isPast {
            // Clickable Completed Stage with Hover Feedback
            PastStageBubbleButton(step: step, compact: compact) {
                viewModel.goToStep(step)
            }
            .disabled(viewModel.isDownloading)
        } else {
            // Inactive / Upcoming Stage
            Group {
                if compact {
                    Circle()
                        .fill(theme.secondaryText.opacity(0.35))
                        .frame(width: 6, height: 6)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 10)
                        .help(step.title)
                } else {
                    Text(step.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(step.title)
        }
    }
}

// MARK: - Window Accessor for Onboarding
// Why: must not re-run on `updateNSView` (it would fight user resizing), and `minSize` must be restored on exit
/// Sizes and centres the window once when onboarding appears and restores the window when onboarding goes away.
struct OnboardingWindowAccessor: NSViewRepresentable {
    static let targetSize = NSSize(width: 880, height: 800)
    static let minimumSize = NSSize(width: 840, height: 720)

    final class Coordinator {
        weak var window: NSWindow?
        var previousMinSize: NSSize?
        var previousFrame: NSRect?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            Self.configureOnce(window, coordinator: coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Only for the case where the view had no window yet when it was made.
        guard context.coordinator.window == nil else { return }
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            Self.configureOnce(window, coordinator: coordinator)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        guard let window = coordinator.window else { return }
        if let previousMinSize = coordinator.previousMinSize {
            window.minSize = previousMinSize
        }
        // Give the window back at the size it had, when that was at least onboarding's size (the
        // main app's layout). A smaller window stays where onboarding left it rather than shrink.
        if let previousFrame = coordinator.previousFrame {
            window.setFrame(previousFrame, display: true, animate: true)
        }
    }

    static func configureOnce(_ window: NSWindow, coordinator: Coordinator) {
        guard coordinator.window == nil else { return }
        coordinator.window = window
        coordinator.previousMinSize = window.minSize
        let isLargerThanOnboarding = window.frame.width >= targetSize.width && window.frame.height >= targetSize.height
        coordinator.previousFrame = isLargerThanOnboarding ? window.frame : nil

        window.minSize = minimumSize
        let size = window.frame.size
        guard abs(size.height - targetSize.height) > 15 || abs(size.width - targetSize.width) > 15 else { return }
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let frame = NSRect(x: visible.origin.x + (visible.width - targetSize.width) / 2,
                               y: visible.origin.y + (visible.height - targetSize.height) / 2,
                               width: targetSize.width, height: targetSize.height)
            window.setFrame(frame, display: true, animate: true)
        } else {
            window.setContentSize(targetSize)
        }
    }
}

// MARK: - Past Stage Bubble Button with Hover Effect
private struct PastStageBubbleButton: View {
    let step: OnboardingViewModel.Step
    var compact: Bool = false
    let action: () -> Void
    @Environment(\.appTheme) private var theme
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.green)
                if !compact {
                    Text(step.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
                }
            }
            .padding(.horizontal, compact ? 7 : 10)
            .padding(.vertical, 6)
            .background(isHovered ? Color.green.opacity(0.18) : Color.green.opacity(0.08))
            .clipShape(Capsule())
            .scaleEffect(isHovered ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(step.title)
        .accessibilityLabel(step.title)
        .accessibilityHint("Completed. Go back to this step.")
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
