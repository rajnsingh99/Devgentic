//
//  PlanGeneratorStrategy.swift
//  Devgentic
//
//  Prompts the LLM to decompose a user query into an ordered array of SubTasks.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "PlanGenerator")

struct PlanGeneratorStrategy: Sendable {

    // MARK: - Plan Generation

    func generatePlan(
        model: any LLMProvider,
        context: SemanticContext
    ) async throws -> [SubTask] {
        let toolsList = context.availableTools.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")

        let systemPrompt = """
        You are a task planning assistant. Given a user request and a set of available tools, decompose the request into an ordered sequence of concrete subtasks.

        Available tools:
        \(toolsList)

        Output ONLY a JSON array of subtask objects. Each subtask has:
        - "id": a unique string identifier (use "step_1", "step_2", etc.)
        - "description": a clear, actionable description of what this step should accomplish
        - "toolHint": (optional) the name of the tool most likely needed
        - "dependsOn": (optional) array of step IDs that must complete first

        Rules:
        - Keep the plan concise (2-6 steps for most tasks)
        - Each step should map to 1-2 tool calls
        - Order steps logically based on data dependencies
        - Do NOT include steps that don't require tool usage unless they synthesize results

        Respond with ONLY the JSON array, no markdown fences or explanation.
        """

        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": context.originalQuery]
        ]

        let response = try await model.generate(messages: messages, tools: nil, responseSchema: nil)
        return parsePlan(from: response)
    }

    // MARK: - Parsing

    func parsePlan(from response: String) -> [SubTask] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try direct JSON decode
        if let tasks = decodeSubTasks(from: trimmed) {
            return tasks
        }

        // Try extracting JSON from markdown code blocks
        if let jsonRange = trimmed.range(of: "\\[\\s*\\{", options: .regularExpression),
           let endRange = trimmed.range(of: "\\]", options: .regularExpression, range: jsonRange.lowerBound..<trimmed.endIndex) {
            let extracted = String(trimmed[jsonRange.lowerBound...endRange.lowerBound])
            if let tasks = decodeSubTasks(from: extracted) {
                return tasks
            }
        }

        // Fallback: single task wrapping the original query
        logger.warning("Failed to parse plan JSON. Falling back to single-task plan.")
        return [SubTask(id: "step_1", description: "Complete the user's request directly")]
    }

    private func decodeSubTasks(from json: String) -> [SubTask]? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode([SubTask].self, from: data)
    }
}
