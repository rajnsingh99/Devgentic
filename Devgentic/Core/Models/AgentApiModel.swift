//
//  AgentAPIModels.swift
//  Devgentic
//
//  Created by Raj Singh on 09/06/25.
//

import Foundation

// MARK: - Main Chat Request Payload
// This is the root object that will be encoded into JSON and sent to the /agent/chat endpoint.

struct ChatRequestPayload: Codable {
    /// Mandatory. Unique identifier for the conversation.
    let conversationId: String

    /// The user's message, including the prompt and any associated files.
    let messageContent: MessageContentPayload

    /// Mandatory. Configuration for the agent(s) processing this request.
    let agentConfig: [AgentConfigItemPayload]

    /// Metadata associated with the chat request.
    let metadata: RequestMetadataPayload
}

// MARK: - Nested Payload Structures

/// Represents the content of the user's message.
struct MessageContentPayload: Codable {
    /// Mandatory. The user's textual prompt.
    let prompt: String

    /// Optional. List of file objects associated with the prompt. Defaults to an empty array.
    let files: [FileObjectPayload]
}

/// Represents a single file associated with the message.
struct FileObjectPayload: Codable {
    /// Mandatory. URI of the file (e.g., "file:///path/to/file.txt").
    let uri: String

    /// Optional. Display name of the file.
    let name: String?

    /// Optional. MIME type of the file (e.g., "text/plain").
    let mimeType: String?

    /// Optional. Size of the file in bytes.
    let sizeBytes: Int?
    
    /// Optional. Programming language of the file, if applicable.
    let language: String?

    enum CodingKeys: String, CodingKey {
        case uri, name
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case language
    }
}

/// Defines the configuration for a single agent instance to be orchestrated.
struct AgentConfigItemPayload: Codable {
    /// Mandatory. A unique identifier for this agent configuration instance.
    let id: String

    /// Optional. A descriptive role or name for this agent configuration.
    let role: String?

    /// Optional. List of tools or capabilities this agent instance should have.
    let tools: [String]

    /// The configuration for the backing Language Model.
    let llmSettings: LLMSettingsPayload
    
    enum CodingKeys: String, CodingKey {
        case id, role, tools
        case llmSettings = "llm_settings"
    }
}

/// Configuration specific to the Language Model provider.
struct LLMSettingsPayload: Codable {
    /// The LLM provider (e.g., "ollama"). Defaults to "ollama".
    let provider: String

    /// Mandatory. Base URL of the LLM instance.
    let baseURL: String

    /// Mandatory. Name of the LLM model to use (e.g., "gemma:2b").
    let modelName: String

    /// Optional. Controls randomness (0.0-2.0).
    let temperature: Double?

    /// Optional. Limits sampling to the k most likely tokens.
    let topK: Int?

    /// Optional. Cumulative probability threshold for nucleus sampling.
    let topP: Double?

    /// Optional. Penalizes token repetition.
    let repeatPenalty: Double?

    /// Optional. Context window size for the model.
    let contextWindowSize: Int?

    /// Optional. Number of GPU layers to use (-1 for all).
    let gpuLayers: Int?
    
    enum CodingKeys: String, CodingKey {
        case provider
        case baseURL = "base_url"
        case modelName = "model_name"
        case temperature
        case topK = "top_k"
        case topP = "top_p"
        case repeatPenalty = "repeat_penalty"
        case contextWindowSize = "context_window_size"
        case gpuLayers = "gpu_layers"
    }
}


/// Metadata associated with the chat request.
struct RequestMetadataPayload: Codable {
    /// A client-generated request ID for tracing purposes.
    let clientRequestId: String
    
    enum CodingKeys: String, CodingKey {
        case clientRequestId = "client_request_id"
    }
}
