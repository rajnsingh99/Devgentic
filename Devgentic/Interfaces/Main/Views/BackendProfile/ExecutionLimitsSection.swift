//
//  ExecutionLimitsSection.swift
//  Devgentic
//
//  Created for Agent Capabilities Migration (Phase 0).
//  Exposes execution limits and error recovery to the user.
//

import SwiftUI

struct ExecutionLimitsSection: View {
    @Binding var maxIterations: Int?
    @Binding var executionTimeout: TimeInterval?
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Max Iterations
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Max Iterations")
                        .font(theme.fontBody.weight(.medium))
                    Text("Maximum reasoning cycles before forced termination")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer(minLength: 16)

                Stepper(
                    "\(maxIterations ?? 15)",
                    value: Binding(
                        get: { maxIterations ?? 15 },
                        set: { maxIterations = $0 == 15 ? nil : $0 }
                    ),
                    in: 3...30
                )
                .fixedSize()
            }

            // Execution Timeout
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Execution Timeout")
                        .font(theme.fontBody.weight(.medium))
                    Text("Maximum wall-clock time for a single execution")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer(minLength: 16)

                if let timeout = executionTimeout {
                    HStack(spacing: 8) {
                        Stepper(
                            "\(Int(timeout))s",
                            value: Binding(
                                get: { timeout },
                                set: { executionTimeout = $0 }
                            ),
                            in: 30...600,
                            step: 30
                        )
                        .fixedSize()

                        Button("Remove") {
                            executionTimeout = nil
                        }
                        .font(theme.fontCaption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else {
                    HStack(spacing: 8) {
                        Text("No limit")
                            .font(theme.fontCallout)
                            .foregroundColor(theme.secondaryText)

                        Button("Set") {
                            executionTimeout = 120
                        }
                        .font(theme.fontCaption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}

struct ErrorRecoverySection: View {
    @Binding var retryPolicy: RetryPolicy?
    @Binding var errorRecovery: ErrorRecovery?
    @Environment(\.appTheme) private var theme

    private var effectiveRetry: RetryPolicy { retryPolicy ?? RetryPolicy() }
    private var effectiveRecovery: ErrorRecovery { errorRecovery ?? ErrorRecovery() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Parse Failure Retries
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On Parse Failure")
                        .font(theme.fontBody.weight(.medium))
                    Text("When the model returns unparseable output")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer(minLength: 16)

                Picker("", selection: Binding(
                    get: { effectiveRetry.maxRetries },
                    set: {
                        var policy = effectiveRetry
                        policy.maxRetries = $0
                        retryPolicy = policy
                    }
                )) {
                    Text("Retry 1x").tag(1)
                    Text("Retry 3x").tag(3)
                    Text("Retry 5x").tag(5)
                }
                .labelsHidden()
                .fixedSize()
            }

            // Backoff Strategy
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Backoff Strategy")
                        .font(theme.fontBody.weight(.medium))
                    Text("Delay pattern between retries")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer(minLength: 16)

                Picker("", selection: Binding(
                    get: { effectiveRetry.backoffStrategy },
                    set: {
                        var policy = effectiveRetry
                        policy.backoffStrategy = $0
                        retryPolicy = policy
                    }
                )) {
                    ForEach(BackoffStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.rawValue.capitalized).tag(strategy)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            // Tool Failure Policy
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On Tool Failure")
                        .font(theme.fontBody.weight(.medium))
                    Text("When a tool execution fails repeatedly")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer(minLength: 16)

                Picker("", selection: Binding(
                    get: { effectiveRecovery.onToolFailure },
                    set: {
                        var recovery = effectiveRecovery
                        recovery.onToolFailure = $0
                        errorRecovery = recovery
                    }
                )) {
                    ForEach(ToolFailurePolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            // Fallback Prompt Custom Message (shown only when .fallbackPrompt is selected)
            if effectiveRecovery.onToolFailure == .fallbackPrompt {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Fallback Message")
                            .font(theme.fontCaption.weight(.medium))
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                        if effectiveRecovery.fallbackMessage != nil {
                            Button("Reset to Default") {
                                var recovery = effectiveRecovery
                                recovery.fallbackMessage = nil
                                errorRecovery = recovery
                            }
                            .font(theme.fontCaption)
                            .buttonStyle(.plain)
                            .foregroundColor(theme.accentColor)
                        }
                    }

                    TextEditor(text: Binding(
                        get: {
                            effectiveRecovery.fallbackMessage ?? ErrorRecovery.defaultFallbackMessage
                        },
                        set: { newValue in
                            var recovery = effectiveRecovery
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            recovery.fallbackMessage = trimmed == ErrorRecovery.defaultFallbackMessage ? nil : (trimmed.isEmpty ? nil : newValue)
                            errorRecovery = recovery
                        }
                    ))
                    .font(theme.fontBody)
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(theme.codeBlockEditorBackground.opacity(0.5))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.dividerColor.opacity(0.3), lineWidth: 1)
                    )

                    Text("This message is injected into the agent's working memory when tools fail repeatedly. The failure reason is automatically prepended.")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.tertiaryText)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Exhaustion Policy
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On Budget Exhausted")
                        .font(theme.fontBody.weight(.medium))
                    Text("When max iterations are reached without completion")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer(minLength: 16)

                Picker("", selection: Binding(
                    get: { effectiveRecovery.onIterationExhaustion },
                    set: {
                        var recovery = effectiveRecovery
                        recovery.onIterationExhaustion = $0
                        errorRecovery = recovery
                    }
                )) {
                    ForEach(ExhaustionPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

        }
    }
}
