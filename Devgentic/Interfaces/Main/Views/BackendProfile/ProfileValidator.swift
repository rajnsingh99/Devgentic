// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileValidator.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - Validation Constants

/// Limits used when validating a `BackendProfileSnapshot` before save.
/// Validation returns field-specific errors the UI can display.
enum ProfileValidationLimits {
    static let maxDisplayNameLength = 100
    static let maxInstructionsLength = 50_000  // ~50K chars ≈ fits most context windows
}

// MARK: - Validation Error

struct ProfileValidationError: Identifiable, Equatable {
    let id = UUID()
    let field: String
    let message: String

    // Why: A capability classification may label but never gate an action: it is a name-based heuristic users may override.
    /// Whether this finding may stop a save (`.blocking`) or merely describes a likely problem (`.advisory`).
    /// Defaults to `.blocking`; a new rule must opt in to being ignorable.
    let severity: Severity

    enum Severity: String, Sendable, Hashable {
        /// The profile genuinely cannot function — refuse the save.
        case blocking
        /// A heuristic warning about likely-degraded behaviour. Report it; never refuse on it.
        case advisory
    }

    init(field: String, message: String, severity: Severity = .blocking) {
        self.field = field
        self.message = message
        self.severity = severity
    }

    /// `severity` is excluded from equality, like `id`: two findings about the same field with the same message are one
    /// finding.
    static func == (lhs: ProfileValidationError, rhs: ProfileValidationError) -> Bool {
        lhs.field == rhs.field && lhs.message == rhs.message
    }
}

extension Array where Element == ProfileValidationError {
    /// The findings that may refuse a save. Callers that gate MUST use this, never `isEmpty`.
    var blocking: [ProfileValidationError] { filter { $0.severity == .blocking } }

    /// The findings that describe a likely problem without refusing anything.
    var advisories: [ProfileValidationError] { filter { $0.severity == .advisory } }
}

// MARK: - Validator

struct ProfileValidator {

    /// Validates a profile snapshot and returns all errors found; an empty array means it can be saved.
    /// - Parameter strict: enforces provider-readiness rules (model, API key, workflow nodes); pass false for initial
    /// creation.
    static func validate(_ profile: BackendProfileSnapshot, strict: Bool = false) -> [ProfileValidationError] {
        var errors: [ProfileValidationError] = []

        // Rule 1: Display name must not be empty
        let trimmedName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            errors.append(ProfileValidationError(
                field: "displayName",
                message: "Profile name is required."
            ))
        }

        // Rule 2: Display name length cap
        if trimmedName.count > ProfileValidationLimits.maxDisplayNameLength {
            errors.append(ProfileValidationError(
                field: "displayName",
                message: "Profile name must be \(ProfileValidationLimits.maxDisplayNameLength) characters or fewer."
            ))
        }

        // Type-specific validation (only in strict mode — provider details
        // are configured after creation, so they can't be required up-front)
        if strict {
            switch profile.details {
            case .bot(let config):
                errors.append(contentsOf: validateLLMConfig(config.llmConfig))
                errors.append(contentsOf: validateInstructions(config.instructions, requirePresence: true))
                errors.append(contentsOf: validateAdvancedConfiguration(config.llmConfig))

            case .agent(let config):
                errors.append(contentsOf: validateLLMConfig(config.llmConfig))
                errors.append(contentsOf: validateInstructions(config.instructions, requirePresence: true))
                errors.append(contentsOf: validateAdvancedConfiguration(config.llmConfig))
                errors.append(contentsOf: validateToolReferences(config))
                // Warn if a local model lacks tool capabilities; advisory, because the verdict can come from a name match alone.
                // Only providers whose capability is measured (Ollama, MLX) are listed; `.openAICompatible` is excluded on purpose.
                let localProviders: [ApiProvider] = [.ollama, .mlx]
                if localProviders.contains(config.llmConfig.apiProvider),
                   config.llmConfig.cognitiveProfile.capability == .none {
                    errors.append(ProfileValidationError(
                        field: "modelCapabilities",
                        message: "Selected model does not support tool calling. Agent features may not work correctly.",
                        severity: .advisory
                    ))
                }

            case .imageGen(let config):
                errors.append(contentsOf: validateLLMConfig(config.llmConfig))

            case .workflow:
                // No profile-level rule: an empty workflow canvas is reported by `WorkflowValidator` before a run.
                break

            case .code(let config):
                errors.append(contentsOf: validateLLMConfig(config.llmConfig))
                // Strict must be a superset of lenient: `.code` instructions are validated here as in the lenient arm.
                errors.append(contentsOf: validateInstructions(config.instructions))
            }
        } else {
            // Even in lenient mode, validate instructions length if present
            switch profile.details {
            case .bot(let config):
                errors.append(contentsOf: validateInstructions(config.instructions))
            case .agent(let config):
                errors.append(contentsOf: validateInstructions(config.instructions))
                errors.append(contentsOf: validateToolReferences(config))
            case .code(let config):
                errors.append(contentsOf: validateInstructions(config.instructions))
            case .imageGen, .workflow:
                break
            }
        }

