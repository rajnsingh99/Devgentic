// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ModelCatalogService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftUI

private let logger = DGLogger(category: "ModelCatalogService")

/// Aggregates models from local engines (Ollama, MLX) and curated remote providers
/// (Hugging Face, Anthropic, OpenAI, Google Gemini, OpenRouter).
@Observable
@MainActor
final class ModelCatalogService {

    @ObservationIgnored static let shared = ModelCatalogService()

    var isLoading: Bool = false
    var isOllamaOnline: Bool = false
    var ollamaVersion: String? = nil
    var cachedOllamaModels: [CatalogModelItem] = []
    var cachedMLXModels: [CatalogModelItem] = []
    var isCustomEndpointOnline: Bool = false
    var customEndpointError: String? = nil
    var cachedCustomModels: [CatalogModelItem] = []

    private init() {}

    // MARK: - Models for Category

    func models(for category: ModelCatalogProviderCategory, baseURLOverride: String? = nil) async -> [CatalogModelItem] {
        switch category {
        case .ollama:
            return await loadOllamaModels(baseURL: baseURLOverride ?? ProviderDefaults.ollamaBaseURL.absoluteString)
        case .mlx:
            return loadMLXModels()
        case .huggingFace:
            return curatedHuggingFaceModels
        case .anthropic:
            return curatedAnthropicModels
        case .openAI:
            return curatedOpenAIModels
        case .google:
            return curatedGoogleModels
        case .openRouter:
            return curatedOpenRouterModels
        case .custom:
            let endpoint = baseURLOverride ?? AppProviderKeyStore.loadEndpoint(forAccount: "openai_compatible") ?? ProviderDefaults.openAICompatibleHintURL.absoluteString
            let key = AppProviderKeyStore.load(forAccount: "openai_compatible")
            return await loadCustomEndpointModels(baseURL: endpoint, apiKey: key)
        }
    }

    func contextWindow(for modelId: String, category: ModelCatalogProviderCategory) -> String? {
        if let model = cachedOllamaModels.first(where: { $0.id == modelId }) {
            return model.contextWindowDisplay
        }
        if let model = cachedMLXModels.first(where: { $0.id == modelId }) {
            return model.contextWindowDisplay
        }
        if let model = cachedCustomModels.first(where: { $0.id == modelId }) {
            return model.contextWindowDisplay
        }
        let allCurated = curatedAnthropicModels + curatedOpenAIModels + curatedGoogleModels + curatedOpenRouterModels + curatedHuggingFaceModels
        if let model = allCurated.first(where: { $0.id == modelId }) {
            return model.contextWindowDisplay
        }
        return nil
    }

    // MARK: - Local Model Loaders

    func loadOllamaModels(baseURL: String) async -> [CatalogModelItem] {
        guard let url = URL(string: baseURL), ProviderDefaults.isUsableEndpoint(url) else {
            return []
        }

        do {
            let result = try await LocalModelRefresher.refresh(baseURL: baseURL, cached: [], cachedDaemonVersion: nil)
            isOllamaOnline = true
            ollamaVersion = result.daemonVersion

            let items = result.models.map { local -> CatalogModelItem in
                let profile = local.cognitiveProfile
                let metadata = profile.metadata
                let assessment = ModelFitAdvisor.assess(
                    metadata: metadata,
                    modelName: local.name
                )

                let ctxDisplay = metadata?.contextWindow.map { formatContextWindow($0) } ?? "8K"
                let isReasoning = profile.toolSupportCaveat == .reasoningFocused

                return CatalogModelItem(
                    id: local.name,
                    displayName: local.name,
                    provider: .ollama,
                    vendorKey: "ollama",
                    parameterCount: metadata?.parameterCount,
                    contextWindow: metadata?.contextWindow,
                    contextWindowDisplay: ctxDisplay,
                    supportedModalities: profile.modalities,
                    cognitiveCapability: local.cognitiveCapability,
                    modelDialect: profile.dialect,
                    isReasoning: isReasoning,
                    isInstalled: true,
                    estimatedRAMBytes: Int64(assessment.estimatedRuntimeRAM),
                    descriptionText: local.digest.map { "Digest: \($0.prefix(12))" } ?? "",
                    baseURL: baseURL,
                    tags: [],
                    fitAssessment: assessment,
                    detectedProfile: profile
                )
            }
            cachedOllamaModels = items
            return items
        } catch {
            logger.debug("[CATALOG] Ollama not reachable at \(baseURL): \(error.localizedDescription)")
            isOllamaOnline = false
            return cachedOllamaModels
        }
    }

