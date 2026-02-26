//
//  CognitiveStrategies.swift
//  Devgentic
//
//  Created by Raj Singh on 16/02/26.
//

import Foundation

// MARK: - Cognitive Profile Factories

/// Abstract Factory ensuring the correct pairings of Adapters and Strategies based on the selected LLM Provider.
protocol CognitiveProfileFactory {
    func createGenerator() -> any CognitiveGenerator
}

/// Factory for cloud providers that natively support JSON Schema and Tool Arrays (e.g., OpenAI).
struct CloudNativeProfileFactory: CognitiveProfileFactory {
    func createGenerator() -> any CognitiveGenerator {
        return NativeStructuredGenerator(toolAdapter: NativeJSONSchemaAdapter())
    }
}

/// Factory for Ollama instances running modern models with native tool support.
struct OllamaNativeProfileFactory: CognitiveProfileFactory {
    func createGenerator() -> any CognitiveGenerator {
        return NativeStructuredGenerator(toolAdapter: NativeJSONSchemaAdapter())
    }
}

/// Factory for local or constrained models requiring explicit prompt instructions for tool usage.
struct LocalPromptedProfileFactory: CognitiveProfileFactory {
    func createGenerator() -> any CognitiveGenerator {
        return PromptedJsonModeStrategy(toolAdapter: LegacyPromptAdapter())
    }
}

/// Factory for providers like Gemini where strict JSON schema validation may occasionally fail.
struct GeminiShadowProfileFactory: CognitiveProfileFactory {
    func createGenerator() -> any CognitiveGenerator {
        return ShadowSchemaGenerator(toolAdapter: LegacyPromptAdapter())
    }
}
