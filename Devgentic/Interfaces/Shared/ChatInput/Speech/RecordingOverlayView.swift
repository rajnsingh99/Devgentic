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

    var body: some View {
        VStack(spacing: 8) {
            // Each child observes only what it needs from the store
            LiveTranscriptionTextView(store: displayStore)

            HStack(spacing: 16) {
                cancelButton
                WaveformBarView(store: displayStore)
                TimerTextView(store: displayStore)
                confirmButton
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
        }
        .frame(minHeight: 58)
        .background(VisualEffectBlur(material: .underWindowBackground, blendingMode: .withinWindow))
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    // MARK: - Controls

    private var cancelButton: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(isCancelHovering ? Color.red.opacity(0.9) : Color.gray.opacity(0.5))
                .clipShape(Circle())
                .scaleEffect(isCancelHovering ? 1.1 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isCancelHovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isCancelHovering)
        .help("Cancel recording")
    }

    private var confirmButton: some View {
        Button(action: onConfirm) {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(isConfirmHovering ? Color.accentColor.opacity(0.9) : Color.accentColor)
                .clipShape(Circle())
                .scaleEffect(isConfirmHovering ? 1.1 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isConfirmHovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isConfirmHovering)
        .help("Stop and transcribe")
    }
}

// MARK: - Isolated Waveform View
// Uses local state and .onReceive to achieve true isolation.

private struct WaveformBarView: View {
    let store: RecordingDisplayStore
    @State private var powerLevels: [Float] = []
    
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
            
            for (index, level) in powerLevels.enumerated() {
                // Sanitize values to protect against NaN/Infinity layout crashes
                let safeLevel = level.isFinite && !level.isNaN ? CGFloat(max(0.0, min(1.0, level))) : 0.0
                
                // Keep a baseline height of 1px for flatlines
                let height = max(1.0, safeLevel * size.height)
                
                let x = startX + CGFloat(index) * (actualBarWidth + actualSpacing)
                let y = (size.height - height) / 2.0
                
                let rect = CGRect(x: x, y: y, width: actualBarWidth, height: height)
                let path = Path(roundedRect: rect, cornerRadius: 1.5 * scale)
                
                context.fill(path, with: .color(.white))
            }
        }
        .frame(height: maxBarHeight, alignment: .center)
        // Only update this specific view when powerLevels changes
        .onReceive(store.$powerLevels) { newLevels in
            self.powerLevels = newLevels
        }
    }
}

// MARK: - Isolated Timer Text View

private struct TimerTextView: View {
    let store: RecordingDisplayStore
    @State private var recordingTime: TimeInterval = 0.0

    var body: some View {
        Text(formatTime(recordingTime))
            .font(.system(.body, design: .monospaced))
            .foregroundColor(.secondary)
            // Only update this specific view when recordingTime changes
            .onReceive(store.$recordingTime) { newTime in
                self.recordingTime = newTime
            }
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

    var body: some View {
        Group {
            if !liveTranscriptionText.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(liveTranscriptionText)
                            .font(.system(.body, design: .rounded))
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 15)
                            .id("liveTextBottom")
                    }
                    .frame(maxHeight: 80)
                    .onChange(of: liveTranscriptionText) { _ in
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
        .onReceive(
            store.$liveTranscriptionText
                .removeDuplicates()
                .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
        ) { newText in
            if newText.isEmpty && !self.liveTranscriptionText.isEmpty {
                // Total buffer reset (e.g., long silence). Wait 2.5s before clearing.
                clearTask?.cancel()
                clearTask = Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000) // 2.5s tolerance
                    if !Task.isCancelled {
                        await MainActor.run { self.liveTranscriptionText = "" }
                    }
                }
            } else if newText.count < self.liveTranscriptionText.count - 5 {
                // Partial drop: The text shrank significantly. Hold the longer text
                // for 1.5s to see if Whisper catches back up before shrinking the UI.
                clearTask?.cancel()
                clearTask = Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s tolerance
                    if !Task.isCancelled {
                        await MainActor.run { self.liveTranscriptionText = newText }
                    }
                }
            } else {
                // Valid update: text grew or had a minor length correction.
                clearTask?.cancel()
                self.liveTranscriptionText = newText
            }
        }
    }
}