    func loadMLXModels() -> [CatalogModelItem] {
        let installed = MLXModelService.shared.installedModels
        let items = installed.map { item -> CatalogModelItem in
            let profile = MLXModelService.shared.cachedCognitiveProfile(for: item)
            let assessment = ModelFitAdvisor.assess(
                metadata: profile.metadata,
                modelName: item.displayName
            )

            let ctxDisplay = profile.metadata?.contextWindow.map { formatContextWindow($0) } ?? "32K"

            return CatalogModelItem(
                id: item.displayName,
                displayName: item.displayName,
                provider: .mlx,
                vendorKey: "mlx",
                parameterCount: profile.metadata?.parameterCount,
                contextWindow: profile.metadata?.contextWindow,
                contextWindowDisplay: ctxDisplay,
                supportedModalities: profile.modalities,
                cognitiveCapability: profile.capability,
                modelDialect: profile.dialect,
                isReasoning: false,
                isInstalled: true,
                estimatedRAMBytes: Int64(assessment.estimatedRuntimeRAM),
                descriptionText: item.localPath.lastPathComponent,
                baseURL: nil,
                tags: [],
                fitAssessment: assessment,
                detectedProfile: profile
            )
        }
        cachedMLXModels = items
        return items
    }

    // MARK: - Curated Remote Catalogs

