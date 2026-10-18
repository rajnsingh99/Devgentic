// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbFloatingView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit

/// Root of Orb's floating panel: a profile picker on first run or explicit switch, otherwise the wordless orb.
/// State is carried by the core visual's motion and color; the transcript and response stream into the chat underneath.
struct OrbFloatingView: View {
    let controller: OrbSessionController
    /// Reports which panel size the current stage needs.
    let onModeChange: (OrbPanelMode) -> Void
    let onClose: () -> Void

    /// The presentation the current stage needs. `.approval` only when there is genuinely
    /// something to answer — a parked stage with an empty queue would grow the panel to show
    /// nothing.
    private var panelMode: OrbPanelMode {
        if controller.stage == .selectingProfile { return .picker }
        if controller.stage == .awaitingApproval, controller.pendingInteraction != nil { return .approval }
        return .orb
    }

    var body: some View {
        Group {
            switch panelMode {
            case .picker:   pickerPresentation
            case .orb:      orbPresentation
            case .approval: approvalPresentation
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: panelMode, initial: false) { _, mode in
            onModeChange(mode)
        }
    }

    // MARK: - Approval

    /// The orb, shrunk, above the request. Keeping the orb visible matters: it is the anchor the
    /// user recognises, and the panel is the same window that was floating a moment ago.
    @ViewBuilder private var approvalPresentation: some View {
        if let pending = controller.pendingInteraction {
            VStack(spacing: 12) {
                OrbCoreVisual(mode: .processing, size: 78)
                OrbHITLBanner(pending: pending, controller: controller)
            }
            .padding(14)
            .background(pickerChrome)
        }
    }

    // MARK: - Picker

    private var pickerPresentation: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 12) {
                OrbCoreVisual(mode: .idle, size: 84)
                OrbProfilePickerView(controller: controller)
            }
            .padding(.top, 20)
            .padding(.bottom, 20)
            .padding(.horizontal, 20)

