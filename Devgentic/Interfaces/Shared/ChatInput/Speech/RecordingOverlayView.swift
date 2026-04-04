//
//  RecordingOverlayView.swift
//  Devgentic
//
//  Created by Raj Singh on 24/07/25.
//

import SwiftUI
import Combine

struct RecordingOverlayView: View {

    // The display store is passed through but NOT observed here.
    // Only child views that need specific properties observe it,
    // preventing the overlay container from re-rendering on every update.
    let displayStore: RecordingDisplayStore

    // MARK: - Actions
    let onCancel: () -> Void
    let onConfirm: () -> Void

    // MARK: - State
    @State private var isCancelHovering: Bool = false
    @State private var isConfirmHovering: Bool = false

    @Environment(\.appTheme) private var theme

    // Match DynamicActionButton / toolbar sizing
    private let buttonSize: CGFloat = 30

    var body: some View {
        VStack(spacing: 6) {
            // Each child observes only what it needs from the store
            LiveTranscriptionTextView(store: displayStore)

            HStack(spacing: 12) {
                cancelButton
                WaveformBarView(store: displayStore)
                TimerTextView(store: displayStore)
                confirmButton
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(minHeight: 58)
        // Match mainInputArea chrome exactly
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.controlBackground)
                .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.surfaceOverlay, lineWidth: 1)
        )
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    // MARK: - Controls

    private var cancelButton: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isCancelHovering ? .white : theme.primaryText)
                .frame(width: buttonSize, height: buttonSize)
                .background(
                    Circle()
                        .fill(isCancelHovering ? theme.errorColor.opacity(0.9) : theme.secondaryText.opacity(0.18))
                )
        }
        .buttonStyle(.plain)
        .onHover { hover in withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { isCancelHovering = hover } }
        .help("Cancel recording")
        .accessibilityLabel("Cancel recording")
    }

    private var confirmButton: some View {
        Button(action: onConfirm) {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: buttonSize, height: buttonSize)
                .background(
                    Circle()
                        .fill(isConfirmHovering ? theme.controlAccent.opacity(0.85) : theme.controlAccent)
                        .shadow(color: theme.controlAccent.opacity(0.3), radius: 3, x: 0, y: 2)
                )
        }
        .buttonStyle(.plain)
        .onHover { hover in withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { isConfirmHovering = hover } }
        .help("Stop and transcribe")
        .accessibilityLabel("Stop and transcribe")
    }
}

// MARK: - Isolated Waveform View
// Uses local state and .onReceive to achieve true isolation.

private struct WaveformBarView: View {
    let store: RecordingDisplayStore
    @State private var powerLevels: [Float] = []
    @Environment(\.appTheme) private var theme

    private let maxBarHeight: CGFloat = 40.0

    var body: some View {
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

            // Resolve themed color for Canvas rendering
            let barColor = theme.controlAccent.opacity(0.7)

            for (index, level) in powerLevels.enumerated() {
                // Sanitize values to protect against NaN/Infinity layout crashes
                let safeLevel = level.isFinite && !level.isNaN ? CGFloat(max(0.0, min(1.0, level))) : 0.0

                // Keep a baseline height of 1px for flatlines
                let height = max(1.0, safeLevel * size.height)

                let x = startX + CGFloat(index) * (actualBarWidth + actualSpacing)
                let y = (size.height - height) / 2.0

                let rect = CGRect(x: x, y: y, width: actualBarWidth, height: height)
                let path = Path(roundedRect: rect, cornerRadius: 1.5 * scale)

                context.fill(path, with: .color(barColor))
            }
        }
        .frame(height: maxBarHeight, alignment: .center)
        // Only update this specific view when powerLevels changes
        .onChange(of: store.powerLevels) { _, newLevels in
            self.powerLevels = newLevels
        }
        .onAppear { self.powerLevels = store.powerLevels }
    }
}

// MARK: - Isolated Timer Text View

private struct TimerTextView: View {
    let store: RecordingDisplayStore
    @State private var recordingTime: TimeInterval = 0.0
    @State private var isPulsing = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            // Pulsing recording indicator dot
            Circle()
                .fill(theme.errorColor)
                .frame(width: 8, height: 8)
                .scaleEffect(isPulsing ? 1.3 : 1.0)
                .opacity(isPulsing ? 0.6 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
                .onAppear { isPulsing = true }

            Text(formatTime(recordingTime))
                .font(.system(.body, design: .monospaced))
                .foregroundColor(theme.secondaryText)
        }
        // Only update this specific view when recordingTime changes
        .onChange(of: store.recordingTime) { _, newTime in
            self.recordingTime = newTime
        }
        .onAppear { self.recordingTime = store.recordingTime }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%01d:%02d", minutes, seconds)
    }
}

// MARK: - Isolated Live Transcription Text View

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
                            .font(.system(size: 14))
                            .foregroundColor(theme.primaryText)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .id("liveTextBottom")
                    }
                    .frame(maxHeight: 80)
                    .onChange(of: liveTranscriptionText) { _, _ in
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("liveTextBottom", anchor: .bottom)
                        }
                    }
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // Smoothly animate the first appearance of the scroll view
        .animation(.easeInOut(duration: 0.2), value: liveTranscriptionText.isEmpty)
        // Smoothly animate height changes when text wraps to new lines
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: liveTranscriptionText)

        // MARK: ARCHITECTURE UPDATE - Smart UI Buffering for Sliding Windows
        // WhisperKit's sliding window frequently drops unconfirmed text during pauses,
        // causing the text to "shrink" or "vanish" completely. We add a smart delay
        // to text reductions to hold the last known good string on screen.
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
