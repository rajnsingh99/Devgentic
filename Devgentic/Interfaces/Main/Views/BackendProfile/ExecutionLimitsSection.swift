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
        VStack(alignment: .leading, spacing: 12) {

            // Max Iterations
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Max Iterations")
                        .fontWeight(.medium)
                    Text("Maximum reasoning cycles before forced termination")
                        .font(.caption)
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

            Divider()

            // Execution Timeout
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Execution Timeout")
                        .fontWeight(.medium)
                    Text("Maximum wall-clock time for a single execution")
                        .font(.caption)
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
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else {
                    HStack(spacing: 8) {
                        Text("No limit")
                            .font(.callout)
                            .foregroundColor(theme.secondaryText)

                        Button("Set") {
                            executionTimeout = 120
                        }
                        .font(.caption)
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
        VStack(alignment: .leading, spacing: 12) {

            // Parse Failure Retries
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On Parse Failure")
                        .fontWeight(.medium)
                    Text("When the model returns unparseable output")
                        .font(.caption)
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

            Divider()

            // Backoff Strategy
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Backoff Strategy")
                        .fontWeight(.medium)
                    Text("Delay pattern between retries")
                        .font(.caption)
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

            Divider()

            // Tool Failure Policy
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On Tool Failure")
                        .fontWeight(.medium)
                    Text("When a tool execution fails repeatedly")
                        .font(.caption)
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

            Divider()

            // Exhaustion Policy
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On Budget Exhausted")
                        .fontWeight(.medium)
                    Text("When max iterations are reached without completion")
                        .font(.caption)
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

            // Info note
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                Text("These settings apply when this agent runs standalone or as a workflow node.")
                    .font(.caption2)
            }
            .foregroundColor(theme.secondaryText)
            .padding(.top, 4)
        }
    }
}
