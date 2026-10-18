// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RecordingOverlayView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import Combine

struct RecordingOverlayView: View {

    // The display store is passed through but not observed here; only child views that need specific properties
    // observe it, so the container does not re-render on every update.
    let displayStore: RecordingDisplayStore

    // MARK: - Actions
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            // Each child observes only what it needs from the store
            LiveTranscriptionTextView(store: displayStore)

            HStack(alignment: .center, spacing: 10) {
                cancelButton
                WaveformBarView(store: displayStore)
                TimerTextView(store: displayStore)
                confirmButton
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .padding(.top, 6)
        .frame(minHeight: 58)
        // Match mainInputArea chrome exactly so toggling voice input doesn't visibly swap materials.
        .appSurface(
            in: .rect(cornerRadius: 18),
            elevation: .elevated,
            strokeWidth: theme.isDark ? 0.5 : 0.75
        )
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    // MARK: - Controls

    private var cancelButton: some View {
        ComposerIconButton(
            systemName: "xmark",
            help: "Cancel recording (Esc)",
            action: onCancel
        )
        .keyboardShortcut(.cancelAction)
    }

    private var confirmButton: some View {
        ComposerPrimaryButton(
            systemName: "checkmark",
            help: "Stop and transcribe (↩)",
            action: onConfirm
        )
        .keyboardShortcut(.defaultAction)
    }
}

// MARK: - Isolated Waveform View
// Reads the @Observable store directly: observation tracking re-renders only views that read a changed property.
// No `@State` mirror or `.onChange` sync, which risks modifying state during a view update.

private struct WaveformBarView: View {
    let store: RecordingDisplayStore
    @Environment(\.appTheme) private var theme
    @Environment(\.buttonAccentStyle) private var buttonAccentStyle

    private let maxBarHeight: CGFloat = 24.0

    private var barColor: Color {
        if buttonAccentStyle == .themeContrast {
            return theme.isDark ? Color.white.opacity(0.85) : Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.85)
        }
        return theme.accentColor.opacity(0.85)
    }

    var body: some View {
        // Bound in body (not only inside the Canvas closure) so @Observable
        // tracking registers the dependency; the render closure captures the value.
        let powerLevels = store.powerLevels
        Canvas { context, size in
            let count = powerLevels.count
            guard count > 0 else { return }

            let barWidth: CGFloat = 2.0
            let spacing: CGFloat = 2.0

            // Total width requested by the bars
            let totalNeededWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * spacing

            // Scale down width and spacing gracefully if the parent view is compressed
            let scale = min(1.0, size.width / totalNeededWidth)
            let actualBarWidth = barWidth * scale
            let actualSpacing = spacing * scale

            let totalActualWidth = CGFloat(count) * actualBarWidth + CGFloat(count - 1) * actualSpacing
            let startX = (size.width - totalActualWidth) / 2.0

            for (index, level) in powerLevels.enumerated() {
                // Sanitize values to protect against NaN/Infinity layout crashes
                let safeLevel = level.isFinite && !level.isNaN ? CGFloat(max(0.0, min(1.0, level))) : 0.0

                // Keep a baseline height of 1.5px for flatlines
                let height = max(1.5, safeLevel * size.height)

                let x = startX + CGFloat(index) * (actualBarWidth + actualSpacing)
                let y = (size.height - height) / 2.0

                let rect = CGRect(x: x, y: y, width: actualBarWidth, height: height)
                let path = Path(roundedRect: rect, cornerRadius: 1.0 * scale)

                context.fill(path, with: .color(barColor))
            }
        }
        .frame(height: maxBarHeight, alignment: .center)
    }
}

// MARK: - Isolated Timer Text View
// Reads `store.recordingTime` directly. `isPulsing` stays `@State`: it drives the repeatForever animation,
// not a store mirror.

private struct TimerTextView: View {
    let store: RecordingDisplayStore
    @State private var isPulsing = false
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            // Pulsing recording indicator dot
            Circle()
                .fill(theme.errorColor)
                .frame(width: 7, height: 7)
                .scaleEffect(isPulsing ? 1.25 : 1.0)
                .opacity(isPulsing ? 0.6 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
                // Reduce Motion: keep the dot static — recording state is already
                // conveyed by the overlay itself and the running timer.
                .onAppear { if !reduceMotion { isPulsing = true } }

            Text(formatTime(store.recordingTime))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(theme.secondaryText)
        }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%01d:%02d", minutes, seconds)
    }
}

// MARK: - Isolated Live Transcription Text View
// Why: replacing it with a direct `store.liveTranscriptionText` read would make the text visibly vanish.
// This @State is derived, not a store mirror: it lags the store so smart buffering can hold the last good
// transcript through WhisperKit's sliding-window shrinks.

private struct LiveTranscriptionTextView: View {
    let store: RecordingDisplayStore
    @State private var liveTranscriptionText: String = ""
    @State private var clearTask: Task<Void, Never>?
    @Environment(\.appTheme) private var theme

    var body: some View {
        Group {
            if !liveTranscriptionText.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(liveTranscriptionText)
                            .font(theme.fontBody)
                            .foregroundColor(theme.primaryText)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .id("liveTextBottom")
                    }
                    .frame(maxHeight: 80)
                    .onChange(of: liveTranscriptionText) { _, _ in
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("liveTextBottom", anchor: .bottom)
                        }
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // Smoothly animate the first appearance of the scroll view
        .animation(.easeInOut(duration: 0.2), value: liveTranscriptionText.isEmpty)
        // Smoothly animate height changes when text wraps to new lines
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: liveTranscriptionText)

        // MARK: ARCHITECTURE UPDATE - Smart UI Buffering for Sliding Windows
        // WhisperKit's sliding window often drops unconfirmed text during pauses; delay text reductions so the
        // last good string stays on screen.
        .onChange(of: store.liveTranscriptionText) { _, newText in
            if newText.isEmpty && !self.liveTranscriptionText.isEmpty {
                clearTask?.cancel()
                clearTask = Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    if !Task.isCancelled {
                        await MainActor.run { self.liveTranscriptionText = "" }
                    }
                }
            } else if newText.count < self.liveTranscriptionText.count - 5 {
                clearTask?.cancel()
                clearTask = Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if !Task.isCancelled {
                        await MainActor.run { self.liveTranscriptionText = newText }
                    }
                }
            } else {
                clearTask?.cancel()
                self.liveTranscriptionText = newText
            }
        }
    }
}
