//
//  VectorSearchTool.swift
//  Devgentic
//
//  Created by Devgentic AI on 23/01/26.
//

import Foundation
import OpenFoundationModels
import OpenFoundationModelsCore
import SwiftAgent

/// A tool that allows an Agent to perform semantic searches against the local vector database.
struct VectorSearchTool: OpenFoundationModels.Tool {
    
    // MARK: - Type Definitions
    
    // Explicitly namespace the protocol to resolve ambiguity
    struct Arguments: Codable, OpenFoundationModelsCore.ConvertibleFromGeneratedContent {
        let query: String
        
        // Explicitly namespace GeneratedContent
        init(_ content: OpenFoundationModelsCore.GeneratedContent) throws {
            // 1. Extract properties from the generated content
            let properties = try content.properties()
            
            // 2. Validate and extract 'query'
            guard let queryContent = properties["query"] else {
                // Explicitly namespace the error type
                throw OpenFoundationModelsCore.GeneratedContentError.missingProperty("query")
            }
            
            // 3. Convert the inner content to String
            self.query = try String(queryContent)
        }
    }
    
    typealias Output = String
    
    // MARK: - Properties
    
    let name = "search_knowledge_base"
    let description = "Searches the user's local documents and conversation history for relevant information."
    let conversationID: UUID?
    
    // MARK: - Initialization
    
    init(conversationID: UUID?) {
        self.conversationID = conversationID
    }
    
    // MARK: - Schema
    
    // Explicitly namespace GenerationSchema
    var parameters: OpenFoundationModelsCore.GenerationSchema {
        // Create the schema using DynamicGenerationSchema
        
        // 1. Define the 'query' property schema (String)
        let querySchema = OpenFoundationModelsCore.DynamicGenerationSchema(
            type: String.self
        )
        
        // 2. Define the root object schema
        let root = OpenFoundationModelsCore.DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                OpenFoundationModelsCore.DynamicGenerationSchema.Property(
                    name: "query",
                    description: "The semantic search query used to find relevant context in the database.",
                    schema: querySchema,
                    isOptional: false
                )
            ]
        )
        
        // 3. Convert to GenerationSchema
        do {
            return try OpenFoundationModelsCore.GenerationSchema(root: root, dependencies: [])
        } catch {
            fatalError("Failed to construct GenerationSchema for VectorSearchTool: \(error)")
        }
    }
    
    // MARK: - Execution
    
    func call(arguments: Arguments) async throws -> String {
        let query = arguments.query
        
        guard let embedding = await EmbeddingService.shared.generateEmbedding(for: query) else {
            return "Error: Could not generate embedding for query."
        }
        
        let results = VectorStoreService.shared.findNearest(
            to: embedding,
            limit: 3,
            conversationID: conversationID
        )
        
        if results.isEmpty {
            return "No relevant information found."
        }
        
        return results.map { "--- Context ---\n\($0.content)" }.joined(separator: "\n\n")
    }
}
