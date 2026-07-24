//
//  JarvisFloatingView.swift
//  Devgentic
//
//  [Jarvis MVP] Root of the floating panel. Two presentations:
//
//  • Profile picker — first run only (and on an explicit switch). The chosen profile
//    is remembered, so every later launch goes straight to the orb.
//  • Orb — deliberately WORDLESS, Siri-style: state is carried entirely by the core
//    visual's motion and color. The transcript and the agent's response are not
//    duplicated here; they stream into the real chat interface underneath, which
//    Jarvis brings into view when a run starts.
//

import SwiftUI

struct JarvisFloatingView: View {
    let controller: JarvisSessionController
    /// Reports which panel size the current stage needs.
    let onModeChange: (Bool) -> Void
    let onClose: () -> Void

    private var isPickerMode: Bool { controller.stage == .selectingProfile }

    var body: some View {
        Group {
            if isPickerMode {
                pickerPresentation
            } else {
                orbPresentation
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: isPickerMode, initial: false) { _, isPicker in
            onModeChange(isPicker)
        }
    }

    // MARK: - Picker

    private var pickerPresentation: some View {
        VStack(spacing: 20) {
            JarvisCoreVisual(mode: .idle, size: 110)
            JarvisProfilePickerView(controller: controller)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 18)
        .background(pickerChrome)
    }

    private var pickerChrome: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(JarvisPalette.backgroundTop.opacity(0.96))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(JarvisPalette.hologram.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
    }

    // MARK: - Orb

    private var orbPresentation: some View {
        ZStack {
            VStack(spacing: 8) {
                JarvisCoreVisual(
                    mode: coreMode,
                    level: controller.audioLevel,
                    energy: controller.energyLevels,
                    size: 175
                )
                .contentShape(Circle())
                .onTapGesture { handleOrbTap() }
                .help(orbTooltip)
                .contextMenu {
                    Button("Switch Profile…") { controller.requestProfileSwitch() }
                    if case .voiceUnavailable = controller.stage {
                        Button("Retry Voice") { controller.retryVoice() }
                    }
                    if controller.stage == .passiveListening {
                        Button("Speak Now (skip wake word)") { controller.armManualCapture() }
                    }
                    if controller.stage == .commandCapture {
                        Button("Send What I Said") { controller.commitCaptureNow() }
                    }
                    if controller.isExecuting {
                        Button("Stop Current Task") { controller.stopExecution() }
                    }
                    Divider()
                    Button("Close Jarvis") { onClose() }
                }

                statusCapsule
            }

            // Config bubbles, floated off the orb's top-right
            VStack(spacing: 10) {
                JarvisBubbleButton(
                    systemName: "person.crop.circle",
                    help: "Switch profile",
                    action: { controller.requestProfileSwitch() }
                )
            }
            .offset(x: 104, y: -72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.001))
    }

    /// Futuristic floating HUD status capsule underneath the orb.
    private var statusCapsule: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .shadow(color: statusColor.opacity(0.8), radius: 3)
            Text(statusText)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(2.5)
                .foregroundColor(JarvisPalette.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(JarvisPalette.backgroundTop.opacity(0.88))
        )
        .overlay(
            Capsule()
                .strokeBorder(JarvisPalette.glassBorderGradient, lineWidth: 1)
        )
        .shadow(color: statusColor.opacity(0.22), radius: 8, x: 0, y: 3)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: controller.stage)
    }

    private var statusColor: Color {
        switch controller.stage {
        case .selectingProfile, .welcoming: return JarvisPalette.hologram
        case .passiveListening:             return JarvisPalette.hologram
        case .commandCapture:               return JarvisPalette.hologram
        case .executing:                    return JarvisPalette.gold
        case .announcing:                   return JarvisPalette.successEmerald
        case .voiceUnavailable:             return JarvisPalette.alert
        }
    }

    private var statusText: String {
        switch controller.stage {
        case .selectingProfile:  return "SELECTING"
        case .welcoming:         return "INITIALIZING"
        case .passiveListening:  return "STANDBY"
        case .commandCapture:    return "LISTENING"
        case .executing:         return "THINKING"
        case .announcing:        return "COMPLETE"
        case .voiceUnavailable:  return "OFFLINE"
        }
    }

    /// Maps the session stage onto the core visual's expression.
    private var coreMode: JarvisCoreMode {
        switch controller.stage {
        case .selectingProfile:  return .idle
        case .welcoming:         return .greeting
        case .passiveListening:  return .passive
        case .commandCapture:    return .capturing
        case .executing:         return .processing
        case .announcing:        return .speaking
        case .voiceUnavailable:  return .alert
        }
    }

    private func handleOrbTap() {
        switch controller.stage {
        case .passiveListening:  controller.armManualCapture()
        case .commandCapture:    controller.commitCaptureNow()
        default:                 break
        }
    }

    /// The only text in orb mode — a hover tooltip, so a failure state is still
    /// explainable without breaking the wordless presentation.
    private var orbTooltip: String {
        switch controller.stage {
        case .selectingProfile:  return "Select a profile"
        case .welcoming:         return "Starting up"
        case .passiveListening:  return "Standing by — say “Jarvis”, or click to speak"
        case .commandCapture:    return "Listening — click to send"
        case .executing:         return "Working — follow along in the chat window"
        case .announcing:        return "Task complete"
        case .voiceUnavailable(let reason): return reason
        }
    }
}

// MARK: - Bubble button

/// A small hologram bubble orbiting the orb — the config affordances from the sketch.
struct JarvisBubbleButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isHovered ? JarvisPalette.textPrimary : JarvisPalette.hologram)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(JarvisPalette.hologram.opacity(isHovered ? 0.25 : 0.12))
                        .overlay(
                            Circle().stroke(
                                isHovered ? JarvisPalette.hologram.opacity(0.85) : JarvisPalette.hologram.opacity(0.45),
                                lineWidth: 1
                            )
                        )
                )
                .shadow(color: JarvisPalette.hologram.opacity(isHovered ? 0.6 : 0.25), radius: isHovered ? 8 : 5)
                .scaleEffect(isHovered ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHovered = hovering }
        }
        .help(help)
        .accessibilityLabel(help)
    }
}
