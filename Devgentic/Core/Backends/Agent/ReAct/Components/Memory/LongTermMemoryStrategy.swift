//
//  LongTermMemoryStrategy.swift
//  Devgentic
//
//  Created by Raj Singh on 11/03/26.
//

import Foundation
/// Defines how long-term grounding and capabilities are exposed.
protocol LongTermMemoryStrategy: Sendable {
    /// The deep-memory tools exposed to the LLM (if any).
    var memoryCapabilities: [AgentTool] { get }
    
    /// The pre-fetched static facts to be injected into the prompt.
    func getStaticGrounding() -> String
}

// MARK: - Concrete Implementations

/// For 8B Models: No agency. Fully reliant on pre-fetched RAG and the immediate Sliding Window.
struct StaticGroundingMemory: LongTermMemoryStrategy {
    let ragContext: String
    
    // Zero memory tools exposed. The agent cannot query the database.
    var memoryCapabilities: [AgentTool] { return [] }
    
    func getStaticGrounding() -> String { return ragContext }
}

/// For 70B+ Models: High agency. Given tools to actively search historical databases.
struct ToolAugmentedMemory: LongTermMemoryStrategy {
    let ragContext: String
    let memoryTools: [AgentTool]
    
    var memoryCapabilities: [AgentTool] { return memoryTools }
    
    func getStaticGrounding() -> String { return ragContext }
}
