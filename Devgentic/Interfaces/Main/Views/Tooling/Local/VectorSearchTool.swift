//
//  VectorSearchTool.swift
//  Devgentic
//
//  Created by Raj Singh on 23/01/26.
//  Updated for Audit Consistency.
//

import Foundation
import OpenFoundationModels
import OpenFoundationModelsCore
import SwiftAgent

/// A tool that allows an Agent to perform semantic searches against the local vector database.
struct VectorSearchTool: OpenFoundationModels.Tool {
    
    struct Arguments: Codable, OpenFoundationModelsCore.ConvertibleFromGeneratedContent {
        let query: String
        
        init(_ content: OpenFoundationModelsCore.GeneratedContent) throws {
            let properties = try content.properties()
            guard let queryContent = properties["query"] else {
                throw OpenFoundationModelsCore.GeneratedContentError.missingProperty("query")
            }
            self.query = try String(queryContent)
        }
    }
    
    typealias Output = String
    
    let name = "search_knowledge_base"
    let description = "Searches the user's local documents and conversation history for relevant information."
    let conversationID: UUID?
    
    init(conversationID: UUID?) {
        self.conversationID = conversationID
    }
    
    var parameters: OpenFoundationModelsCore.GenerationSchema {
        let querySchema = OpenFoundationModelsCore.DynamicGenerationSchema(type: String.self)
        let root = OpenFoundationModelsCore.DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                OpenFoundationModelsCore.DynamicGenerationSchema.Property(
                    name: "query",
                    description: "The semantic search query.",
                    schema: querySchema,
                    isOptional: false
                )
            ]
        )
        do {
            return try OpenFoundationModelsCore.GenerationSchema(root: root, dependencies: [])
        } catch {
            fatalError("Failed to construct GenerationSchema for VectorSearchTool: \(error)")
        }
    }
    
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
            return "No relevant information found. (Audit Ref: \(logID))"
        }
        
        let resultText = results.map { "--- Context ---\n\($0.content)" }.joined(separator: "\n\n")
        return resultText + "\n(Audit Ref: \(logID))"
    }
}
