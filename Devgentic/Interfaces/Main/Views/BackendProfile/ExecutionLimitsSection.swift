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
    /// Per-tier resilience cap overrides. `nil`/all-Auto = inherit the resolved
    /// defaults; transport-tier (HTTP retry/backoff) budgets are auto-derived from
    /// the provider and intentionally not exposed here.
    @Binding var resilienceOverrides: ResilienceOverrides?
    @Binding var errorRecovery: ErrorRecovery?
    @Environment(\.appTheme) private var theme

    /// The default each cap falls back to when left on Auto (matches
    /// `ResolvedResiliencePolicy.resolved`'s `RetryPolicy()` default).
    private let autoDefault = 3

    private var effectiveOverrides: ResilienceOverrides { resilienceOverrides ?? ResilienceOverrides() }
    private var effectiveRecovery: ErrorRecovery { errorRecovery ?? ErrorRecovery() }

    /// Mutates the overrides and collapses an all-Auto result back to `nil` so an
    /// untouched profile never persists an empty overrides object.
    private func updateOverrides(_ mutate: (inout ResilienceOverrides) -> Void) {
        var updated = effectiveOverrides
        mutate(&updated)
        resilienceOverrides = updated.isEmpty ? nil : updated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Parse Failure Cap (cognitive tier) — was conflated with the tool and
            // repetitive caps under one "Max Retries" knob; now isolated.
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On Parse Failure")
                        .font(theme.fontBody.weight(.medium))
                    Text("Retries when the model returns unparseable output")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer(minLength: 16)

                Picker("", selection: Binding<Int?>(
                    get: { effectiveOverrides.maxParseFailures },
                    set: { newValue in updateOverrides { $0.maxParseFailures = newValue } }
                )) {
                    Text("Auto (\(autoDefault))").tag(Int?.none)
                    Text("1").tag(Int?.some(1))
                    Text("2").tag(Int?.some(2))
                    Text("3").tag(Int?.some(3))
                    Text("5").tag(Int?.some(5))
                }
                .labelsHidden()
                .fixedSize()
            }

            // Tool Failure Tolerance (loop tier) — how many consecutive tool failures
            // the circuit breaker tolerates before aborting. Distinct from the policy
            // below, which decides what to DO once tolerance is exhausted.
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tool Failure Tolerance")
                        .font(theme.fontBody.weight(.medium))
                    Text("Consecutive tool failures before the agent gives up")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer(minLength: 16)

                Picker("", selection: Binding<Int?>(
                    get: { effectiveOverrides.maxConsecutiveToolFailures },
                    set: { newValue in updateOverrides { $0.maxConsecutiveToolFailures = newValue } }
                )) {
                    Text("Auto (\(autoDefault))").tag(Int?.none)
                    Text("2").tag(Int?.some(2))
                    Text("3").tag(Int?.some(3))
                    Text("5").tag(Int?.some(5))
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