    var curatedHuggingFaceModels: [CatalogModelItem] {
        [
            CatalogModelItem(
                id: "meta-llama/Llama-3.3-70B-Instruct",
                displayName: "Llama 3.3 70B Instruct",
                provider: .openAICompatible,
                vendorKey: "huggingface",
                parameterCount: "70B",
                contextWindow: 131_072,
                contextWindowDisplay: "128K",
                supportedModalities: .textOnly,
                cognitiveCapability: .parallelActions,
                modelDialect: .llama3JsonSingle,
                isReasoning: false,
                descriptionText: "State-of-the-art open weights with industry-leading reasoning, coding, and multilingual performance.",
                baseURL: ProviderDefaults.huggingFaceRouterBaseURL.absoluteString,
                tags: ["Frontier"]
            ),
            CatalogModelItem(
                id: "Qwen/Qwen2.5-Coder-32B-Instruct",
                displayName: "Qwen 2.5 Coder 32B Instruct",
                provider: .openAICompatible,
                vendorKey: "huggingface",
                parameterCount: "32B",
                contextWindow: 131_072,
                contextWindowDisplay: "128K",
                supportedModalities: .textOnly,
                cognitiveCapability: .parallelActions,
                modelDialect: .qwenHermesToolCall,
                isReasoning: false,
                descriptionText: "Exceptional coding intelligence comparable to GPT-4o on software engineering and code generation benchmarks.",
                baseURL: ProviderDefaults.huggingFaceRouterBaseURL.absoluteString,
                tags: ["Code Specialist"]
            ),
            CatalogModelItem(
                id: "deepseek-ai/DeepSeek-R1",
                displayName: "DeepSeek R1 (Distill / Router)",
                provider: .openAICompatible,
                vendorKey: "huggingface",
                parameterCount: "671B MoE",
                contextWindow: 131_072,
                contextWindowDisplay: "128K",
                supportedModalities: .textOnly,
                cognitiveCapability: .parallelActions,
                modelDialect: .deepseekV3JsonFence,
                isReasoning: true,
                descriptionText: "Deep reasoning frontier model using reinforcement learning for chain-of-thought verification.",
                baseURL: ProviderDefaults.huggingFaceRouterBaseURL.absoluteString,
                tags: ["Frontier Reasoning", "Chain-of-Thought"]
            ),
            CatalogModelItem(
                id: "mistralai/Mistral-Small-24B-Instruct-2501",
                displayName: "Mistral Small 24B (2501)",
                provider: .openAICompatible,
                vendorKey: "huggingface",
                parameterCount: "24B",
                contextWindow: 32_768,
                contextWindowDisplay: "32K",
                supportedModalities: .textOnly,
                cognitiveCapability: .parallelActions,
                modelDialect: .mistralV11Flat,
                isReasoning: false,
                descriptionText: "High efficiency, powerful instruction following, and reliable tool calling in a compact size.",
                baseURL: ProviderDefaults.huggingFaceRouterBaseURL.absoluteString,
                tags: ["Fast"]
            ),
            CatalogModelItem(
                id: "meta-llama/Llama-3.2-11B-Vision-Instruct",
                displayName: "Llama 3.2 11B Vision",
                provider: .openAICompatible,
                vendorKey: "huggingface",
                parameterCount: "11B",
                contextWindow: 131_072,
                contextWindowDisplay: "128K",
                supportedModalities: .visionInput,
                cognitiveCapability: .parallelActions,
                modelDialect: .llama3JsonSingle,
                isReasoning: false,
                descriptionText: "Multimodal model capable of visual understanding, image reasoning, and chart parsing.",
                baseURL: ProviderDefaults.huggingFaceRouterBaseURL.absoluteString,
                tags: ["Multimodal"]
            ),
            CatalogModelItem(
                id: "google/gemma-2-27b-it",
                displayName: "Gemma 2 27B Instruct",
                provider: .openAICompatible,
                vendorKey: "huggingface",
                parameterCount: "27B",
                contextWindow: 8_192,
                contextWindowDisplay: "8K",
                supportedModalities: .textOnly,
                cognitiveCapability: .none,
                modelDialect: .nativeJSON,
                isReasoning: false,
                descriptionText: "Google's open-weights model designed for general conversational intelligence and text completion.",
                baseURL: ProviderDefaults.huggingFaceRouterBaseURL.absoluteString,
                tags: ["Conversational"]
            )
        ]
    }

    var curatedAnthropicModels: [CatalogModelItem] {
        [
            CatalogModelItem(
                id: "claude-3-7-sonnet-20250219",
                displayName: "Claude 3.7 Sonnet",
                provider: .anthropic,
                vendorKey: "anthropic",
                parameterCount: "Frontier",
                contextWindow: 200_000,
                contextWindowDisplay: "200K",
                supportedModalities: .visionInput,
                cognitiveCapability: .parallelActions,
                modelDialect: .nativeJSON,
                isReasoning: true,
                descriptionText: "Anthropic's most intelligent hybrid model with dynamic reasoning and state-of-the-art coding capabilities.",
                baseURL: ProviderDefaults.anthropicBaseURL.absoluteString,
                tags: ["Hybrid Reasoning"]
            ),
            CatalogModelItem(
                id: "claude-3-5-sonnet-20241022",
                displayName: "Claude 3.5 Sonnet",
                provider: .anthropic,
                vendorKey: "anthropic",
                parameterCount: "Frontier",
                contextWindow: 200_000,
                contextWindowDisplay: "200K",
                supportedModalities: .visionInput,
                cognitiveCapability: .parallelActions,
                modelDialect: .nativeJSON,
                isReasoning: false,
                descriptionText: "Exceptional coding, creative writing, and nuanced reasoning with industry-grade reliability.",
                baseURL: ProviderDefaults.anthropicBaseURL.absoluteString,
                tags: []
            ),
            CatalogModelItem(
                id: "claude-3-5-haiku-20241022",
                displayName: "Claude 3.5 Haiku",
                provider: .anthropic,
                vendorKey: "anthropic",
                parameterCount: "Fast",
                contextWindow: 200_000,
                contextWindowDisplay: "200K",
                supportedModalities: .textOnly,
                cognitiveCapability: .parallelActions,
                modelDialect: .nativeJSON,
                isReasoning: false,
                descriptionText: "Ultra-fast, cost-effective model designed for real-time responsiveness and agentic operations.",
                baseURL: ProviderDefaults.anthropicBaseURL.absoluteString,
                tags: ["Ultra-Fast"]
            ),
            CatalogModelItem(
                id: "claude-3-opus-20240229",
                displayName: "Claude 3 Opus",
                provider: .anthropic,
                vendorKey: "anthropic",
                parameterCount: "Deep",
                contextWindow: 200_000,
                contextWindowDisplay: "200K",
                supportedModalities: .visionInput,
                cognitiveCapability: .parallelActions,
                modelDialect: .nativeJSON,
                isReasoning: false,
                descriptionText: "Deep reasoning power for complex analysis, long-form synthesis, and intricate research tasks.",
                baseURL: ProviderDefaults.anthropicBaseURL.absoluteString,
                tags: ["Deep Analysis"]
            )
        ]
    }

