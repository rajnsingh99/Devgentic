//
//  VectorSearchTool.swift
//  Devgentic
//
//  Updated for Audit Consistency and Hallucination Prevention.
//  MIGRATION: Updated to native DevgenticTool protocol.
//

import Foundation

/// A tool that allows an Agent to perform semantic searches against the local vector database.
struct VectorSearchTool: DevgenticTool {
    
    // MARK: - Properties
    
    let name = "recall_conversation_history"
    
    let description = "Performs a semantic search against local conversation history and uploaded documents to recall past context."
    
    let conversationID: UUID?
    
    init(conversationID: UUID?) {
        self.conversationID = conversationID
    }
    
    // MARK: - Type Definitions
    
    struct Arguments: Decodable, Sendable {
        let query: String
        
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            
            var foundQuery: String? = nil
            let keys = ["query", "search", "keyword", "text", "search_term", "searchTerm"]
            
            for key in keys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundQuery = val
                    break
                }
            }
            
            guard let validQuery = foundQuery else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Missing property 'query'. Checked aliases: \(keys.joined(separator: ", "))"
                    )
                )
            }
            
            self.query = validQuery
        }
    }
    
    // MARK: - Schema
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("query", "string", "The semantic search query.")
            ],
            required: ["query"]
        )
    }
    
    // MARK: - Execution
    
    func call(arguments: Arguments) async throws -> String {
        // --- LOGGING INSTRUMENTATION ---
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Semantic Search: '\(arguments.query)'",
            operations: [
                ["query": arguments.query]
            ]
        )
        // -------------------------------
        
        let query = arguments.query
        
        guard let embedding = await EmbeddingService.shared.generateEmbedding(for: query) else {
            return "Error: Could not generate embedding for query. (Audit Ref: \(logID))"
        }
        
        let results = VectorStoreService.shared.findNearest(
            to: embedding,
            limit: 3,
            conversationID: conversationID
        )
        
        if results.isEmpty {
            return "No relevant information found in local history. (Audit Ref: \(logID))"
        }
        
        let resultText = results.map { "--- Context ---\n\($0.fullTextContent)" }.joined(separator: "\n\n")
        return resultText + "\n(Audit Ref: \(logID))"
    }
}
