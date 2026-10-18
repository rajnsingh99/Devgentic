// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbHITLBanner.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// The orb's answer to a parked run: shows the tool name and arguments with approve/deny choices.
/// Renders inside the Orb panel in its own hologram palette rather than forcing the main window forward.
/// Nothing here is approvable by voice: the user reads the arguments and clicks.
struct OrbHITLBanner: View {
    let pending: PendingHITL
    let controller: OrbSessionController

    @State private var clarificationText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            Button("Open in Chat") { controller.openInMainWindow() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(OrbPalette.hologram.opacity(0.8))
                .help("Show this in the main window, where arguments can be edited")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OrbPalette.backgroundTop.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(OrbPalette.gold.opacity(0.45), lineWidth: 1)
                )
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(OrbPalette.gold)
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(OrbPalette.textPrimary)
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
                    .foregroundColor(OrbPalette.hologram)
                // The arguments are shown, never spoken: a misheard approval must not become an executed command.
                if !confirmation.params.isEmpty {
                    ScrollView {
                        Text(confirmation.params)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(OrbPalette.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                }
                HStack(spacing: 8) {
                    actionButton("Approve", tint: OrbPalette.successEmerald) {
                        controller.approveTool(pending)
                    }
                    actionButton("Deny", tint: OrbPalette.alert) {
                        controller.denyTool(pending)
                    }
                }
            }

        case .clarification(let clarification):
            VStack(alignment: .leading, spacing: 8) {
                Text(clarification.question)
                    .font(.system(size: 11))
                    .foregroundColor(OrbPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let options = clarification.options, !options.isEmpty {
                    // One-tap choices, so the common case needs no typing on a panel that
                    // deliberately does not take keyboard focus.
                    ForEach(options, id: \.self) { option in
                        actionButton(option, tint: OrbPalette.hologram) {
                            controller.submitClarification(pending, text: option)
                        }
                    }
                } else {
                    TextField("Your answer", text: $clarificationText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit { controller.submitClarification(pending, text: clarificationText) }
                    actionButton("Send", tint: OrbPalette.hologram) {
                        controller.submitClarification(pending, text: clarificationText)
                    }
                }
            }

        case .planReview(let plan):
            VStack(alignment: .leading, spacing: 8) {
                Text("\(plan.subtasks.count) step(s) planned")
                    .font(.system(size: 11))
                    .foregroundColor(OrbPalette.textSecondary)
                // Editing a plan needs room this panel does not have — the main window owns that.
                Text("Open in Chat to edit the steps before approving.")
                    .font(.system(size: 10))
                    .foregroundColor(OrbPalette.textSecondary.opacity(0.8))
                HStack(spacing: 8) {
                    actionButton("Approve", tint: OrbPalette.successEmerald) {
                        controller.resolvePlan(pending, approved: true)
                    }
                    actionButton("Reject", tint: OrbPalette.alert) {
                        controller.resolvePlan(pending, approved: false)
                    }
                }
            }

        case .gate(let gate):
            VStack(alignment: .leading, spacing: 8) {
                Text(gate.prompt)
                    .font(.system(size: 11))
                    .foregroundColor(OrbPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(gate.options, id: \.self) { option in
                    actionButton(option, tint: OrbPalette.hologram) {
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