    var curatedOpenAIModels: [CatalogModelItem] {
        [
            CatalogModelItem(
                id: "gpt-4o",
                displayName: "GPT-4o (Omni)",
                provider: .openAI,
                vendorKey: "openai",
                parameterCount: "Frontier",
                contextWindow: 128_000,
                contextWindowDisplay: "128K",
                supportedModalities: .visionInput,
                cognitiveCapability: .parallelActions,
                modelDialect: .nativeJSON,
                isReasoning: false,
                descriptionText: "Flagship multimodal intelligence with high speed and precision across text, visual parsing, and tool execution.",
                baseURL: ProviderDefaults.openAIBaseURL.absoluteString,
                tags: []
            ),
            CatalogModelItem(
                id: "gpt-4o-mini",
                displayName: "GPT-4o mini",
                provider: .openAI,
                vendorKey: "openai",
                parameterCount: "Compact",
                contextWindow: 128_000,
                contextWindowDisplay: "128K",
                supportedModalities: .visionInput,
                cognitiveCapability: .parallelActions,
                modelDialect: .nativeJSON,
                isReasoning: false,
                descriptionText: "Fast and lightweight model optimized for quick turnaround and low latency operations.",
                baseURL: ProviderDefaults.openAIBaseURL.absoluteString,
                tags: ["Fast"]
            ),
            CatalogModelItem(
                id: "o3-mini",
                displayName: "o3-mini",
                provider: .openAI,
                vendorKey: "openai",
                parameterCount: "Reasoning",
                contextWindow: 200_000,
                contextWindowDisplay: "200K",
                supportedModalities: .textOnly,
                cognitiveCapability: .parallelActions,
                modelDialect: .nativeJSON,
                isReasoning: true,
                descriptionText: "Next-generation reasoning model specialized in coding, mathematics, and complex multi-step reasoning.",
                baseURL: ProviderDefaults.openAIBaseURL.absoluteString,
                tags: ["Frontier Reasoning", "Coding"]
            ),
            CatalogModelItem(
                id: "o1",
                displayName: "o1",
                provider: .openAI,
                vendorKey: "openai",
                parameterCount: "Frontier",
                contextWindow: 200_000,
                contextWindowDisplay: "200K",
                supportedModalities: .visionInput,
                cognitiveCapability: .none,
                modelDialect: .nativeJSON,
                isReasoning: true,
                descriptionText: "Full-scale reasoning model engineered to spend more time thinking through hard science and coding challenges.",
                baseURL: ProviderDefaults.openAIBaseURL.absoluteString,
                tags: ["Deep Reasoning"]
            )
        ]
    }

