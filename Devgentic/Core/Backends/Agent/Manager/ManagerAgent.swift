//
//  ManagerAgent.swift
//  Devgentic
//
//  Created by Raj Singh
//

import Foundation
import OpenFoundationModels
import OpenFoundationModelsCore

actor ManagerAgent {
    
    private let model: any LanguageModel
    
    // Dependencies (Singleton access for RAG retrieval)
    private let vectorStore = VectorStoreService.shared
    private let embeddingService = EmbeddingService.shared
    
    init(model: any LanguageModel) {
        self.model = model
    }
    
    // MARK: - 1. New Plan Generation (The Architect)
    // Updates:
    // 1. Accepts chatHistory/conversationID for Hybrid Context.
    // 2. Prompts the model to populate 'contextBrief'.
    func generatePlan(
        userRequest: String,
        chatHistory: [ChatMessage],
        conversationID: UUID
    ) async throws -> ExecutionPlan {
        
        let session = LanguageModelSession(model: model, tools: [], instructions: nil as String?)
        
        // --- STEP 1: SHORT-TERM MEMORY (Sliding Window) ---
        // Get the last 6 messages to provide immediate conversational context.
        let windowSize = 6
        let recentMessages = chatHistory
            .filter { if case .error = $0.content { return false }; return true }
            .suffix(windowSize)
        
        var shortTermMemory = ""
        if !recentMessages.isEmpty {
            shortTermMemory = "## SHORT-TERM MEMORY (RECENT CHAT)\n"
            for msg in recentMessages {
                let role = (msg.sender == .user) ? "User" : "Assistant"
                let content = msg.content.textContent ?? "[Non-text content]"
                shortTermMemory += "- **\(role)**: \(content)\n"
            }
        }
        
        // --- STEP 2: LONG-TERM MEMORY (RAG / Vector Search) ---
        var longTermMemory = ""
        
        // Generate embedding for the specific user request to find relevant history
        if let queryEmbedding = await embeddingService.generateEmbedding(for: userRequest) {
            let relevantChunks = vectorStore.findNearest(
                to: queryEmbedding,
                limit: 3,
                conversationID: conversationID
            )
            
            if !relevantChunks.isEmpty {
                longTermMemory = "## LONG-TERM MEMORY (RELEVANT KNOWLEDGE)\n"
                for (index, chunk) in relevantChunks.enumerated() {
                    longTermMemory += "Context \(index + 1): \(chunk.content)\n\n"
                }
            }
        }
        
        // --- STEP 3: CURATED PROMPT CONSTRUCTION ---
        let promptText = """
        You are the **MacOS System Architect**. Analyze the request and create a safe ExecutionPlan.
        
        ## RULES
        1. **Syntax Check**: Scan specifically for filesystem hazards (newlines '\\n', unescaped backslashes).
        2. **Atomicity**: Break complex tasks into small, sequential steps.
        3. **Ambiguity**: If a user request is unsafe, mark the step as `isAmbiguous: true` and set `requiresUserConfirmation: true`.
        
        ## CONTEXT CURATION (CRITICAL)
        The Executor Agent has NO MEMORY of the past. You must provide it with a `contextBrief`.
        - **Look at the Memory provided below.**
        - Extract **ONLY** the specific variables, file paths, PIDs, or status codes that are relevant to *this specific request*.
        - **FILTER OUT** unrelated previous tasks (e.g., if the user asks for "cleanup", ignore previous "network speed" tasks).
        - If this is a new, unrelated task, the `contextBrief` should be: "Starting fresh task."
        
        \(longTermMemory)
        
        \(shortTermMemory)
        
        ## CURRENT INPUT
        "\(userRequest)"
        """
        
        // --- STEP 4: GENERATION ---
        let response = try await session.respond(to: promptText, generating: ExecutionPlan.self)
        return response.content
    }
    
    // MARK: - 2. Plan Patching (The Repairman)
    func patchPlan(currentPlan: ExecutionPlan, userCorrection: String) async throws -> ExecutionPlan {
        let session = LanguageModelSession(model: model, tools: [], instructions: nil as String?)
        
        // 1. Identify the SPECIFIC blocked step
        let blockedStep = currentPlan.steps.first(where: { $0.isAmbiguous })
        let blockedStepID = blockedStep?.id ?? 1
        let blockageReason = blockedStep?.clarificationQuestion ?? "Ambiguity detected."

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let planData = try encoder.encode(currentPlan)
        let planString = String(data: planData, encoding: .utf8) ?? "{}"
        
        // 2. Dynamic Prompting
        // We instruct the repairman to also update the contextBrief if the correction reveals new context.
        let promptText = """
        You are the **Plan Repair Architect**.
        
        ## STATUS
        The ExecutionPlan is PAUSED because **Step \(blockedStepID)** is ambiguous.
        We asked the user: "\(blockageReason)"
        
        ## USER RESPONSE
        "\(userCorrection)"
        
        ## TASK
        1. **TARGET STEP \(blockedStepID) ONLY**: Apply the user's correction to Step \(blockedStepID).
        2. **UPDATE BRIEF**: If the user provided new details (like a file path), append them to the `contextBrief`.
        3. If the correction resolves the issue, set `isAmbiguous` to `false`.
        
        ## CURRENT PLAN JSON
        \(planString)
        
        ## OUTPUT
        Return the fully updated ExecutionPlan JSON.
        """
        
        let response = try await session.respond(to: promptText, generating: ExecutionPlan.self)
        return response.content
    }
}
