//
//  ChatMessage.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//

import Foundation
import Combine

enum GenerationType: String, Codable, CaseIterable, Identifiable {
    case text
    case imageData
    case videoData
    
    var id: String { self.rawValue }
}

struct ResponseMessageVariant: Codable, Equatable {
    let variantId: UUID = UUID()
    var content: MessageContent
    let backendEntityId: UUID?
}

/// Holds all response variants for a single agent message.
struct AgentResponse: Codable, Equatable {
    var variants: [ResponseMessageVariant]
    var selectedVariantIndex: Int = 0
    var generationAttempts: Int = 1
}

enum TimelineEvent: Codable, Equatable, Identifiable {
    case thought(id: UUID, text: String)
    case toolExecution(id: UUID, name: String, params: String, output: String?, isSuccess: Bool?, isExecuting: Bool)
    case mediaGeneration(id: UUID, toolName: String, artifact: MediaArtifact?, isComplete: Bool)

    var id: UUID {
        switch self {
        case .thought(let id, _): return id
        case .toolExecution(let id, _, _, _, _, _): return id
        case .mediaGeneration(let id, _, _, _): return id
        }
    }
}

class ChatMessage: ObservableObject, Identifiable, Codable, Equatable, @unchecked Sendable {
    let id: UUID
    let conversationId: UUID
    let timestamp: Date
    let sender: SenderRole
    
    @Published var content: MessageContent
    @Published var agentResponse: AgentResponse?
    @Published var isStreaming: Bool = false
    
    // MARK: - Glass Box UI State (Gemini-Style)
    // These properties store the intermediate reasoning and tool outputs.
    // These properties derive chronological reasoning steps and tool outputs from timelineEvents.
    var thoughts: [AgentThought] {
        timelineEvents.compactMap { event in
            if case .thought(let id, let text) = event {
                return AgentThought(id: id, text: text)
            }
            return nil
        }
    }
    
    var artifacts: [ToolOutput] {
        timelineEvents.compactMap { event in
            if case .toolExecution(_, let name, _, let output, let isSuccess, let isExecuting) = event, !isExecuting {
                return ToolOutput(toolName: name, output: output ?? "", isSuccess: isSuccess ?? false)
            }
            return nil
        }
    }

    @Published var timelineEvents: [TimelineEvent] = []
    
    // MARK: - Transient UI State (Not Persisted)
    @Published var thinkingHeadline: String? = nil
    @Published var agentState: AgentState = .idle
    @Published var isThinkingExpanded: Bool = false // UI toggle for the accordion
    
    // [HITL] New Property for Permission Card
    @Published var pendingToolConfirmation: PendingToolConfirmation? = nil

    // [ASK_USER] Property for Clarification Card
    @Published var pendingClarification: PendingClarification? = nil
    
    // MARK: - RAG Indexing State
    // No longer polled; index occurs on stream completion.

    /// Estimated token count for the message content.
    /// Uses a heuristic of ~4 characters per token (standard for English/code text).
    /// This avoids expensive tokenizer calls for UI display and cost estimation.
    var tokenCountEstimate: Int {
        guard let text = content.textContent else { return 0 }
        return max(1, text.count / 4)
    }

    // MARK: - Performance Caching
    var cachedMarkdownBlocks: [ContentBlock]? = nil
    
    var attachedTextFiles: [AttachedTextFile]?
    var attachedImageFiles: [AttachedImageFile]?
    private var streamTask: Task<Void, Never>?

    /// Computed property to get the currently displayed content for an agent message.
    var currentAgentContent: MessageContent? {
        guard let response = agentResponse,
              response.variants.indices.contains(response.selectedVariantIndex) else {
            return nil
        }
        return response.variants[response.selectedVariantIndex].content
    }

    init(id: UUID = UUID(), conversationId: UUID, timestamp: Date = Date(), sender: SenderRole, content: MessageContent, attachedTextFiles: [AttachedTextFile]? = nil, attachedImageFiles: [AttachedImageFile]? = nil, isStreaming: Bool = false, backendEntityId: UUID? = nil) {
        self.id = id
        self.conversationId = conversationId
        self.timestamp = timestamp
        self.sender = sender
        self.content = content
        self.attachedTextFiles = attachedTextFiles
        self.attachedImageFiles = attachedImageFiles
        self.isStreaming = isStreaming

        if sender == .agent {
            let initialVariant = ResponseMessageVariant(
                content: content,
                backendEntityId: backendEntityId
            )
            self.agentResponse = AgentResponse(variants: [initialVariant])
        }
    }
    
