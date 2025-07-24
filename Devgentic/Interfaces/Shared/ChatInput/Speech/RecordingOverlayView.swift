//
//  RecordingOverlayView.swift
//  Devgentic
//
//  Created by Raj Singh on 24/07/25.
//

import SwiftUI

struct RecordingOverlayView: View {
    
    // MARK: - Bindings
    @Binding var recordingTime: TimeInterval
    @Binding var powerLevels: [Float]
    
    // MARK: - Actions
    let onCancel: () -> Void
    let onConfirm: () -> Void
    
    // MARK: - State
    @State private var isCancelHovering: Bool = false
    @State private var isConfirmHovering: Bool = false
    
    private let maxBarHeight: CGFloat = 40.0 // The max height of a waveform bar
    
    var body: some View {
        HStack(spacing: 16) {
            // Cancel Button
            cancelButton
            
            // Waveform View
            waveformView
            
            // Timer Text
            timerText
            
            // Confirm Button
            confirmButton
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .frame(minHeight: 58) // Match the approximate height of the input area
        .background(VisualEffectBlur(material: .underWindowBackground, blendingMode: .withinWindow))
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
    
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
    
    private var waveformView: some View {
        HStack(spacing: 2) {
            ForEach(0..<powerLevels.count, id: \.self) { index in
                let power = powerLevels[index]
                let barHeight = CGFloat(power) * maxBarHeight
                
                RoundedRectangle(cornerRadius: 1.5)
                    .frame(width: 2, height: max(1, barHeight))
                    .foregroundColor(.white)
            }
        }
        .frame(height: maxBarHeight, alignment: .center)
        .animation(.easeOut(duration: 0.05), value: powerLevels)
    }
    
    private var timerText: some View {
        Text(formatTime(recordingTime))
            .font(.system(.body, design: .monospaced))
            .foregroundColor(.secondary)
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
    
    private func formatTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%01d:%02d", minutes, seconds)
    }
}
