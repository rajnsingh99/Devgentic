//
//  AgentInterruptBannerView.swift
//  Devgentic
//
//  Sticky banner anchored above the chat input that handles both
//  ask_user clarifications and requiresConfirmation HITL permissions.
//  The in-history cards are read-only records; this is the lone interaction surface.
//

import SwiftUI

// MARK: - Main Banner View

struct AgentInterruptBannerView: View {
    @ObservedObject var message: ChatMessage
    @EnvironmentObject var mainAppViewModel: MainApplicationViewModel
    @Environment(\.appTheme) private var theme

    var body: some View {
        Group {
            if let clarification = message.pendingClarification {
                ClarificationBanner(clarification: clarification, message: message)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
            } else if let confirmation = message.pendingToolConfirmation {
                PermissionBanner(confirmation: confirmation, message: message)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
            }
        }
        // Match the chat input's width constraints exactly
        .frame(maxWidth: 1000)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal)
        .padding(.bottom, 6)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: message.pendingClarification != nil)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: message.pendingToolConfirmation != nil)
    }
}

// MARK: - Clarification Banner

private struct ClarificationBanner: View {
    let clarification: PendingClarification
    @ObservedObject var message: ChatMessage
    @EnvironmentObject var mainAppViewModel: MainApplicationViewModel
    @Environment(\.appTheme) private var theme

    @State private var userInput: String = ""
    @State private var isSubmitting: Bool = false
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row
            HStack(spacing: 7) {
                Circle()
                    .fill(theme.streamingIndicator)
                    .frame(width: 6, height: 6)
                    .shadow(color: theme.streamingIndicator.opacity(0.5), radius: 3)

                Text("Question")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.streamingIndicator)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Spacer()

                // Subtle dismiss hint
                Text("⎋ skip")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.tertiaryText.opacity(0.6))
            }

            // Question text
            Text(clarification.question)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            // Input row
            HStack(spacing: 8) {
                TextField("Type your answer...", text: $userInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(theme.primaryText)
                    .focused($isFocused)
                    .onSubmit { if canSend { submit() } }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.surfaceOverlay.opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isFocused ? theme.streamingIndicator.opacity(0.45) : theme.dividerColor.opacity(0.4), lineWidth: 1)
                    )

                // Skip button
                BannerActionButton(
                    label: "Skip",
                    icon: "arrow.uturn.left",
                    style: .ghost,
                    isDisabled: isSubmitting,
                    action: { skip() }
                )

                // Send button
                BannerActionButton(
                    label: "Send",
                    icon: "arrow.up",
                    style: .primary(color: theme.streamingIndicator),
                    isDisabled: !canSend,
                    action: { submit() }
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.streamingIndicator.opacity(0.15), lineWidth: 1)
        )
        .onAppear { isFocused = true }
    }

    private func submit() {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withAnimation { isSubmitting = true }
        mainAppViewModel.submitClarificationResponse(operationID: message.pendingClarification!.id, response: trimmed)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation { message.pendingClarification = nil }
        }
    }

    private func skip() {
        withAnimation { isSubmitting = true }
        mainAppViewModel.submitClarificationResponse(operationID: message.pendingClarification!.id, response: nil)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation { message.pendingClarification = nil }
        }
    }
}

// MARK: - Permission Banner

private struct PermissionBanner: View {
    let confirmation: PendingToolConfirmation
    @ObservedObject var message: ChatMessage
    @EnvironmentObject var mainAppViewModel: MainApplicationViewModel
    @Environment(\.appTheme) private var theme

    @State private var isProcessing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row
            HStack(spacing: 7) {
                Circle()
                    .fill(theme.warningColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: theme.warningColor.opacity(0.5), radius: 3)

                Text("Permission Required")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Spacer()
            }

            // Tool + params row
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)

                Text(confirmation.toolName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)

                if !confirmation.params.isEmpty && confirmation.params != "{}" {
                    Text("·")
                        .foregroundColor(theme.tertiaryText)

                    Text(confirmation.params)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(theme.surfaceOverlay.opacity(0.5))
            )

            // Button row
            HStack(spacing: 8) {
                Spacer()

                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                        .frame(height: 28)
                } else {
                    BannerActionButton(
                        label: "Deny",
                        icon: "xmark",
                        style: .ghost,
                        isDisabled: false,
                        action: { decide(approved: false) }
                    )

                    BannerActionButton(
                        label: "Allow",
                        icon: "checkmark",
                        style: .primary(color: theme.successColor),
                        isDisabled: false,
                        action: { decide(approved: true) }
                    )
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.warningColor.opacity(0.2), lineWidth: 1)
        )
    }

    private func decide(approved: Bool) {
        withAnimation { isProcessing = true }
        mainAppViewModel.submitToolApproval(operationID: confirmation.id, approved: approved)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation { message.pendingToolConfirmation = nil }
        }
    }
}

// MARK: - Shared Action Button

private enum BannerButtonStyle {
    case ghost
    case primary(color: Color)
}

private struct BannerActionButton: View {
    let label: String
    let icon: String
    let style: BannerButtonStyle
    let isDisabled: Bool
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    private var bgColor: Color {
        switch style {
        case .ghost:
            return isHovering ? theme.surfaceOverlay : Color.clear
        case .primary(let color):
            return isDisabled ? color.opacity(0.25) : (isHovering ? color.opacity(0.9) : color)
        }
    }

    private var fgColor: Color {
        switch style {
        case .ghost:
            return theme.secondaryText
        case .primary:
            return .white
        }
    }

    private var borderColor: Color {
        switch style {
        case .ghost:
            return theme.dividerColor.opacity(0.4)
        case .primary(let color):
            return color.opacity(0.3)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isDisabled ? fgColor.opacity(0.4) : fgColor)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(bgColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { isHovering = h } }
        .scaleEffect(isHovering && !isDisabled ? 1.02 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovering)
    }
}