            // Dismiss button
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.65))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(14)
            .help("Close")
        }
        .background(pickerChrome)
    }

    private var pickerChrome: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.09, blue: 0.13).opacity(0.97),
                        Color(red: 0.04, green: 0.05, blue: 0.08).opacity(0.98)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.20), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.65), radius: 32, y: 12)
    }

    // MARK: - Orb

    private var orbPresentation: some View {
        ZStack {
            VStack(spacing: 8) {
                OrbCoreVisual(
                    mode: coreMode,
                    level: controller.audioLevel,
                    energy: controller.energyLevels,
                    size: 135
                )
                .contentShape(Circle())
                .onTapGesture { handleOrbTap() }
                .help(orbTooltip)
                // The orb is the feature's only control: expose it to VoiceOver as one labelled button that carries its stage.
                // `.accessibilityAction`, not just the trait: activate does not reliably fire a bare `onTapGesture` on a shape.
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text("Orb"))
                .accessibilityValue(Text(Self.accessibilityStatus(
                    stage: controller.stage, micTrouble: controller.micTroubleDetected)))
                .accessibilityHint(Text(orbTooltip))
                .accessibilityAction { handleOrbTap() }
                // Every context-menu item is also an accessibility action, so the recovery paths (Repair Audio, Cancel)
                // do not depend on a pointer; they surface in VoiceOver's Actions rotor.
                .accessibilityActions { orbActions }
                .contextMenu { orbActions }

                statusCapsule
                transcriptCaption
            }

            // Close, floated off the orb's top-right and shown only while the pointer is over the panel, so the resting orb
            // stays wordless. Hidden also means out of the hit-test and accessibility tree.
            OrbBubbleButton(
                systemName: "xmark",
                help: "Close Orb",
                action: onClose
            )
            .offset(x: 92, y: -54)
            .opacity(isPanelHovered ? 1 : 0)
            .allowsHitTesting(isPanelHovered)
            .accessibilityHidden(!isPanelHovered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.001))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isPanelHovered = hovering }
        }
    }

    /// The pointer is over the orb panel — the close button shows only then.
    @State private var isPanelHovered = false

    // Why: one list for both surfaces: written twice they would drift, and the accessible copy is the one nobody checks.
    /// The orb's actions, shared by the right-click menu and VoiceOver's Actions rotor.
    @ViewBuilder private var orbActions: some View {
        Button("Switch Profile…") { controller.requestProfileSwitch() }
        if case .voiceUnavailable = controller.stage {
            Button("Retry Voice") { controller.retryVoice() }
        }
        // Offered as soon as the microphone misbehaves, not only after Orb gives
        // up — the wedge survives relaunching the app, so waiting is never useful.
        if controller.micTroubleDetected || controller.isVoiceUnavailable {
            Button("Repair Audio…") { controller.repairAudio() }
        }
        if controller.stage == .passiveListening {
            Button("Speak Now (skip wake word)") { controller.armManualCapture() }
        }
        if controller.stage == .commandCapture {
            Button("Send What I Said") { controller.commitCaptureNow() }
            // The abort path: a tap on the orb sends, so this is the way to stop a mis-transcription
            // from reaching a profile with shell and filesystem tools.
            Button("Cancel — Don't Send") { controller.cancelCapture() }
        }
        if controller.isExecuting {
            Button("Stop Current Task") { controller.stopExecution() }
        }
        if controller.stage == .announcing {
            Button("Stop Speaking") { controller.bargeIn() }
        }
        Divider()
        Button("Close Orb") { onClose() }
    }

    // Why: sentence case, not the capsule's capitalized `statusText`: a screen reader may spell capitals out letter by letter.
    /// What VoiceOver reads as the orb's value. Pure, so every stage is guaranteed to say something.
    static func accessibilityStatus(stage: OrbStage, micTrouble: Bool) -> String {
        switch stage {
        case .selectingProfile:  return String(localized: "Choosing a profile")
        case .welcoming:         return String(localized: "Starting up")
        case .passiveListening:  return micTrouble
            ? String(localized: "No audio from the microphone")
            : String(localized: "Standing by")
        case .commandCapture:    return String(localized: "Listening")
        case .followUpWindow:    return String(localized: "Listening for a follow-up")
        case .executing:         return String(localized: "Working")
        case .awaitingApproval:  return String(localized: "Waiting for your answer")
        case .announcing:        return String(localized: "Speaking")
        case .voiceUnavailable:  return String(localized: "Voice input unavailable")
        }
    }

    /// Tactile Dark Glass floating status capsule underneath the orb.
    private var statusCapsule: some View {
        HStack(spacing: 7) {
            OrbStatusDot(color: statusColor, stage: controller.stage)

            Text(statusText)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(2.0)
                .foregroundColor(OrbPalette.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(
            ZStack {
                Capsule()
                    .fill(.ultraThinMaterial)
                Capsule()
                    .fill(Color.black.opacity(0.60))
            }
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.28), Color.white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(color: Color.black.opacity(0.40), radius: 10, x: 0, y: 4)
        .shadow(color: statusColor.opacity(0.25), radius: 8, x: 0, y: 2)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: controller.stage)
        // The orb already exposes this as its accessibility VALUE; announcing it again as a
        // separate element makes every stage change read twice.
        .accessibilityHidden(true)
    }

    // Why: required, not a setting: a mis-transcribed command reaches a profile with shell tools, so the user must see it.
    /// What Orb currently thinks you said, shown only while capture is armed and gone the moment it commits.
    @ViewBuilder private var transcriptCaption: some View {
        if controller.stage == .commandCapture, !controller.commandPreview.isEmpty {
            Text(controller.commandPreview)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(OrbPalette.textSecondary)
                .lineLimit(2)
                .truncationMode(.head)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 250)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(OrbPalette.backgroundTop.opacity(0.75)))
                .transition(.opacity)
                .accessibilityLabel("Heard: \(controller.commandPreview)")
        }
    }

    private var statusColor: Color {
        switch controller.stage {
        case .selectingProfile, .welcoming: return OrbPalette.hologram
        // Amber while the microphone is failing but retries continue — a healthy-looking
        // STANDBY over a dead mic is the thing this whole warning exists to prevent.
        case .passiveListening:             return controller.micTroubleDetected ? OrbPalette.gold : OrbPalette.hologram
        case .commandCapture:               return OrbPalette.hologram
        case .followUpWindow:               return OrbPalette.successEmerald
        case .executing:                    return OrbPalette.gold
        case .awaitingApproval:             return OrbPalette.gold
        case .announcing:                   return OrbPalette.successEmerald
        case .voiceUnavailable:             return OrbPalette.alert
        }
    }

    // Why: needs `String(localized:)`: `Text(statusText)` with a `String` uses SwiftUI's non-localizing initializer.
    /// The status word shown in the HUD capsule, localized.
    private var statusText: String {
        switch controller.stage {
        case .selectingProfile:  return String(localized: "SELECTING")
        case .welcoming:         return String(localized: "INITIALIZING")
        case .passiveListening:  return controller.micTroubleDetected
            ? String(localized: "NO AUDIO")
            : String(localized: "STANDBY")
        case .commandCapture:    return String(localized: "LISTENING")
        case .followUpWindow:    return String(localized: "GO AHEAD")
        case .executing:         return String(localized: "THINKING")
        case .awaitingApproval:  return String(localized: "WAITING ON YOU")
        case .announcing:        return String(localized: "COMPLETE")
        case .voiceUnavailable:  return String(localized: "OFFLINE")
        }
    }

    /// Maps the session stage onto the core visual's expression.
    private var coreMode: OrbCoreMode {
        switch controller.stage {
        case .selectingProfile:  return .idle
        case .welcoming:         return .greeting
        case .passiveListening:  return .passive
        // The microphone really is hot, so it gets the hot-mic expression rather than standby's.
        case .commandCapture, .followUpWindow: return .capturing
        case .executing, .awaitingApproval: return .processing
        case .announcing:        return .speaking
        case .voiceUnavailable:  return .alert
        }
    }

    private func handleOrbTap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        switch controller.stage {
        case .passiveListening:  controller.armManualCapture()
        case .commandCapture:    controller.commitCaptureNow()
        // Tapping during the answer cuts it short. Until full duplex lands the microphone is
        // closed while Orb speaks, so this tap is the only way to interrupt.
        case .announcing:        controller.bargeIn()
        default:                 break
        }
    }

    /// The only text in orb mode — a hover tooltip, so a failure state is still
    /// explainable without breaking the wordless presentation.
    private var orbTooltip: String {
        switch controller.stage {
        case .selectingProfile:  return String(localized: "Select a profile")
        case .welcoming:         return String(localized: "Starting up")
        case .passiveListening:
            if controller.micTroubleDetected {
                return String(localized: "The microphone opened but delivered no audio — right-click to repair")
            }
            // A wake word that cannot match in the configured speech language must say so, or the orb looks alive and ignores
            // the user. The wake word stays untranslated: it is an acoustic token.
            return controller.wakeWordUnavailable
                ? String(localized: "Standing by — click to speak (the wake word can’t work in this speech language)")
                : String(localized: "Standing by — say “\(OrbSessionController.wakeWord)”, or click to speak")
        case .commandCapture:    return String(localized: "Listening — click to send, or right-click to cancel")
        case .followUpWindow:    return String(localized: "Go ahead — ask a follow-up, no wake word needed")
        case .executing:         return String(localized: "Working — follow along in the chat window")
        case .awaitingApproval:  return String(localized: "Waiting for you to answer")
        case .announcing:        return String(localized: "Speaking — click to stop")
        // Already localized at the source — these are the sentences the listening loops build.
        case .voiceUnavailable(let reason): return reason
        }
    }
}

