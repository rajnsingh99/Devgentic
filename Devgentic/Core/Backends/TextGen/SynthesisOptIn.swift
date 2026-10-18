// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SynthesisOptIn.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "SynthesisOptIn")

/// Resolves whether IC-powered response synthesis runs for an agent run: strictly opt-in, per provider
/// family. Never triggered automatically, because rewriting a larger model's finished answer through
/// the small IC model is lossy.
enum SynthesisOptIn {

    // MARK: - Provider Family

    /// The three opt-in buckets surfaced in Core Intelligence settings. Coarser
    /// than `ApiProvider` because the decision is about model class, not vendor:
    /// every remote API is "a big model behind an HTTP call".
    enum ProviderFamily: String, Sendable, CaseIterable {
        case mlx
        case ollama
        case remote

        /// Exhaustive by construction, with no `default`: adding a provider to `ApiProvider` is a compile error
        /// here.
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

    /// Resolves synthesis opt-in for one run: Core Intelligence enabled, an IC model selected, and this
    /// provider family's checkbox on. `defaults` is injected for testability.
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
}