    func getOrCreateMarkdownBlocks(from text: String) -> [ContentBlock] {
        if let cached = cachedMarkdownBlocks { return cached }
        let blocks = parseMarkdown(text)
        self.cachedMarkdownBlocks = blocks
        return blocks
    }
    
    func invalidateMarkdownCache() {
        self.cachedMarkdownBlocks = nil
    }

    /// Returns parsed ContentBlocks for the RAG indexing pipeline.
    func getBlocksForIndexing() -> [ContentBlock] {
        switch content {
        case .plainText(let text), .markdownText(let text):
            return getOrCreateMarkdownBlocks(from: text)
        case .codeBlock(let language, let code):
            return [ContentBlock(id: "block-0", type: .code(language: language ?? "text", content: code, fileName: nil))]
        case .error, .image, .mediaArtifact:
            return []
        }
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        return lhs.id == rhs.id &&
               lhs.content == rhs.content &&
               lhs.isStreaming == rhs.isStreaming &&
               lhs.agentResponse == rhs.agentResponse &&
               lhs.thoughts == rhs.thoughts &&
               lhs.artifacts == rhs.artifacts &&
               lhs.pendingToolConfirmation == rhs.pendingToolConfirmation &&
               lhs.pendingClarification == rhs.pendingClarification
    }
    
    func beginStreamingResponse(from service: BackendOrchestrationService) {
        // Lifecycle management placeholder
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, conversationId, timestamp, sender, content, agentResponse, isStreaming, attachedTextFiles, attachedImageFiles
        case timelineEvents, thoughts, artifacts, agentState // Added agentState to keys
    }

    // Manual Decodable conformance
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.id = try container.decode(UUID.self, forKey: .id)
        self.conversationId = try container.decode(UUID.self, forKey: .conversationId)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.sender = try container.decode(SenderRole.self, forKey: .sender)
        self.content = try container.decode(MessageContent.self, forKey: .content)
        self.agentResponse = try container.decodeIfPresent(AgentResponse.self, forKey: .agentResponse)
        self.isStreaming = try container.decode(Bool.self, forKey: .isStreaming)
        self.attachedTextFiles = try container.decodeIfPresent([AttachedTextFile].self, forKey: .attachedTextFiles)
        self.attachedImageFiles = try container.decodeIfPresent([AttachedImageFile].self, forKey: .attachedImageFiles)
        
        self.timelineEvents = try container.decodeIfPresent([TimelineEvent].self, forKey: .timelineEvents) ?? []
        self.agentState = try container.decodeIfPresent(AgentState.self, forKey: .agentState) ?? .idle
        
        // Migration logic: If no timelineEvents but legacy data exists, reconstruct timeline
        if self.timelineEvents.isEmpty {
            let legacyThoughts = try container.decodeIfPresent([AgentThought].self, forKey: .thoughts) ?? []
            let legacyArtifacts = try container.decodeIfPresent([ToolOutput].self, forKey: .artifacts) ?? []
            
            // Note: Since we don't know the exact order of legacy data, we append thoughts then artifacts.
            // This is a one-time migration for old local data.
            self.timelineEvents = legacyThoughts.map { .thought(id: $0.id, text: $0.text) }
            self.timelineEvents.append(contentsOf: legacyArtifacts.map { .toolExecution(id: UUID(), name: $0.toolName, params: "", output: $0.output, isSuccess: $0.isSuccess, isExecuting: false) })
        }
        
        // Transient properties initialize to default
        self.thinkingHeadline = nil
        self.agentState = .idle
        self.cachedMarkdownBlocks = nil
        self.isThinkingExpanded = false
        self.pendingToolConfirmation = nil
        self.pendingClarification = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(id, forKey: .id)
        try container.encode(conversationId, forKey: .conversationId)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(sender, forKey: .sender)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(agentResponse, forKey: .agentResponse)
        try container.encode(isStreaming, forKey: .isStreaming)
        try container.encodeIfPresent(attachedTextFiles, forKey: .attachedTextFiles)
        try container.encodeIfPresent(attachedImageFiles, forKey: .attachedImageFiles)
        