    var curatedGoogleModels: [CatalogModelItem] {
        [
            CatalogModelItem(
                id: "gemini-2.5-pro",
                displayName: "Gemini 2.5 Pro",
                provider: .google,
                vendorKey: "google",
                parameterCount: "Frontier",
                contextWindow: 1_000_000,
                contextWindowDisplay: "1M",
                supportedModalities: .visionInput,
                cognitiveCapability: .parallelActions,
                modelDialect: .nativeJSON,
                isReasoning: true,
                descriptionText: "Google's flagship reasoning and multimodal model with massive 1M token context capacity.",
                baseURL: ProviderDefaults.geminiBaseURL.absoluteString,
                tags: []
            ),
            CatalogModelItem(
                id: "gemini-2.5-flash",
                displayName: "Gemini 2.5 Flash",
                provider: .google,
                vendorKey: "google",
                parameterCount: "Fast",
                contextWindow: 1_000_000,
                contextWindowDisplay: "1M",
                supportedModalities: .visionInput,
                cognitiveCapability: .parallelActions,
                modelDialect: .nativeJSON,
                isReasoning: true,
                descriptionText: "Ultra-fast response latency with adaptive reasoning and multimodal understanding.",
                baseURL: ProviderDefaults.geminiBaseURL.absoluteString,
                tags: ["Ultra-Fast"]
            ),
            CatalogModelItem(
                id: "gemini-2.0-flash-exp",
                displayName: "Gemini 2.0 Flash (Experimental)",
                provider: .google,
                vendorKey: "google",
                parameterCount: "Fast",
                contextWindow: 1_000_000,
                contextWindowDisplay: "1M",
                supportedModalities: .visionInput,
                cognitiveCapability: .parallelActions,
                modelDialect: .nativeJSON,
                isReasoning: false,
                descriptionText: "High throughput experimental build showcasing the newest multimodal features.",
                baseURL: ProviderDefaults.geminiBaseURL.absoluteString,
                tags: ["Experimental"]
            ),
            CatalogModelItem(
                id: "gemini-1.5-pro",
                displayName: "Gemini 1.5 Pro",
                provider: .google,
                vendorKey: "google",
                parameterCount: "Frontier",
                contextWindow: 2_000_000,
                contextWindowDisplay: "2M",
                supportedModalities: .visionInput,
                cognitiveCapability: .parallelActions,
                modelDialect: .nativeJSON,
                isReasoning: false,
                descriptionText: "Proven workhorse for huge document synthesis and long-context multimodal analysis up to 2M tokens.",
                baseURL: ProviderDefaults.geminiBaseURL.absoluteString,
                tags: []
            )
        ]
    }

