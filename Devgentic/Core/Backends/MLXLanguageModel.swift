//
//  MLXLanguageModel.swift
//  Devgentic
//
//  Created by Raj Singh on 04/02/26.
//

import Foundation
import OpenFoundationModels
import OpenFoundationModelsCore

/// An adapter that allows the Agent framework (SwiftAgent) to use the local MLX engine.
/// It conforms to the standard `LanguageModel` protocol.
public struct MLXLanguageModel: LanguageModel {
    
    // MARK: - Properties
    
    public let modelName: String
    
    // MLX models are "available" if the service is ready/loaded.
    public var isAvailable: Bool { true }
    
    // MARK: - Initialization
    
    public init(modelName: String) {
        self.modelName = modelName
    }
    
    // MARK: - LanguageModel Protocol
    
    public func supports(locale: Locale) -> Bool {
        return true // Basic assumption for LLMs
    }
    
    /// Generates a response for a single-turn prompt (non-streaming).
    public func generate(transcript: Transcript, options: GenerationOptions?) async throws -> Transcript.Entry {
        let messages = convertTranscriptToMLXMessages(transcript)
        
        var fullText = ""
        // Use default parameters or extract from options if available (e.g. options?.temperature)
        let temperature = options?.temperature ?? 0.6
        let maxTokens = options?.maximumResponseTokens ?? 2048
        
        // Await the actor method
        let stream = await MLXService.shared.streamChat(
            messages: messages,
            maxTokens: maxTokens,
            temperature: Float(temperature)
        )
        
        for try await token in stream {
            fullText += token
        }
        
        return .response(Transcript.Response(
            assetIDs: [],
            segments: [.text(Transcript.TextSegment(content: fullText))]
        ))
    }
    
    /// Streams a response based on the transcript.
    public func stream(transcript: Transcript, options: GenerationOptions?) -> AsyncThrowingStream<Transcript.Entry, Error> {
        let messages = convertTranscriptToMLXMessages(transcript)
        let temperature = options?.temperature ?? 0.6
        let maxTokens = options?.maximumResponseTokens ?? 2048
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // BUG FIX: Removed 'accumulatedText' variable.
                    // We must stream DELTAS (chunks) only, as the consumer (ChatExecutor/UI)
                    // is responsible for accumulation. Sending accumulated text here causes
                    // exponential duplication (e.g. "T", "Te", "Tes", "Test").
                    
                    // Await the actor method inside the Task
                    let tokenStream = await MLXService.shared.streamChat(
                        messages: messages,
                        maxTokens: maxTokens,
                        temperature: Float(temperature)
                    )
                    
                    for try await token in tokenStream {
                        // Yield the NEW token only
                        let entry = Transcript.Entry.response(Transcript.Response(
                            assetIDs: [],
                            segments: [.text(Transcript.TextSegment(content: token))]
                        ))
                        continuation.yield(entry)
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Private Helpers
    
    /// Converts the Agent framework's `Transcript` into the simpler dictionary format used by MLX.
    private func convertTranscriptToMLXMessages(_ transcript: Transcript) -> [[String: String]] {
        var messages: [[String: String]] = []
        
        // FIX: Iterate over 'transcript' directly instead of 'transcript.entries'
        // 'entries' is package-private, but Transcript conforms to Collection/Sequence
        for entry in transcript {
            switch entry {
            case .instructions(let instructions):
                // System Prompt
                let text = instructions.segments.compactMap { segment -> String? in
                    if case .text(let t) = segment { return t.content }
                    return nil
                }.joined(separator: "\n")
                
                if !text.isEmpty {
                    messages.append(["role": "system", "content": text])
                }
                
            case .prompt(let prompt):
                // User Message
                let text = prompt.segments.compactMap { segment -> String? in
                    if case .text(let t) = segment { return t.content }
                    return nil
                }.joined(separator: "\n")
                
                messages.append(["role": "user", "content": text])
                
            case .response(let response):
                // Assistant Message
                let text = response.segments.compactMap { segment -> String? in
                    if case .text(let t) = segment { return t.content }
                    return nil
                }.joined(separator: "\n")
                
                messages.append(["role": "assistant", "content": text])
                
            case .toolCalls, .toolOutput:
                // MLX implementation primarily handles text chat.
                // Tool calls/outputs are usually embedded in the prompt text by the ReAct loop
                // before reaching this layer, or they are ignored for pure chat models.
                break
            }
        }
        
        return messages
    }
}
