//
//  QueryRewritingService.swift
//  Devgentic
//
//  Created by Antigravity on 12/03/26.
//

import Foundation
import os

/// A service responsible for rewriting user queries to be fully self-contained
/// using the conversation history context, optimized for Vector/RAG retrieval.
actor QueryRewritingService {
    
    static let shared = QueryRewritingService()
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic", category: "QueryRewritingService")
    
    private init() {}
    
    /// Rewrites the given query if the history warrants it.
    /// Unloads the Intelligence Core model from GPU immediately after to conserve memory.
    func rewriteQuery(_ currentQuery: String, history: [ChatMessage]) async -> String {
        guard !history.isEmpty else {
            return currentQuery // Nothing to contextualize against
        }
        
        logger.notice("Initiating Contextual Query Rewriting using Intelligence Core...")
        
        let recentHistory = formatRecentHistory(history)
        
        let systemPrompt = """
        You are an expert search query rewriting assistant. Your singular task is to rewrite a user's follow-up query into a fully self-contained, descriptive search query using the provided conversation history.
        
        Rules:
        1. If the query contains pronouns or ambiguous references (e.g., "it", "that", "this function", "the model"), resolve them explicitly using the history.
        2. Do NOT answer the user's question.
        3. Do NOT include any explanations, conversational filler, or preambles.
        4. If the original query is already self-contained and clear, output the original query exactly as is.
        5. Output ONLY the raw rewritten query string and nothing else.
        """
        
        let userPrompt = """
        <conversation_history>
        \(recentHistory)
        </conversation_history>
        
        Current Query: \(currentQuery)
        
        Rewritten Query:
        """
        
        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ]
        
        do {
            let rewritten = try await IntelligenceCoreService.shared.generate(messages: messages, maxTokens: 100, temperature: 0.1)
            let cleaned = rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Clean up cache to prevent memory footprint issues
            await IntelligenceCoreService.shared.unload()
            
            if cleaned.isEmpty || cleaned.lowercased().starts(with: "i cannot") || cleaned.lowercased().starts(with: "i can't") {
                return currentQuery
            }
            
            logger.notice("Query Rewriting successful. Original: '\(currentQuery)' -> Rewritten: '\(cleaned)'")
            return cleaned
            
        } catch {
            logger.error("Failed to rewrite query via Intelligence Core: \(error.localizedDescription). Falling back to original query.")
            
            // Ensure we attempt to unload even if an error occurred during generation or tokenization
            await IntelligenceCoreService.shared.unload()
            
            return currentQuery
        }
    }
    
    private func formatRecentHistory(_ history: [ChatMessage], maxMessages: Int = 4) -> String {
        let relevant = Array(history.suffix(maxMessages))
        var formatted = ""
        for msg in relevant {
            let role = msg.sender == .user ? "User" : "Agent"
            let content = msg.content.textContent ?? "[Non-text content]"
            formatted += "\(role): \(content)\n"
        }
        return formatted
    }
}
