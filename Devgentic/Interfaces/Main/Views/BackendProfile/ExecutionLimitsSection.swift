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
                    "\(maxIterations ?? AgentExecutionDefaults.maxIterations)",
                    value: Binding(
                        get: { maxIterations ?? AgentExecutionDefaults.maxIterations },
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

                        GlassActionButton(title: "Remove", icon: "xmark", isAccent: false) {
                            executionTimeout = nil
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Text("No limit")
                            .font(theme.fontCallout)
                            .foregroundColor(theme.secondaryText)

                        GlassActionButton(title: "Set", icon: "clock") {
                            executionTimeout = 120
                        }
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
    /// The profile's legacy single retry knob. ⚠️ Register A70: `Auto` does NOT mean 3 — it means
    /// this. Passed in rather than assumed so the label cannot drift from the resolver.
    var legacyRetryPolicy: RetryPolicy?
    @Environment(\.appTheme) private var theme

    /// What each cap actually falls back to when left on Auto — read from the same source
    /// `ResolvedResiliencePolicy.resolved` reads, never restated as a literal.
    private var autoDefault: Int {
        ResolvedResiliencePolicy.autoDefault(legacy: legacyRetryPolicy)
    }

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
                    Text("Gives up after this many tool failures in a row")
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
                            GlassActionButton(title: "Reset to Default", icon: "arrow.counterclockwise", isAccent: false) {
                                var recovery = effectiveRecovery
                                recovery.fallbackMessage = nil
                                errorRecovery = recovery
                            }
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

/// Loop Safety — circuit-breaker caps. These live on the AGENT profile, so they apply both in
/// chat and when a workflow node executes this agent (same AgentConnect resolution seam). If the
/// agent stops early but has a usable answer, the run completes with warnings instead of failing
/// (degraded success). Rendered as its own titled group in AgentConfigDetailView, sibling to
/// "Error Recovery".
struct LoopSafetySection: View {
    @Binding var resilienceOverrides: ResilienceOverrides?
    /// See `ErrorRecoverySection.legacyRetryPolicy` — the repetition cap falls back to this (A70).
    var legacyRetryPolicy: RetryPolicy?
    @Environment(\.appTheme) private var theme

    /// The repetition cap's real Auto value. The denial cap has its own fixed default below.
    private var autoDefault: Int {
        ResolvedResiliencePolicy.autoDefault(legacy: legacyRetryPolicy)
    }

    private var effectiveOverrides: ResilienceOverrides { resilienceOverrides ?? ResilienceOverrides() }

    /// Mutates the overrides and collapses an all-Auto result back to `nil` so an
    /// untouched profile never persists an empty overrides object.
    private func updateOverrides(_ mutate: (inout ResilienceOverrides) -> Void) {
        var updated = effectiveOverrides
        mutate(&updated)
        resilienceOverrides = updated.isEmpty ? nil : updated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Repetition Tolerance (loop tier) — ONE knob for both repetition checks:
            // identical-iteration fingerprints AND per-tool global repeats. The model is
            // warned one identical call before the cap fires.
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Repetition Tolerance")
                        .font(theme.fontBody.weight(.medium))
                    Text("Stops the run when a tool returns the same result this many times — the model is warned one call early")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer(minLength: 16)

                Picker("", selection: Binding<Int?>(
                    get: { effectiveOverrides.maxRepetitiveActions },
                    set: { newValue in updateOverrides { $0.maxRepetitiveActions = newValue } }
                )) {
                    Text("Auto (\(autoDefault))").tag(Int?.none)
                    Text("2").tag(Int?.some(2))
                    Text("3").tag(Int?.some(3))
                    Text("5").tag(Int?.some(5))
                }
                .labelsHidden()
                .fixedSize()
            }

            // Denial Limit — consecutive user-denied tool calls before the run stops
            // (tighter than general failures: the user already rejected the action).
            // Identical declined requests are auto-denied without a banner (RunInteractionMemory);
            // identical repeated questions replay the earlier answer — so no clarification knob.
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Denial Limit")
                        .font(theme.fontBody.weight(.medium))
                    Text("Stops the run after this many denials in a row — repeats of a declined request are auto-denied")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer(minLength: 16)

                Picker("", selection: Binding<Int?>(
                    get: { effectiveOverrides.maxConsecutiveDenials },
                    set: { newValue in updateOverrides { $0.maxConsecutiveDenials = newValue } }
                )) {
                    Text("Auto (\(ResolvedResiliencePolicy.defaultMaxConsecutiveDenials))").tag(Int?.none)
                    Text("1").tag(Int?.some(1))
                    Text("2").tag(Int?.some(2))
                    Text("3").tag(Int?.some(3))
                }
                .labelsHidden()
                .fixedSize()
            }

        }
    }
}
