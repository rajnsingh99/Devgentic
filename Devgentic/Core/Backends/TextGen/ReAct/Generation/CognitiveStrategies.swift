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
        return NativeStructuredStrategy(toolAdapter: NativeJSONSchemaAdapter())
    }
}

/// Factory for Ollama instances running modern models with native tool support.
struct OllamaNativeProfileFactory: CognitiveProfileFactory {
    func createGenerator() -> any CognitiveGenerator {
        return NativeStructuredStrategy(toolAdapter: NativeJSONSchemaAdapter())
    }
}

/// Factory for local or constrained models requiring explicit prompt instructions for tool usage.
struct LocalPromptedProfileFactory: CognitiveProfileFactory {
    func createGenerator() -> any CognitiveGenerator {
        return PromptedJsonModeStrategy(toolAdapter: LegacyPromptAdapter())
    }
}

/// Factory for Mistral-family local models using <tool_call> XML wrapping.
struct MistralXMLProfileFactory: CognitiveProfileFactory {
    func createGenerator() -> any CognitiveGenerator {
        return MistralXMLGenerator()
    }
}

/// Factory for models using the classic ReAct Thought/Action/Action Input format.
struct LlamaReActProfileFactory: CognitiveProfileFactory {
    func createGenerator() -> any CognitiveGenerator {
        return LlamaReActGenerator()
    }
}
