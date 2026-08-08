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

    /// Whether this finding may STOP a save, or merely describes a likely problem.
    ///
    /// ⚠️ This distinction exists because it was missing, and its absence was a live defect (G92).
    /// Every finding used to land in one flat array that both callers treated as fatal, so an
    /// explicitly advisory sentence — "Agent features **may not** work correctly" — silently
    /// acquired the force of "A model must be selected." The wording said warning; the placement
    /// said error. A user could create a local agent profile and then never save an edit to it,
    /// not even a rename, with an error toast whose text does not even claim the save failed.
    ///
    /// It also violated the project rule that a capability classification may LABEL or GROUP but
    /// must never GATE an action — the classification here is a name-based heuristic that the
    /// model picker itself calls "often wrong" while inviting the user to override it.
    ///
    /// Defaults to `.blocking` so every existing construction site keeps its current force, and a
    /// new rule has to opt IN to being ignorable rather than opting out of being fatal.
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

    /// ⚠️ `severity` is deliberately EXCLUDED from equality, matching the existing exclusion of
    /// `id`: two findings about the same field with the same message are the same finding. Nothing
    /// in the app compares severities, and including it would make a rule's reclassification look
    /// like a different error to any future diffing consumer.
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
                errors.append(contentsOf: validateInstructions(config.instructions, requirePresence: true))
                errors.append(contentsOf: validateAdvancedConfiguration(config.llmConfig))

            case .agent(let config):
                errors.append(contentsOf: validateLLMConfig(config.llmConfig))
                errors.append(contentsOf: validateInstructions(config.instructions, requirePresence: true))
                errors.append(contentsOf: validateAdvancedConfiguration(config.llmConfig))
                // Warn if local model lacks tool capabilities (cloud providers always support tools).
                //
                // ⚠️ ADVISORY, and it must stay advisory. `cognitiveCapability` is a detection
                // verdict, and for MLX it can come from a Tier-0 match on the model NAME alone
                // (deepseek-r1, qwq, gpt-oss, magistral) ahead of any tokenizer evidence. The MLX
                // picker says so to the user's face — "often wrong for new or re-quantized models —
                // if you know it supports tools, keep it selected" — so blocking the save on it
                // makes that invitation unhonourable. It also strands the user with no escape when
                // no tool-capable local model is installed: the picker deliberately lets the
                // selection stand, and the save then refuses it.
                //
                // The describing still happens, in the places that can act on it: the MLX picker's
                // alert, the Ollama picker's "no tool-capable models installed" notice, and the
                // Inference Capability badge. This finding adds the record; it does not add a gate.
                // ⚠️ `.openAICompatible` is EXCLUDED ON PURPOSE, not by oversight (register G96,
                // where this was filed as a gap and is refuted here). The list is not "local
                // providers" — it is "providers whose capability is actually MEASURED". Only the
                // Ollama (`/api/show`) and MLX (`MLXTokenizerAnalyzer`) paths run an analyzer;
                // `.openAICompatible` has no picker to run one from (it is a free-text endpoint
                // field), is seeded `.parallelActions` by `ProfileCapabilityFilter`, and is routed
                // through `AgentConnect`'s cloud arm, which consults no capability at all.
                //
                // Adding it here would emit "does not support tool calling" from a value nothing
                // ever measured — a confident claim about a user's private LM Studio or vLLM
                // endpoint, derived from a default. A note that cannot be wrong in the user's favour
                // is worse than no note.
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

            case .workflow(let config):
                if config.agentProfileIDs.isEmpty {
                    errors.append(ProfileValidationError(
                        field: "workflow",
                        message: "Workflow must reference at least one agent profile."
                    ))
                }

            case .code(let config):
                errors.append(contentsOf: validateLLMConfig(config.llmConfig))
                // ⚠️ This line was MISSING while the lenient arm below had it (register G96), so
                // `.code` validated its instructions the wrong way round relative to every other
                // profile type: an over-long system prompt blocked CREATION and then passed every
                // UPDATE. Strict must be a superset of lenient, never a different set.
                errors.append(contentsOf: validateInstructions(config.instructions))
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

        // Rule 5b: plain HTTP to a host that is not this machine (register A52).
        //
        // ⚠️ `.advisory`, never blocking. `http://localhost:11434` is how Ollama works and
        // `http://127.0.0.1:1234/v1` is how LM Studio works — refusing here would break the app's
        // own default local setup. A self-hosted gateway on a trusted LAN is also a legitimate
        // choice. This describes the risk; it does not gate the save.
        //
        // ⚠️ Advisories currently have no return path to any UI (register A34, still open), so this
        // rule alone would be invisible. The user-facing half is an inline warning under the API
        // Endpoint field in `ProviderConfigSection` — the rule is here so the finding is recorded
        // centrally and picked up for free when A34 lands.
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

    /// ⚠️ Deliberately BLOCKING, unlike the capability finding above — the distinction is worth
    /// stating because both are "limits" and only one is a heuristic about a third party.
    ///
    /// This one is deterministic (count the characters), visible before it is hit (the editors show
    /// a live counter that turns orange at 90% and red past the limit), and actionable by the person
    /// who caused it (delete some text). A capability verdict is none of those: it is a guess about
    /// someone else's model that the user can neither verify nor change. Blocking on the first is a
    /// product cap; blocking on the second was the G92 defect.
    /// - Parameter requirePresence: whether MISSING instructions is itself a finding (register
    ///   A35). ⚠️ False by default and passed `true` only from the strict bot/agent arms. The
    ///   lenient arm exists to check LENGTH at creation time, and a profile being created has not
    ///   been given instructions yet — reporting their absence there would fire on every single new
    ///   profile, which is neither true nor useful. `.code` is excluded for the same reason: code
    ///   sessions are configured from the Code interface, not this editor.
    private static func validateInstructions(
        _ instructions: String?,
        requirePresence: Bool = false
    ) -> [ProfileValidationError] {
        // ⚠️ Register A35. The "instructions are required" rule lived in TWO views and nowhere else,
        // so every non-editor save path — creation from the + button, the capability chips, the
        // Tool Library, `CodeSessionManager`, the thinking auto-heal, the quit-time save (A29) —
        // wrote a profile with no instructions and nothing ever noticed. Defined here now: one rule,
        // and every path at least RECORDS it.
        //
        // ⚠️ **Advisory, not blocking**, and the distinction is load-bearing. Making it blocking at
        // the store would refuse every out-of-band write to such a profile — including
        // `BackendOrchestrationService.disableThinkingOnProfile`, whose whole job is to stop a
        // recurring provider 400. An agent created from + and not yet configured is exactly the
        // profile this finding is about, so those saves are not hypothetical. The editors keep their
        // hard block at Save, where the user is present and can act; everywhere else it is recorded
        // and surfaced by the save-advisory banner (register A34).
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

    /// Cross-field checks inside the opaque `advancedConfiguration` blob.
    ///
    /// ⚠️ Register A36. `ProfileValidator` never inspected `advancedConfiguration` AT ALL, so a
    /// Thinking Budget of 64000 against a Max Output Tokens of 2048 saved cleanly — the panel's own
    /// caption states the constraint and nothing enforced it. Anthropic rejects that request, so the
    /// profile was saveable and unusable.
    ///
    /// ⚠️ Advisory rather than blocking: the two fields live in a blob this validator cannot decode
    /// with certainty for every provider, and a false positive here would refuse a legitimate save.
    /// It also cannot be reached by the out-of-band writers' fault — they do not touch these fields.
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