    var curatedOpenRouterModels: [CatalogModelItem] {
        [
            CatalogModelItem(
                id: "anthropic/claude-3.7-sonnet",
                displayName: "Claude 3.7 Sonnet",
                provider: .openRouter,
                vendorKey: "openrouter",
                parameterCount: "Frontier",
                contextWindow: 200_000,
                contextWindowDisplay: "200K",
                supportedModalities: .visionInput,
                cognitiveCapability: .parallelActions,
                modelDialect: .nativeJSON,
                isReasoning: true,
                descriptionText: "Routed via OpenRouter aggregator with flexible rate limits and fallback failover.",
                baseURL: ProviderDefaults.openRouterBaseURL.absoluteString,
                tags: []
            ),
            CatalogModelItem(
                id: "openai/gpt-4o",
                displayName: "GPT-4o",
                provider: .openRouter,
                vendorKey: "openrouter",
                parameterCount: "Frontier",
                contextWindow: 128_000,
                contextWindowDisplay: "128K",
                supportedModalities: .visionInput,
                cognitiveCapability: .parallelActions,
                modelDialect: .nativeJSON,
                isReasoning: false,
                descriptionText: "OpenAI flagship routed with global latency optimization.",
                baseURL: ProviderDefaults.openRouterBaseURL.absoluteString,
                tags: []
            ),
            CatalogModelItem(
                id: "meta-llama/llama-3.3-70b-instruct",
                displayName: "Llama 3.3 70B",
                provider: .openRouter,
                vendorKey: "openrouter",
                parameterCount: "70B",
                contextWindow: 131_072,
                contextWindowDisplay: "128K",
                supportedModalities: .textOnly,
                cognitiveCapability: .parallelActions,
                modelDialect: .nativeJSON,
                isReasoning: false,
                descriptionText: "High-speed hosted Llama 3.3 70B through OpenRouter inference partners.",
                baseURL: ProviderDefaults.openRouterBaseURL.absoluteString,
                tags: []
            ),
            CatalogModelItem(
                id: "deepseek/deepseek-r1",
                displayName: "DeepSeek R1",
                provider: .openRouter,
                vendorKey: "openrouter",
                parameterCount: "671B MoE",
                contextWindow: 131_072,
                contextWindowDisplay: "128K",
                supportedModalities: .textOnly,
                cognitiveCapability: .parallelActions,
                modelDialect: .nativeJSON,
                isReasoning: true,
                descriptionText: "Chain-of-thought frontier reasoning model hosted on OpenRouter.",
                baseURL: ProviderDefaults.openRouterBaseURL.absoluteString,
                tags: []
            )
        ]
    }

    func loadCustomEndpointModels(baseURL: String, apiKey: String?) async -> [CatalogModelItem] {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ProviderDefaults.isUsableEndpoint(url) else {
            isCustomEndpointOnline = false
            customEndpointError = "Invalid base URL"
            return cachedCustomModels
        }

        do {
            let service = OpenAICompatibleService()
            let modelIDs = try await service.fetchModels(baseURL: trimmed, apiKey: apiKey)
            isCustomEndpointOnline = true
            customEndpointError = nil

            let items = modelIDs.map { modelId -> CatalogModelItem in
                let lower = modelId.lowercased()
                let isReasoning = lower.contains("r1") || lower.contains("reason") || lower.contains("think") || lower.contains("o1") || lower.contains("o3")
                let hasVision = lower.contains("vl") || lower.contains("vision") || lower.contains("4o") || lower.contains("pixtral")

                var ctx: Int? = 32_768
                var ctxDisplay = "32K"
                if lower.contains("128k") {
                    ctx = 131_072
                    ctxDisplay = "128K"
                } else if lower.contains("64k") {
                    ctx = 65_536
                    ctxDisplay = "64K"
                } else if lower.contains("1m") {
                    ctx = 1_000_000
                    ctxDisplay = "1M"
                }

                return CatalogModelItem(
                    id: modelId,
                    displayName: modelId,
                    provider: .openAICompatible,
                    vendorKey: "openai_compatible",
                    parameterCount: nil,
                    contextWindow: ctx,
                    contextWindowDisplay: ctxDisplay,
                    supportedModalities: hasVision ? .visionInput : .textOnly,
                    cognitiveCapability: .parallelActions,
                    modelDialect: .nativeJSON,
                    isReasoning: isReasoning,
                    isInstalled: true,
                    descriptionText: "Discovered from gateway at \(trimmed)",
                    baseURL: trimmed,
                    tags: []
                )
            }
            cachedCustomModels = items
            return items
        } catch {
            logger.debug("[CATALOG] Custom endpoint not reachable at \(trimmed): \(error.localizedDescription)")
            isCustomEndpointOnline = false
            customEndpointError = error.localizedDescription
            cachedCustomModels = []
            return []
        }
    }

    private func formatContextWindow(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            let m = tokens / 1_000_000
            return "\(m)M"
        } else if tokens >= 1_000 {
            let k = tokens / 1_000
            return "\(k)K"
        }
        return "\(tokens)"
    }
}
