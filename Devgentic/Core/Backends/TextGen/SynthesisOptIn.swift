//
//  SynthesisOptIn.swift
//  Devgentic
//
//  Resolves whether IC-powered response synthesis runs for a given agent run.
//
//  Design (decided 2026-07-19): synthesis is STRICTLY OPT-IN, per provider family.
//  It is never triggered automatically — not by tool failures, not by a circuit-
//  breaker abort. Rationale:
//
//    • The IC model is small (≈3B) and its system prompt caps simple answers at
//      three sentences. Handing it a finished answer from a larger model is a
//      lossy rewrite: an on-device run produced a complete 7-row markdown table
//      that one dead tool call turned into 3 rows, because the failure forced
//      synthesis and punched through the native fast-path.
//    • Failure communication no longer needs a narrator. The amber
//      `completedWithWarnings` chip, the failed tool row with its category,
//      `terminalReason`, and preserved partial prose all carry that job.
//    • Raw output quality is the user's call, because the model is the user's
//      choice — the same philosophy as the fail-open model picker.
//
//  A cleanup pass genuinely helps a small local model and is pure downside behind
//  a large cloud model, so the opt-in is per family rather than global.
//
//  The deterministic template floor is unaffected: "raw output" only exists when
//  the model produced output. Runs that end with nothing usable still fall back to
//  `ResponseSynthesizer.buildDeterministicFallback` (no LLM, no IC).
//

import Foundation

private let logger = DGLogger(category: "SynthesisOptIn")

enum SynthesisOptIn {

    // MARK: - Provider Family

    /// The three opt-in buckets surfaced in Core Intelligence settings. Coarser
    /// than `ApiProvider` because the decision is about model class, not vendor:
    /// every remote API is "a big model behind an HTTP call".
    enum ProviderFamily: String, Sendable, CaseIterable {
        case mlx
        case ollama
        case remote

        /// Exhaustive by construction — deliberately no `default`, so adding a
        /// provider to `ApiProvider` is a compile error here rather than a silent
        /// landing in `.remote`.
        init(apiProvider: ApiProvider) {
            switch apiProvider {
            case .mlx:    self = .mlx
            case .ollama: self = .ollama
            case .openAI, .anthropic, .google, .openRouter, .openAICompatible:
                self = .remote
            }
        }

        var defaultsKey: String {
            switch self {
            case .mlx:    return AppSettings.ciFeatureResponseSynthesisMLXKey
            case .ollama: return AppSettings.ciFeatureResponseSynthesisOllamaKey
            case .remote: return AppSettings.ciFeatureResponseSynthesisRemoteKey
            }
        }
    }

    // MARK: - Decision

    /// The resolved verdict plus why — so the call site can log a single line that
    /// fully explains the run's synthesis routing without a second lookup.
    struct Decision: Sendable, Equatable {
        let optedIn: Bool
        let family: ProviderFamily
        /// Short, log-safe explanation of what decided it.
        let reason: String
    }

    /// Resolves synthesis opt-in for one run.
    ///
    /// All three conditions must hold: Core Intelligence enabled, an IC model
    /// actually selected, and the checkbox for THIS run's provider family on.
    ///
    /// - Parameters:
    ///   - provider: The provider the run's LLM config resolved to.
    ///   - icModelSelected: Whether `IntelligenceCoreService` has a model selected.
    ///   - icEnabled: The Core Intelligence master toggle.
    ///   - defaults: Injected for testability.
    static func resolved(
        provider: ApiProvider,
        icModelSelected: Bool,
        icEnabled: Bool,
        defaults: UserDefaults = .standard
    ) -> Decision {
        let family = ProviderFamily(apiProvider: provider)

        guard icEnabled else {
            return Decision(optedIn: false, family: family, reason: "core-intelligence-disabled")
        }
        guard icModelSelected else {
            return Decision(optedIn: false, family: family, reason: "no-ic-model-selected")
        }
        guard defaults.bool(forKey: family.defaultsKey) else {
            return Decision(optedIn: false, family: family, reason: "family-not-opted-in")
        }
        return Decision(optedIn: true, family: family, reason: "opted-in")
    }

    // MARK: - Migration

    /// One-time seeding of the per-family toggles from the legacy single toggle,
    /// so a previously-opted-in user keeps synthesis everywhere. Idempotent —
    /// guarded by `ciSynthPerProviderMigratedKey`.
    ///
    /// Reads the legacy key EXPLICITLY (`object(forKey:) as? Bool`) rather than
    /// `bool(forKey:)`, and seeds only on an explicit `true`. This is deliberate:
    /// the settings UI declared `@AppStorage(...) = true` while the engine read
    /// `UserDefaults.bool(forKey:)` (false when absent), so an install where the
    /// switch was never touched DISPLAYED "on" but never actually synthesized.
    /// Seeding from the engine's real behavior keeps every user's experience
    /// unchanged across the upgrade; seeding from the UI's claim would silently
    /// switch synthesis ON for everyone who never opted in.
    ///
    /// - Returns: true if seeding ran on this call (false if already migrated).
    @discardableResult
    static func migrateLegacyToggleIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: AppSettings.ciSynthPerProviderMigratedKey) else {
            return false
        }

        let legacyOptedIn = (defaults.object(forKey: AppSettings.ciFeatureResponseSynthesisKey) as? Bool) == true
        for family in ProviderFamily.allCases {
            defaults.set(legacyOptedIn, forKey: family.defaultsKey)
        }
        defaults.set(true, forKey: AppSettings.ciSynthPerProviderMigratedKey)

        logger.info("[SYNTH] Migrated legacy Response Synthesis toggle → per-family opt-in. legacy-explicit-true: \(legacyOptedIn) → MLX/Ollama/Remote all set to \(legacyOptedIn).")
        return true
    }
}
