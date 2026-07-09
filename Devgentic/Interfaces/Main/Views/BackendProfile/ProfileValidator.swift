//
//  ProfileValidator.swift
//  Devgentic
//
//  Created on 26/03/26.
//
//  Validates BackendProfileSnapshot before save.
//  Returns a list of field-specific errors that the UI can display.
//

import Foundation

// MARK: - Validation Constants

enum ProfileValidationLimits {
    static let maxDisplayNameLength = 100
    static let maxInstructionsLength = 50_000  // ~50K chars ≈ fits most context windows
}

// MARK: - Validation Error

struct ProfileValidationError: Identifiable, Equatable {
    let id = UUID()
    let field: String
    let message: String

    static func == (lhs: ProfileValidationError, rhs: ProfileValidationError) -> Bool {
        lhs.field == rhs.field && lhs.message == rhs.message
    }
}

// MARK: - Validator

struct ProfileValidator {

    /// Validates a profile snapshot and returns all errors found.
    /// An empty array means the profile is valid and can be saved.
    ///
    /// - Parameter strict: When `true`, enforces provider-readiness rules (model selected,
    ///   API key present, workflow has nodes). Pass `false` for initial profile creation
    ///   where the user hasn't configured provider details yet.
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
                errors.append(contentsOf: validateInstructions(config.instructions))

            case .agent(let config):
                errors.append(contentsOf: validateLLMConfig(config.llmConfig))
                errors.append(contentsOf: validateInstructions(config.instructions))
                // Warn if local model lacks tool capabilities (cloud providers always support tools)
                let localProviders: [ApiProvider] = [.ollama, .mlx]
                if localProviders.contains(config.llmConfig.apiProvider),
                   config.llmConfig.cognitiveProfile.capability == .none {
                    errors.append(ProfileValidationError(
                        field: "modelCapabilities",
                        message: "Selected model does not support tool calling. Agent features may not work correctly."
                    ))
                }

            case .imageGen(let config):
                errors.append(contentsOf: validateLLMConfig(config.llmConfig))

            case .workflow(let config):
                if config.agentProfileIDs.isEmpty {
                    errors.append(ProfileValidationError(
                        field: "workflow",
                        message: "Workflow must reference at least one agent profile."
                    ))
                }

            case .code(let config):
                errors.append(contentsOf: validateLLMConfig(config.llmConfig))
            }
        } else {
            // Even in lenient mode, validate instructions length if present
            switch profile.details {
            case .bot(let config):
                errors.append(contentsOf: validateInstructions(config.instructions))
            case .agent(let config):
                errors.append(contentsOf: validateInstructions(config.instructions))
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

        // Rule 4: Cloud providers require an API key.
        // NOTE: `.openAICompatible` is intentionally excluded — LM Studio, vLLM,
        // and llama.cpp servers typically need no key. It instead requires a base
        // URL (Rule 4b).
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

        return errors
    }

    // MARK: - Instructions Validation

    private static func validateInstructions(_ instructions: String?) -> [ProfileValidationError] {
        guard let instructions = instructions, !instructions.isEmpty else { return [] }

        if instructions.count > ProfileValidationLimits.maxInstructionsLength {
            return [ProfileValidationError(
                field: "instructions",
                message: "Instructions exceed \(ProfileValidationLimits.maxInstructionsLength) character limit."
            )]
        }
        return []
    }
}
