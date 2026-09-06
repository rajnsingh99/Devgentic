//
//  JarvisHITLBanner.swift
//  Devgentic
//
//  [Phase 3] The orb's answer to a parked run.
//
//  ⚠️ Why this exists rather than reusing QuickAccessHITLBanner: that banner is typed on
//  `QuickAccessSessionViewModel` and paints with the app theme, while the Jarvis panel forces
//  `.darkAqua` and its own hologram palette. Sharing it would have meant genericizing a
//  keyboard-driven surface AND theming it two ways; a small dedicated banner is less code and
//  reads as part of the orb.
//
//  ⚠️ WHY IT RENDERS IN THE ORB AND DOES NOT FORCE THE MAIN WINDOW FORWARD. Three source facts:
//  the Jarvis panel is already `.canJoinAllSpaces`, so it is on whatever desktop the user is on;
//  the main window sets NO collectionBehavior, so activating it TELEPORTS the user's desktop to
//  wherever that window lives; and `activateMainWindow()` returns false outright when the window
//  is closed, which is routine when the app runs from the shortcut. Forcing the window forward
//  is therefore both more disruptive and less reliable. "Open in Chat" stays available as a
//  deliberate escalation for reading and editing arguments.
//
//  ⚠️ NOTHING HERE IS APPROVABLE BY VOICE. The user reads the tool name and its arguments and
//  clicks. An ASR transcript must never be what authorizes code execution.
//

import SwiftUI

struct JarvisHITLBanner: View {
    let pending: PendingHITL
    let controller: JarvisSessionController

    @State private var clarificationText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            Button("Open in Chat") { controller.openInMainWindow() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(JarvisPalette.hologram.opacity(0.8))
                .help("Show this in the main window, where arguments can be edited")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(JarvisPalette.backgroundTop.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(JarvisPalette.gold.opacity(0.45), lineWidth: 1)
                )
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(JarvisPalette.gold)
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(JarvisPalette.textPrimary)
        }
    }

    private var title: String {
        switch pending.kind {
        case .toolConfirmation: return String(localized: "Approval needed")
        case .clarification:    return String(localized: "Question")
        case .planReview:       return String(localized: "Review the plan")
        case .gate:             return String(localized: "Choose how to continue")
        }
    }

    @ViewBuilder private var content: some View {
        switch pending.kind {
        case .toolConfirmation(let confirmation):
            VStack(alignment: .leading, spacing: 8) {
                Text(confirmation.toolName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(JarvisPalette.hologram)
                // ⚠️ The arguments are shown, never spoken. Approving something you have only
                // heard paraphrased is how a misheard approval becomes an executed command.
                if !confirmation.params.isEmpty {
                    ScrollView {
                        Text(confirmation.params)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(JarvisPalette.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                }
                HStack(spacing: 8) {
                    actionButton("Approve", tint: JarvisPalette.successEmerald) {
                        controller.approveTool(pending)
                    }
                    actionButton("Deny", tint: JarvisPalette.alert) {
                        controller.denyTool(pending)
                    }
                }
            }

        case .clarification(let clarification):
            VStack(alignment: .leading, spacing: 8) {
                Text(clarification.question)
                    .font(.system(size: 11))
                    .foregroundColor(JarvisPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let options = clarification.options, !options.isEmpty {
                    // One-tap choices, so the common case needs no typing on a panel that
                    // deliberately does not take keyboard focus.
                    ForEach(options, id: \.self) { option in
                        actionButton(option, tint: JarvisPalette.hologram) {
                            controller.submitClarification(pending, text: option)
                        }
                    }
                } else {
                    TextField("Your answer", text: $clarificationText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit { controller.submitClarification(pending, text: clarificationText) }
                    actionButton("Send", tint: JarvisPalette.hologram) {
                        controller.submitClarification(pending, text: clarificationText)
                    }
                }
            }

        case .planReview(let plan):
            VStack(alignment: .leading, spacing: 8) {
                Text("\(plan.subtasks.count) step(s) planned")
                    .font(.system(size: 11))
                    .foregroundColor(JarvisPalette.textSecondary)
                // Editing a plan needs room this panel does not have — the main window owns that.
                Text("Open in Chat to edit the steps before approving.")
                    .font(.system(size: 10))
                    .foregroundColor(JarvisPalette.textSecondary.opacity(0.8))
                HStack(spacing: 8) {
                    actionButton("Approve", tint: JarvisPalette.successEmerald) {
                        controller.resolvePlan(pending, approved: true)
                    }
                    actionButton("Reject", tint: JarvisPalette.alert) {
                        controller.resolvePlan(pending, approved: false)
                    }
                }
            }

        case .gate(let gate):
            VStack(alignment: .leading, spacing: 8) {
                Text(gate.prompt)
                    .font(.system(size: 11))
                    .foregroundColor(JarvisPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(gate.options, id: \.self) { option in
                    actionButton(option, tint: JarvisPalette.hologram) {
                        controller.chooseGate(pending, option: option)
                    }
                }
            }
        }
    }

    private func actionButton(_ label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(tint.opacity(0.15)))
                .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