        try container.encode(timelineEvents, forKey: .timelineEvents)
        try container.encode(agentState, forKey: .agentState)
        // Note: thoughts and artifacts are now computed and NOT encoded.
    }
}

// (AttachedTextFile, AttachedImageFile, MessageContent structs remain unchanged)
struct AttachedTextFile: Codable, Equatable, Identifiable {
    var id = UUID(); let name: String; let url: URL; let fileExtension: String; let content: String; let size: Int64
    static func == (lhs: AttachedTextFile, rhs: AttachedTextFile) -> Bool { return lhs.id == rhs.id && lhs.url == rhs.url }
}

struct AttachedImageFile: Codable, Equatable, Identifiable {
    var id = UUID(); let name: String; let url: URL; let fileExtension: String; let binaryData: Data; let size: Int64
    static func == (lhs: AttachedImageFile, rhs: AttachedImageFile) -> Bool { return lhs.id == rhs.id && lhs.url == rhs.url }
}

enum MessageContent: Equatable, Codable {
    case plainText(String)
    case markdownText(String)
    case codeBlock(language: String?, code: String)
    case error(title: String?, details: String)
    case image(url: URL?, alt: String?, imageData: Data?)
    case mediaArtifact(MediaArtifact)

    enum CodingKeys: String, CodingKey {
        case type, text, language, code, title, details, imageUrl, imageAlt, imageData, artifact
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "plainText":
            let text = try container.decode(String.self, forKey: .text)
            self = .plainText(text)
        case "markdownText":
            let text = try container.decode(String.self, forKey: .text)
            self = .markdownText(text)
        case "codeBlock":
            let language = try container.decodeIfPresent(String.self, forKey: .language)
            let code = try container.decode(String.self, forKey: .code)
            self = .codeBlock(language: language, code: code)
        case "error":
            let title = try container.decodeIfPresent(String.self, forKey: .title)
            let details = try container.decode(String.self, forKey: .details)
            self = .error(title: title, details: details)
        case "image":
            let urlString = try container.decodeIfPresent(String.self, forKey: .imageUrl)
            let alt = try container.decodeIfPresent(String.self, forKey: .imageAlt)
            let imageData = try container.decodeIfPresent(Data.self, forKey: .imageData)
            let url = urlString.flatMap { URL(string: $0) }
            self = .image(url: url, alt: alt, imageData: imageData)
        case "mediaArtifact":
            let artifact = try container.decode(MediaArtifact.self, forKey: .artifact)
            self = .mediaArtifact(artifact)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid MessageContent type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .plainText(let text):
            try container.encode("plainText", forKey: .type)
            try container.encode(text, forKey: .text)
        case .markdownText(let text):
            try container.encode("markdownText", forKey: .type)
            try container.encode(text, forKey: .text)
        case .codeBlock(let language, let code):
            try container.encode("codeBlock", forKey: .type)
            try container.encodeIfPresent(language, forKey: .language)
            try container.encode(code, forKey: .code)
        case .error(let title, let details):
            try container.encode("error", forKey: .type)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(details, forKey: .details)
        case .image(let url, let alt, let imageData):
            try container.encode("image", forKey: .type)
            try container.encodeIfPresent(url?.absoluteString, forKey: .imageUrl)
            try container.encodeIfPresent(alt, forKey: .imageAlt)
            try container.encodeIfPresent(imageData, forKey: .imageData)
        case .mediaArtifact(let artifact):
            try container.encode("mediaArtifact", forKey: .type)
            try container.encode(artifact, forKey: .artifact)
        }
    }

    var textContent: String? {
        switch self {
        case .plainText(let text): return text
        case .markdownText(let text): return text
        case .codeBlock(_, let code): return code
        case .error(let title, let details): return "\(title ?? "Error"): \(details)"
        case .image: return nil
        case .mediaArtifact: return nil
        }
    }
}
