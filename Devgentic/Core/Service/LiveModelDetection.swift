// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LiveModelDetection.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "LiveModelDetection")

/// Detects the capability of a local model (Ollama, MLX) when a run starts instead of trusting the stored profile.
/// Stored values remain the fallback for a model this lookup cannot find, and what display surfaces show.
/// Measurements only: user-controlled preferences such as Extended Thinking are never touched.
@MainActor
enum LiveModelDetection {

    /// How long after a failed Ollama model-list load the next run waits before asking again, so an
    /// offline Ollama does not cost every send a round trip.
    static let ollamaReloadInterval: TimeInterval = 60
    private static var lastOllamaLoadAttempt: Date?

    // MARK: - Runs

    /// `profile` with its LLM config's measurements replaced by what detection reports for its
    /// model right now. Unchanged for cloud providers, profiles with no LLM config, and models the
    /// lookup cannot find.
    static func resolving(_ profile: BackendProfileModel) async -> BackendProfileModel {
        guard let stored = profile.details.llmProviderConfig, !stored.apiProvider.usesCloudDefaults else {
            return profile
        }
        // Never in the test host: loading would read the developer's real Ollama server and MLX folder.
        // The Ollama cache holds one server's models; a profile on another server must not resolve against them.
        if stored.apiProvider == .ollama, !ollamaCacheServes(stored) {
            logger.notice("[MODEL_DETECT] Profile '\(profile.displayName)': its Ollama server \(InferenceEngine.normalizedOllamaURL(stored.baseURL)) is not the one live detection reads (\(InferenceEngine.normalizedOllamaURL(OllamaService.shared.ollamaBaseURL))). CONSEQUENCE: this run uses the values stored on the profile rather than another server's model data.")
            return profile
        }
        if !TestHost.isRunning {
            if stored.apiProvider == .ollama { await loadOllamaModelsIfNeeded() }
            if stored.apiProvider == .mlx { await MLXModelService.shared.ensureLoaded() }
        }
        guard let detected = detectedFromCache(stored) else {
            logger.notice("[MODEL_DETECT] Profile '\(profile.displayName)': no live detection for \(stored.apiProvider.rawValue) model '\(stored.modelName)'. CONSEQUENCE: this run uses the values stored on the profile (capability \(stored.cognitiveCapability.rawValue)); they may be stale if the model changed since it was picked.")
            return profile
        }
        // Names every field that differs, so stale metadata is not reported as two identical values.
        let differences = differingMeasurements(stored: stored, detected: detected)
        if !differences.isEmpty {
            logger.notice("[MODEL_DETECT] Profile '\(profile.displayName)' (\(profile.id.uuidString.prefix(8))), model '\(stored.modelName)': stored copy differs from detection — \(differences.joined(separator: "; ")). CONSEQUENCE: this run uses the DETECTED values; the stored copy is refreshed when the model is next picked from the catalog and the profile saved.")
        }
        var resolved = profile
        resolved.details = profile.details.settingLLMProviderConfig(detected)
        return resolved
    }

    /// Each measured field whose stored value differs from detection, as "field stored → detected".
    nonisolated static func differingMeasurements(stored: ProviderConfig, detected: ProviderConfig) -> [String] {
        func meta(_ m: ModelMetadata?) -> String {
            guard let m else { return "none" }
            return "\(m.tier.rawValue) tier, \(m.quantization ?? "no quant"), \(m.parameterCount ?? "no param count"), window \(m.contextWindow.map(String.init) ?? "unknown")"
        }
        var out: [String] = []
        func note<T: Equatable>(_ name: String, _ a: T, _ b: T, _ text: (T) -> String) {
            if a != b { out.append("\(name) \(text(a)) → \(text(b))") }
        }
        note("capability", stored.cognitiveCapability, detected.cognitiveCapability) { $0.rawValue }
        note("dialect", stored.modelDialect, detected.modelDialect) { $0.rawValue }
        note("metadata", stored.modelMetadata, detected.modelMetadata, meta)
        note("modalities", stored.supportedModalities, detected.supportedModalities) { "\($0)" }
        note("template", stored.chatTemplateSource, detected.chatTemplateSource) { $0.description }
        note("stop sequences", stored.stopSequences, detected.stopSequences) { "\($0.count)" }
        return out
    }

    // MARK: - Synchronous, cache-only

    /// `config` with detected measurements applied, from caches already in memory — no network,
    /// no disk scan. Nil when the provider is not a local one or the model is not in the cache.
    static func detectedFromCache(_ config: ProviderConfig) -> ProviderConfig? {
        var out = config
        switch config.apiProvider {
        case .ollama:
            guard ollamaCacheServes(config), let model = ollamaModel(named: config.modelName) else { return nil }
            out.cognitiveCapability = model.cognitiveCapability
            out.modelDialect = model.modelDialect
            if let metadata = model.cognitiveProfile.metadata { out.modelMetadata = metadata }
            out.supportedModalities = model.cognitiveProfile.modalities
        case .mlx:
            guard let item = MLXModelService.shared.installedModel(named: config.modelName) else { return nil }
            let profile = MLXModelService.shared.cachedCognitiveProfile(for: item)
            out.cognitiveCapability = profile.capability
            out.modelDialect = profile.dialect
            if let metadata = profile.metadata { out.modelMetadata = metadata }
            out.chatTemplateSource = profile.chatTemplateSource
            out.stopSequences = profile.stopSequences
            out.supportedModalities = profile.modalities
        case .openAI, .anthropic, .google, .openRouter, .openAICompatible:
            return nil
        }
        return out
    }

