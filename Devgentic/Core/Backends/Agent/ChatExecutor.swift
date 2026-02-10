//
//  ChatExecutor.swift
//  Devgentic
//
//  Created by Raj Singh on 07/02/26.
//

import Foundation
import SwiftAgent
import OpenFoundationModels
import OpenFoundationModelsCore
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ChatExecutor")

/// A lightweight executor for direct "Bot" interactions.
/// Unlike the ReActAgentExecutor, this does not loop, reason, or use tools.
/// It simply constructs a transcript and streams the model's response.
actor ChatExecutor: AgentExecutor {
    
    // MARK: - Properties
    
    // We default to ReAct or a generic type since this executor doesn't strictly follow an agentic architecture.
    // This satisfies the protocol requirement.
    nonisolated let architecture: AgentArchitecture = .reAct
    
    // MARK: - Execution Entry Point
    
    nonisolated func execute(
        model: any OpenFoundationModels.LanguageModel,
        input: AgentInput,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) -> AsyncThrowingStream<String, Error> {
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // 1. Trace: Start (UI Feedback)
                    // We map the "Chat" state to "Thinking" so the UI shows activity.
                    let traceSpan = input.traceContext.newSpan()
                    
                    onTraceUpdate(AgentTraceLog(
                        traceID: traceSpan.traceID,
                        spanID: traceSpan.spanID,
                        parentSpanID: traceSpan.parentSpanID,
                        stepNumber: 0,
                        state: .thinking,
                        content: "Preparing response..."
                    ))
                    
                    // 2. Construct Transcript
                    // We combine instructions, RAG context, history, and the user query.
                    let transcript = self.buildTranscript(input: input)
                    
                    // 3. Stream Response
                    // Fix: Use correct 'stream' method from LanguageModel protocol
                    // Returns AsyncThrowingStream<Transcript.Entry, Error>
                    let entryStream = model.stream(transcript: transcript, options: nil)
                    
                    for try await entry in entryStream {
                        switch entry {
                        case .response(let response):
                            // Extract text content from the response segments
                            for segment in response.segments {
                                switch segment {
                                case .text(let textSegment):
                                    continuation.yield(textSegment.content)
                                case .structure(let structuredSegment):
                                    continuation.yield(structuredSegment.content.text)
                                }
                            }
                        default:
                            // We ignore tool calls or other entry types for simple Chat execution
                            break
                        }
                    }
                    
                    // 4. Trace: End
                    onTraceUpdate(AgentTraceLog(
                        traceID: traceSpan.traceID,
                        spanID: traceSpan.spanID,
                        parentSpanID: traceSpan.parentSpanID,
                        stepNumber: 1,
                        state: .finalizing,
                        content: "Response Complete"
                    ))
                    
                    continuation.finish()
                    
                } catch {
                    logger.error("ChatExecutor Error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    nonisolated private func buildTranscript(input: AgentInput) -> OpenFoundationModels.Transcript {
        var entries: [OpenFoundationModels.Transcript.Entry] = []
        
        // A. System Instructions / RAG Context
        var systemTextParts: [String] = []
        
        if let instructions = input.instructions, !instructions.isEmpty {
            systemTextParts.append(instructions)
        }
        
        // If RAG context is present, we inject it into the system prompt or as a preamble.
        // For Bots, we typically prepend it to ensure adherence.
        if let ragContext = input.ragContext, !ragContext.isEmpty {
            let contextBlock = """
            ### CONTEXT FROM KNOWLEDGE BASE
            \(ragContext)
            ### END CONTEXT
            (Please use the context above if relevant to answer the following question)
            """
            systemTextParts.append(contextBlock)
        }
        
        if !systemTextParts.isEmpty {
            let combinedSystem = systemTextParts.joined(separator: "\n\n")
            entries.append(.instructions(OpenFoundationModels.Transcript.Instructions(
                segments: [.text(OpenFoundationModels.Transcript.TextSegment(content: combinedSystem))],
                toolDefinitions: []
            )))
        }
        
        // B. Chat History
        for msg in input.chatHistory {
            guard let text = msg.content.textContent else { continue }
            if msg.sender == .user {
                entries.append(.prompt(OpenFoundationModels.Transcript.Prompt(segments: [.text(OpenFoundationModels.Transcript.TextSegment(content: text))])))
            } else {
                entries.append(.response(OpenFoundationModels.Transcript.Response(assetIDs: [], segments: [.text(OpenFoundationModels.Transcript.TextSegment(content: text))])))
            }
        }
        
        // C. Current User Input
        // Note: Some models expect the last entry to be the user prompt.
        entries.append(.prompt(OpenFoundationModels.Transcript.Prompt(segments: [.text(OpenFoundationModels.Transcript.TextSegment(content: input.userInput))])))
        
        return OpenFoundationModels.Transcript(entries: entries)
    }
}