// MARK: - Bubble button

/// A tactile dark glass bubble orbiting the orb for quick configuration.
struct OrbBubbleButton: View {
    let systemName: String
    // Why: must be `LocalizedStringKey`: a `String` silently selects the non-localizing `.help` and
    // `.accessibilityLabel` overloads.
    /// Localized tooltip and accessibility label.
    let help: LocalizedStringKey
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            action()
        }) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isHovered ? .white : OrbPalette.textPrimary.opacity(0.85))
                .frame(width: 34, height: 34)
                .background(
                    ZStack {
                        Circle().fill(.ultraThinMaterial)
                        Circle().fill(Color.black.opacity(0.55))
                    }
                    .overlay(
                        Circle().fill(Color.white.opacity(isHovered ? 0.16 : 0.04))
                    )
                )
                .overlay(
                    Circle().stroke(
                        LinearGradient(
                            colors: isHovered
                                ? [Color.white.opacity(0.50), Color.white.opacity(0.20)]
                                : [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
                )
                .shadow(color: isHovered ? Color.cyan.opacity(0.4) : Color.black.opacity(0.25), radius: isHovered ? 8 : 4)
                .scaleEffect(isHovered ? 1.08 : 1.0)
                .opacity(isHovered ? 1.0 : 0.40)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHovered = hovering }
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Status Dot

/// Living breathing status dot with an ambient blurred aura halo that pulses synchronously.
struct OrbStatusDot: View {
    let color: Color
    let stage: OrbStage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 : 1.0 / 24.0)) { context in
            let t = reduceMotion ? 0.0 : context.date.timeIntervalSinceReferenceDate
            let pulsePeriod: Double = {
                switch stage {
                case .commandCapture, .followUpWindow: return 0.95 // brisk listening pulse
                case .executing, .awaitingApproval: return 1.35 // warm thinking pulse
                default: return 2.40 // calm standby breathing
                }
            }()
            let pulse = reduceMotion ? 1.0 : (1.0 + 0.16 * sin(t * 2 * .pi / pulsePeriod))
            let auraOpacity = reduceMotion ? 0.5 : (0.40 + 0.35 * (sin(t * 2 * .pi / pulsePeriod) + 1.0) * 0.5)

            ZStack {
                // Ambient pulsing aura halo behind the dot
                Circle()
                    .fill(color.opacity(auraOpacity))
                    .frame(width: 12, height: 12)
                    .blur(radius: 2.5)

                // Core dot with dynamic scale and glow shadow
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .scaleEffect(pulse)
                    .shadow(color: color.opacity(0.95), radius: 4)
            }
            .frame(width: 12, height: 12)
        }
    }
}