    // MARK: - Ollama

    /// Ollama names a model `name:tag`, and an untagged name means `:latest`.
    private static func ollamaModel(named name: String) -> LocalModel? {
        let models = OllamaService.shared.localModels
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let exact = models.first(where: { $0.name == trimmed }) { return exact }
        let withTag = trimmed.contains(":") ? trimmed : trimmed + ":latest"
        return models.first(where: { $0.name == withTag })
    }

    /// Whether the in-memory Ollama model list belongs to the server `config` talks to.
    static func ollamaCacheServes(_ config: ProviderConfig) -> Bool {
        InferenceEngine.normalizedOllamaURL(config.baseURL)
            == InferenceEngine.normalizedOllamaURL(OllamaService.shared.ollamaBaseURL)
    }

    enum OllamaLoadAction: Equatable {
        /// The list is loaded, or the throttle says not yet.
        case none
        /// The server has never been probed (or was down): probe it, and load the list if it answers.
        case probeAndLoad
        /// The server is known to be up; load the list.
        case loadOnly
    }

    /// What a run should do to get the Ollama model list: nothing, probe the server then load, or just load.
    /// Probes first when the server is not known to be connected; `loadLocalModels()` returns at once unless connected.
    /// Returns `.none` when the list is loaded or the reload throttle has not elapsed.
    nonisolated static func ollamaLoadAction(serverConnected: Bool, hasModels: Bool,
                                             lastAttempt: Date?, now: Date) -> OllamaLoadAction {
        guard !hasModels else { return .none }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < ollamaReloadInterval { return .none }
        return serverConnected ? .loadOnly : .probeAndLoad
    }

    /// Loads the Ollama model list when it has never been loaded this run (nothing has opened a
    /// picker yet), throttled so an offline server is asked at most once a minute.
    private static func loadOllamaModelsIfNeeded() async {
        let service = OllamaService.shared
        let action = ollamaLoadAction(serverConnected: service.serverStatus == .connected,
                                      hasModels: !service.localModels.isEmpty,
                                      lastAttempt: lastOllamaLoadAttempt, now: Date())
        guard action != .none else { return }
        lastOllamaLoadAttempt = Date()
        switch action {
        case .probeAndLoad: await service.checkServerStatusAndUpdateModels()
        case .loadOnly: await service.loadLocalModels()
        case .none: break
        }
        if service.localModels.isEmpty {
            logger.notice("[MODEL_DETECT] Ollama model list still empty after \(action == .probeAndLoad ? "probing" : "loading") \(service.ollamaBaseURL) (status \(String(describing: service.serverStatus))). CONSEQUENCE: runs use stored model values; retried in \(Int(ollamaReloadInterval)) s.")
        }
    }

    /// Test seam: forget the throttle.
    static func resetForTesting() {
        lastOllamaLoadAttempt = nil
    }
}

// MARK: - Comparing profiles without detection results

extension BackendProfileSnapshot {
    /// A copy with every DETECTED measurement reset to its default — capability, dialect, metadata,
    /// modalities, template source and stop sequences — so two snapshots that differ only by a
    /// detection refresh compare equal. User preferences (Extended Thinking) are kept.
    func ignoringDetectedMeasurements() -> BackendProfileSnapshot {
        guard var config = details.llmProviderConfig else { return self }
        let defaults = ProviderConfig(apiProvider: config.apiProvider, modelName: config.modelName)
        config.cognitiveCapability = defaults.cognitiveCapability
        config.modelDialect = defaults.modelDialect
        config.modelMetadata = defaults.modelMetadata
        config.supportedModalities = defaults.supportedModalities
        config.chatTemplateSource = defaults.chatTemplateSource
        config.stopSequences = defaults.stopSequences
        var copy = self
        copy.details = details.settingLLMProviderConfig(config)
        return copy
    }
}

// MARK: - ProfileDetails access

extension ProfileDetails {

    /// The LLM provider configuration this profile runs on, or nil for a workflow.
    var llmProviderConfig: ProviderConfig? {
        switch self {
        case .bot(let c):      return c.llmConfig
        case .agent(let c):    return c.llmConfig
        case .code(let c):     return c.llmConfig
        case .imageGen(let c): return c.llmConfig
        case .workflow:        return nil
        }
    }

    /// A copy with the LLM provider configuration replaced. A workflow is returned unchanged.
    func settingLLMProviderConfig(_ config: ProviderConfig) -> ProfileDetails {
        switch self {
        case .bot(var c):      c.llmConfig = config; return .bot(c)
        case .agent(var c):    c.llmConfig = config; return .agent(c)
        case .code(var c):     c.llmConfig = config; return .code(c)
        case .imageGen(var c): c.llmConfig = config; return .imageGen(c)
        case .workflow:        return self
        }
    }
}

extension ApiProvider {
    /// Whether this provider's capability is a fixed default rather than a measurement — the cloud
    /// providers, which always speak native tool calling, and OpenAI-compatible endpoints, which
    /// have no analyzer to measure them.
    var usesCloudDefaults: Bool {
        switch self {
        case .ollama, .mlx: return false
        case .openAI, .anthropic, .google, .openRouter, .openAICompatible: return true
        }
    }
}