        return errors
    }

    // MARK: - LLM Config Validation

    private static func validateLLMConfig(_ config: ProviderConfig) -> [ProfileValidationError] {
        var errors: [ProfileValidationError] = []

        // Rule 3: Model name must not be empty
        if config.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(ProfileValidationError(
                field: "modelName",
                message: "A model must be selected."
            ))
        }

        // Cloud providers require an API key. `.openAICompatible` is excluded (LM Studio, vLLM and llama.cpp usually need none);
        // it requires a base URL instead.
        let cloudProviders: [ApiProvider] = [.openAI, .anthropic, .google, .openRouter]
        if cloudProviders.contains(config.apiProvider) {
            if let key = config.apiKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Key present — OK
            } else {
                errors.append(ProfileValidationError(
                    field: "apiKey",
                    message: "\(config.apiProvider.rawValue) requires an API key."
                ))
            }
        }

        // Rule 4b: A custom OpenAI-compatible provider has no canonical endpoint,
        // so a base URL is mandatory (the key is optional).
        if config.apiProvider == .openAICompatible {
            let hasBaseURL = (config.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            if !hasBaseURL {
                errors.append(ProfileValidationError(
                    field: "baseURL",
                    message: "A base URL is required for an OpenAI-Compatible provider (e.g. http://localhost:1234/v1)."
                ))
            }
        }

        // Rule 5: Base URL must be a valid http(s) URL if provided
        if let baseURL = config.baseURL, !baseURL.isEmpty {
            if let parsed = URL(string: baseURL) {
                let scheme = parsed.scheme?.lowercased()
                if scheme != "http" && scheme != "https" {
                    errors.append(ProfileValidationError(
                        field: "baseURL",
                        message: "Base URL must use http:// or https:// scheme."
                    ))
                }
            } else {
                errors.append(ProfileValidationError(
                    field: "baseURL",
                    message: "Base URL is not a valid URL."
                ))
            }
        }

        // Plain HTTP to a non-local host is advisory, never blocking: local Ollama and LM Studio use http://localhost.
        // Advisories have no UI return path yet; `ProviderConfigSection` shows the user-facing inline warning.
        if let warning = EndpointTransportSecurity.warning(
            for: EndpointTransportSecurity.evaluate(baseURL: config.baseURL, apiKey: config.apiKey)
        ) {
            errors.append(ProfileValidationError(
                field: "baseURL",
                message: warning,
                severity: .advisory
            ))
        }

        return errors
    }

    // MARK: - Instructions Validation

    /// Validates instruction length, and absence when `requirePresence` is true. Blocking, unlike the capability finding:
    /// length is deterministic and actionable. `requirePresence` is passed only from the strict bot/agent arms;
    /// a profile being created has no instructions yet, and `.code` is configured elsewhere.
    private static func validateInstructions(
        _ instructions: String?,
        requirePresence: Bool = false
    ) -> [ProfileValidationError] {
        // The "instructions are required" rule lives here so every save path at least records it. Advisory, not blocking:
        // editors hard-block at Save; elsewhere the save-advisory banner surfaces it and out-of-band writes still succeed.
        if instructionsAreMissing(instructions) {
            guard requirePresence else { return [] }
            return [ProfileValidationError(
                field: "instructions",
                message: missingInstructionsMessage,
                severity: .advisory
            )]
        }

        if instructions!.count > ProfileValidationLimits.maxInstructionsLength {
            return [ProfileValidationError(
                field: "instructions",
                message: "Instructions exceed \(ProfileValidationLimits.maxInstructionsLength) character limit."
            )]
        }
        return []
    }

    /// Instructions that name a tool this agent cannot call (not enabled, renamed or removed).
    /// Advisory, never blocking (see `InstructionToolReferences`); agent profiles only, since Bots and Code profiles have
    /// no `config.tools` loadout.
    static func validateToolReferences(_ config: AgentConfig) -> [ProfileValidationError] {
        let enabled = Set(config.tools.filter(\.isEnabled).map(\.name))
        return InstructionToolReferences.check(instructions: config.instructions, enabledToolNames: enabled)
            .map { ProfileValidationError(field: "instructions", message: $0.message, severity: .advisory) }
    }

    // MARK: - Shared Rules (single definition, several consumers)

    /// The one definition of "this profile has no system instructions" (register A35).
    /// The agent and bot editors call this rather than re-deriving it, so the rule cannot drift.
    static func instructionsAreMissing(_ instructions: String?) -> Bool {
        (instructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The sentence both editors show inline. Shared so they cannot say different things about the
    /// same rule — they each carried their own copy of this string.
    static let missingInstructionsMessage = String(localized: "System instructions are required.")

    // MARK: - Advanced Configuration

    /// Cross-field checks inside the opaque `advancedConfiguration` blob, e.g. a Thinking Budget above Max Output Tokens.
    /// Advisory: the blob cannot be decoded with certainty for every provider, so a false positive must not refuse a save.
    static func validateAdvancedConfiguration(_ config: ProviderConfig) -> [ProfileValidationError] {
        guard config.apiProvider == .anthropic,
              let advanced = config.advancedConfiguration,
              case .bool(let thinkingOn)? = advanced["extendedThinking"], thinkingOn,
              case .number(let budget)? = advanced["thinkingBudgetTokens"],
              case .number(let maxTokens)? = advanced["maxTokens"]
        else { return [] }

        // The budget is drawn FROM the output allowance, so it must leave room for an answer.
        guard budget >= maxTokens else { return [] }

        return [ProfileValidationError(
            field: "thinkingBudgetTokens",
            message: "Thinking Budget (\(Int(budget))) must be lower than Max Output Tokens "
                   + "(\(Int(maxTokens))) — the budget is taken from that allowance, so the model "
                   + "would have nothing left to answer with. The provider rejects this request.",
            severity: .advisory
        )]
    }
}
