//
//  OllamaContextWindowPolicy.swift
//  Devgentic
//
//  Created on 12/07/26.
//
//  Single source of truth for the context window Ollama requests actually run
//  under. Ollama allocates `num_ctx` tokens of KV cache per request — NOT the
//  model's trained maximum. When no num_ctx is sent (and none is baked into the
//  Modelfile), the server default (~4K) applies, and oversized prompts are
//  silently HEAD-truncated — system prompt first — with no client-visible
//  signal. Used by BOTH the request factory (what we send) and the retrieval
//  budget (what we assume), so the two can never disagree.
//

import Foundation

/// Resolves the context window a request will EFFECTIVELY run under, per
/// provider class — the ONE resolver behind the retrieval budget, the pre-flight
/// fit check, and AgentConnect's memory/compaction + native-turn budgets, so
/// they can never disagree about how much room a model actually has.
/// (Before this, compaction budgets assumed 128K for ANY model missing metadata —
/// including local ones whose real allocation was Ollama's ~4K default, so
/// native turn arrays never compacted and Ollama silently truncated mid-run.)
enum EffectiveContextWindow {

    /// The model's TRAINED maximum, when known (scan metadata, else catalog).
    static func trainedWindow(for config: ProviderConfig?) -> Int? {
        config?.modelMetadata?.contextWindow
            ?? KnownModelContextWindows.lookup(config?.modelName ?? "")
    }

    /// The window requests actually get: Ollama → num_ctx policy (configured →
    /// auto-default → server default); MLX → trained max (the app owns the
    /// prompt), conservative 8K when unknown; cloud → trained/catalog, 128K
    /// when unknown (overflow errors loudly there anyway).
    static func resolve(for config: ProviderConfig?) -> Int {
        let trained = trainedWindow(for: config)
        switch config?.apiProvider {
        case .ollama:
            return OllamaContextWindowPolicy.effectiveTokens(
                configuredNumCtx: OllamaContextWindowPolicy.configuredNumCtx(in: config?.advancedConfiguration),
                trainedContextWindow: trained
            )
        case .mlx:
            return max(2_048, trained ?? 8_192)
        default:
            return max(2_048, trained ?? 128_000)
        }
    }
}

enum OllamaContextWindowPolicy {

    /// Ceiling for the auto-default. KV cache costs real memory (roughly another
    /// 0.5–1 GB for a 7B model at 8K), so we don't blindly allocate a
    /// 128K-trained model's maximum; users can exceed this deliberately via the
    /// profile's Advanced settings.
    static let autoDefaultCap = 16_384

    /// What Ollama allocates when no num_ctx reaches it: 2,048 on older servers,
    /// 4,096 on current ones, overridable server-side by OLLAMA_CONTEXT_LENGTH —
    /// and none of it queryable via the API. Assume the current default.
    static let assumedServerDefault = 4_096

    /// The user's explicit numCtx from a profile's advanced configuration
    /// (the Advanced card in Bot/Agent config → `advancedConfiguration["numCtx"]`).
    static func configuredNumCtx(in options: [String: JSONValue]?) -> Int? {
        guard let value = options?["numCtx"] else { return nil }
        if case .number(let double) = value, double > 0 { return Int(double) }
        return nil
    }

    /// The num_ctx to auto-send when the user configured none: the model's
    /// trained maximum, memory-capped. Nil when the trained size is unknown —
    /// then we send nothing rather than guess above the server default.
    static func autoNumCtx(trainedContextWindow: Int?) -> Int? {
        guard let trained = trainedContextWindow, trained > 0 else { return nil }
        return min(trained, autoDefaultCap)
    }

    /// The window the rest of the app should assume a request runs under —
    /// mirrors exactly what the request factory resolves and sends:
    /// user-configured value → auto-default → assumed server default.
    static func effectiveTokens(configuredNumCtx: Int?, trainedContextWindow: Int?) -> Int {
        if let configured = configuredNumCtx { return configured }
        if let auto = autoNumCtx(trainedContextWindow: trainedContextWindow) { return auto }
        return assumedServerDefault
    }
}
