// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CatalogModelItem.swift
//  Devgentic
//
//  Data model representing an LLM model in the dedicated Model Catalog split-view window.
//

import Foundation
import SwiftUI

// MARK: - Provider Categories for Catalog Sidebar

enum ModelCatalogProviderCategory: String, CaseIterable, Identifiable, Sendable {
    case ollama
    case mlx
    case huggingFace
    case anthropic
    case openAI
    case google
    case openRouter
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ollama: return "Ollama"
        case .mlx: return "MLX"
        case .huggingFace: return "Hugging Face"
        case .anthropic: return "Anthropic"
        case .openAI: return "OpenAI"
        case .google: return "Google Gemini"
        case .openRouter: return "OpenRouter"
        case .custom: return "Custom Endpoint"
        }
    }

    var subtitle: String {
        switch self {
        case .ollama: return "Local Engine"
        case .mlx: return "Apple Silicon"
        case .huggingFace: return "Inference Router"
        case .anthropic: return "Claude 3.5 & 3.7"
        case .openAI: return "GPT-4o & o-series"
        case .google: return "Gemini 2.5 & 2.0"
        case .openRouter: return "Universal Router"
        case .custom: return "OpenAI-Compatible"
        }
    }

    var icon: String {
        switch self {
        case .ollama: return "terminal.fill"
        case .mlx: return "apple.logo"
        case .huggingFace: return "face.smiling"
        case .anthropic: return "staroflife.fill"
        case .openAI: return "atom"
        case .google: return "sparkle"
        case .openRouter: return "arrow.triangle.branch"
        case .custom: return "gearshape.2"
        }
    }

    var isLocal: Bool {
        self == .ollama || self == .mlx
    }

    var apiProvider: ApiProvider {
        switch self {
        case .ollama: return .ollama
        case .mlx: return .mlx
        case .huggingFace: return .openAICompatible
        case .anthropic: return .anthropic
        case .openAI: return .openAI
        case .google: return .google
        case .openRouter: return .openRouter
        case .custom: return .openAICompatible
        }
    }

    var vendorKey: String {
        switch self {
        case .huggingFace: return "huggingface"
        case .ollama: return "ollama"
        case .mlx: return "mlx"
        case .anthropic: return "anthropic"
        case .openAI: return "openai"
        case .google: return "google"
        case .openRouter: return "openrouter"
        case .custom: return "openai_compatible"
        }
    }

    var defaultBaseURL: String? {
        switch self {
        case .huggingFace:
            return ProviderDefaults.huggingFaceRouterBaseURL.absoluteString
        case .ollama:
            return ProviderDefaults.ollamaBaseURL.absoluteString
        case .anthropic:
            return ProviderDefaults.anthropicBaseURL.absoluteString
        case .openAI:
            return ProviderDefaults.openAIBaseURL.absoluteString
        case .google:
            return ProviderDefaults.geminiBaseURL.absoluteString
        case .openRouter:
            return ProviderDefaults.openRouterBaseURL.absoluteString
        case .custom:
            return ProviderDefaults.openAICompatibleHintURL.absoluteString
        case .mlx:
            return nil
        }
    }

    /// Finds matching category for an active provider config.
    static func category(for config: ProviderConfig) -> ModelCatalogProviderCategory {
        switch config.apiProvider {
        case .ollama:
            return .ollama
        case .mlx:
            return .mlx
        case .anthropic:
            return .anthropic
        case .openAI:
            return .openAI
        case .google:
            return .google
        case .openRouter:
            return .openRouter
        case .openAICompatible:
            if let base = config.baseURL, base.contains("huggingface") {
                return .huggingFace
            }
            return .custom
        }
    }
}

// MARK: - Catalog Filter Capability

enum CatalogFilterCapability: String, CaseIterable, Identifiable {
    case all = "All Models"
    case vision = "Vision"
    case tools = "Tool Calling"
    case reasoning = "Reasoning"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .vision: return "eye"
        case .tools: return "wrench.and.screwdriver"
        case .reasoning: return "brain"
        }
    }
}

// MARK: - Catalog Model Item

struct CatalogModelItem: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let provider: ApiProvider
    let vendorKey: String
    let parameterCount: String?
    let contextWindow: Int?
    let contextWindowDisplay: String
    let supportedModalities: SupportedModalities
    let cognitiveCapability: ModelCognitiveCapability
    let modelDialect: ModelDialect
    let isReasoning: Bool
    let isInstalled: Bool
    let estimatedRAMBytes: Int64?
    let descriptionText: String
    let baseURL: String?
    let tags: [String]
    let fitAssessment: ModelFitAssessment?

    init(
        id: String,
        displayName: String,
        provider: ApiProvider,
        vendorKey: String,
        parameterCount: String? = nil,
        contextWindow: Int? = nil,
        contextWindowDisplay: String = "128K",
        supportedModalities: SupportedModalities = .textOnly,
        cognitiveCapability: ModelCognitiveCapability = .none,
        modelDialect: ModelDialect = .nativeJSON,
        isReasoning: Bool = false,
        isInstalled: Bool = false,
        estimatedRAMBytes: Int64? = nil,
        descriptionText: String = "",
        baseURL: String? = nil,
        tags: [String] = [],
        fitAssessment: ModelFitAssessment? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.vendorKey = vendorKey
        self.parameterCount = parameterCount
        self.contextWindow = contextWindow
        self.contextWindowDisplay = contextWindowDisplay
        self.supportedModalities = supportedModalities
        self.cognitiveCapability = cognitiveCapability
        self.modelDialect = modelDialect
        self.isReasoning = isReasoning
        self.isInstalled = isInstalled
        self.estimatedRAMBytes = estimatedRAMBytes
        self.descriptionText = descriptionText
        self.baseURL = baseURL
        self.tags = tags
        self.fitAssessment = fitAssessment
    }

    var hasVision: Bool {
        supportedModalities.contains(.visionInput)
    }

    var hasTools: Bool {
        cognitiveCapability != .none
    }

    static func == (lhs: CatalogModelItem, rhs: CatalogModelItem) -> Bool {
        lhs.id == rhs.id && lhs.provider == rhs.provider && lhs.baseURL == rhs.baseURL
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(provider)
        hasher.combine(baseURL)
    }
}
