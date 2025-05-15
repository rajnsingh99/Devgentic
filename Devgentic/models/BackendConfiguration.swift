//
//  BackendConfiguration.swift
//  Devgentic
//
//  Created by Raj Singh on 16/05/25.
//

// MARK: - Payload Construction Helpers (Now primarily for determineBackendConfiguration)
// The actual prompt/payload string construction from MessagePart is now in DefaultLLMCommunicator.
// These helpers (constructOllamaPrompt, constructAgentPayload) are REMOVED from ViewModel.
// The determineBackendConfiguration method is simplified.

struct BackendConfiguration {
    let url: String
    let endpoint: String
    var payload: [String: Any] // Keep payload flexible for model params, stream options etc.
                               // The main "prompt" or "task" will be set by the communicator.
}
