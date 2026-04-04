//
//  CallAgentTool.swift
//  Devgentic
//
//  Agent delegation tool: allows an LLM to delegate subtasks to inline sub-agents.
//  Sub-agents are leaf nodes — they run plain ReAct with their own model/tools/instructions
//  but have NO capabilities and NO call_agent tool, so they cannot delegate further.
//
//  Created during the Agent Capabilities Migration.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "CallAgentTool")

enum CallAgentTool {

    /// Creates the `call_agent` AgentTool for injection into the parent agent's tool set.
    ///
    /// - Parameters:
    ///   - config: Delegation configuration containing inline sub-agent definitions.
    ///   - agentConnect: The AgentConnect instance for model initialization and tool resolution.
    ///   - conversationID: Current conversation for context propagation.
    static func create(
        config: AgentDelegationConfig,
        agentConnect: AgentConnect,
        conversationID: UUID
    ) -> AgentTool {

        // Build dynamic description listing available sub-agents
        let subAgentList = config.subAgents
            .map { "- \"\($0.name)\": \($0.purpose)" }
            .joined(separator: "\n")

        let parameters = ToolParameters(
            type: "object",
            properties: [
                "agent_name": ToolParameterProperty(
                    type: "string",
                    description: "Name of the sub-agent to delegate to. Must be one of the available sub-agents listed in this tool's description.",
                    items: nil
                ),
                "task": ToolParameterProperty(
                    type: "string",
                    description: "Clear description of the subtask to delegate to the sub-agent.",
                    items: nil
                )
            ],
            required: ["agent_name", "task"]
        )

        return AgentTool(
            name: "call_agent",
            description: """
                Delegate a subtask to a specialist sub-agent. Use when the task requires \
                specialist expertise you don't have.
                Available sub-agents:
                \(subAgentList.isEmpty ? "(none configured)" : subAgentList)
                """,
            parameters: parameters,
            requiresConfirmation: false,
            run: { data in
                // Parse arguments
                guard let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let agentName = args["agent_name"] as? String,
                      let taskDescription = args["task"] as? String
                else {
                    return (output: "Error: call_agent requires 'agent_name' (string) and 'task' (string) parameters.", artifacts: [])
                }

                // Find the sub-agent by name (case-insensitive)
                guard let subAgent = config.subAgents.first(where: {
                    $0.name.lowercased() == agentName.lowercased()
                }) else {
                    let available = config.subAgents.map(\.name).joined(separator: ", ")
                    return (
                        output: "Sub-agent '\(agentName)' not found. Available sub-agents: \(available.isEmpty ? "(none configured)" : available)",
                        artifacts: []
                    )
                }

                logger.info("Delegating to sub-agent '\(subAgent.name)': \(taskDescription.prefix(100))")

                do {
                    // Initialize sub-agent's model
                    let model = try await agentConnect.initializeModel(config: subAgent.llmConfig, isBotFlow: false)

                    // Resolve sub-agent's tools (NO system tools, NO call_agent — leaf node)
                    let resolvedTools = await agentConnect.resolveSubAgentTools(
                        profileTools: subAgent.tools,
                        conversationID: conversationID
                    )

                    // Resolve cognitive generator for the sub-agent's dialect
                    let generator = agentConnect.resolveCognitiveGeneratorForSubAgent(
                        llmConfig: subAgent.llmConfig,
                        tools: resolvedTools
                    )

                    // Build AgentInput — minimal, no memory, no history
                    let traceContext = TraceContext(subAgentName: subAgent.name, provider: subAgent.llmConfig.apiProvider)
                    let input = AgentInput(
                        userInput: taskDescription,
                        chatHistory: [],
                        conversationID: conversationID,
                        tools: resolvedTools,
                        longTermMemory: StaticGroundingMemory(ragContext: ""),
                        generatorStrategy: generator,
                        rateLimitCategory: agentConnect.rateLimitCategory(for: subAgent.llmConfig.apiProvider),
                        instructions: subAgent.instructions,
                        traceContext: traceContext
                    )

                    // Run plain ReAct — NO capabilities, NO call_agent
                    let executor = ReActAgentExecutor(maxIterations: subAgent.maxIterations)
                    let stream = executor.execute(model: model, input: input) { _ in }

                    var output = ""
                    var artifacts: [MediaArtifact] = []

                    for try await event in stream {
                        switch event {
                        case .content(let text):
                            output += text
                        case .artifactProduced(let artifact):
                            artifacts.append(artifact)
                        default:
                            break
                        }
                    }

                    logger.info("Sub-agent '\(subAgent.name)' completed. Output length: \(output.count)")

                    return (
                        output: output.isEmpty ? "Sub-agent completed the task but produced no output." : output,
                        artifacts: artifacts
                    )
                } catch {
                    logger.error("Sub-agent '\(subAgent.name)' failed: \(error.localizedDescription)")
                    return (output: "Sub-agent '\(subAgent.name)' failed: \(error.localizedDescription)", artifacts: [])
                }
            }
        )
    }
}
