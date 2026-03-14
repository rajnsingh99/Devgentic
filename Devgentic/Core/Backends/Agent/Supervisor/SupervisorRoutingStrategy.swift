//
//  SupervisorRoutingStrategy.swift
//  Devgentic
//
//  Prompts the LLM to decompose a user query into specialized worker assignments.
//  Each worker is assigned a role, instruction, and subset of available tools.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "SupervisorRouter")

struct SupervisorRoutingStrategy: Sendable {

    func route(
        query: String,
        availableTools: [AgentTool],
        model: any LLMProvider,
        context: SemanticContext
    ) async throws -> [WorkerTask] {

        let toolsList = availableTools.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")

        let systemPrompt = """
        You are a task supervisor. Decompose the user's request into specialized worker tasks.
        Each worker has a specific role and uses a subset of the available tools.

        Available tools:
        \(toolsList)

        Output ONLY a JSON array of worker assignments (no markdown fences):
        [
            {
                "workerRole": "researcher",
                "instruction": "Clear instruction for this worker",
                "toolNames": ["tool_name_1", "tool_name_2"]
            }
        ]

        Rules:
        - Create 1-4 workers depending on task complexity
        - Each worker should have a distinct role (e.g., "researcher", "executor", "analyst")
        - Assign only relevant tools to each worker
        - Simple tasks may need just 1 worker
        - Each instruction should be self-contained and actionable
        """

        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": query]
        ]

        let response = try await model.generate(messages: messages, tools: nil, responseSchema: nil)
        return parseWorkerTasks(from: response, availableTools: availableTools)
    }

    // MARK: - Parsing

    private func parseWorkerTasks(from response: String, availableTools: [AgentTool]) -> [WorkerTask] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try direct JSON decode
        if let tasks = decodeWorkers(from: trimmed, availableTools: availableTools) {
            return tasks
        }

        // Try extracting from markdown code blocks
        let cleaned = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let tasks = decodeWorkers(from: cleaned, availableTools: availableTools) {
            return tasks
        }

        // Fallback: single worker with all tools
        logger.warning("Failed to parse worker routing. Falling back to single worker.")
        return [WorkerTask(
            workerRole: "general",
            instruction: "Complete the user's request using available tools.",
            assignedTools: availableTools
        )]
    }

    private func decodeWorkers(from json: String, availableTools: [AgentTool]) -> [WorkerTask]? {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        let toolLookup = Dictionary(uniqueKeysWithValues: availableTools.map { ($0.name, $0) })

        var workers: [WorkerTask] = []
        for item in array {
            guard let role = item["workerRole"] as? String,
                  let instruction = item["instruction"] as? String else { continue }

            let toolNames = item["toolNames"] as? [String] ?? []
            let assignedTools = toolNames.compactMap { toolLookup[$0] }

            // If no valid tools matched, give all tools (graceful degradation)
            let finalTools = assignedTools.isEmpty ? availableTools : assignedTools

            workers.append(WorkerTask(
                workerRole: role,
                instruction: instruction,
                assignedTools: finalTools
            ))
        }

        return workers.isEmpty ? nil : workers
    }
}
