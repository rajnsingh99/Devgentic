//
//  PlanGeneratorStrategy.swift
//  Devgentic
//
//  Prompts the LLM to decompose a user query into an ordered list of SubTasks.
//
//  Output format: Numbered list (universal across model sizes).
//  Tool hints: Optional inline [bracket] notation, validated against the tool registry.
//
//  Migrated from JSON array output during the Planner Resilience Migration.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "PlanGenerator")

struct PlanGeneratorStrategy: Sendable {

    /// Planning config — provides maxSubtasks and subtaskToolFiltering.
    let planningConfig: PlanningCapabilityConfig

    init(planningConfig: PlanningCapabilityConfig = PlanningCapabilityConfig()) {
        self.planningConfig = planningConfig
    }

    // MARK: - Plan Generation

    func generatePlan(
        model: any LLMProvider,
        context: SemanticContext
    ) async throws -> [SubTask] {
        let maxSteps = planningConfig.maxSubtasks
        let toolFilteringEnabled = planningConfig.subtaskToolFiltering

        // Build tool list section — format depends on whether tool filtering is enabled.
        // Filtering ON:  "- name: brief description" (model needs context to assign tools)
        // Filtering OFF: "name1, name2, name3"       (model just needs to know what's possible)
        let toolsSection: String
        if toolFilteringEnabled {
            let toolLines = context.availableTools
                .map { "- \($0.name): \($0.description)" }
                .joined(separator: "\n")
            toolsSection = toolLines
        } else {
            toolsSection = context.availableTools.map(\.name).joined(separator: ", ")
        }

        // Build the bracket instruction (only when tool filtering is enabled)
        let bracketInstruction = toolFilteringEnabled
            ? "\nIf a step maps to specific tools, add their names in [brackets] at the end."
            : ""

        // Single user message — no system message.
        // Attention-optimized: task (primacy) → tools (middle) → format instructions (recency).
        let prompt = """
        <task>
        \(context.originalQuery)
        </task>

        <tools>
        \(toolsSection)
        </tools>

        Break this into at most \(maxSteps) numbered steps.
        Each step should be one concrete action.\(bracketInstruction)
        Output ONLY the numbered list.
        """

        let messages: [[String: String]] = [
            ["role": "user", "content": prompt]
        ]

        let response = try await model.generate(messages: messages, tools: nil, responseSchema: nil)

        let availableToolNames = Set(context.availableTools.map { $0.name.lowercased() })
        return parsePlan(from: response, availableToolNames: availableToolNames)
    }

    // MARK: - Numbered List Parser

    /// Parses a numbered-list LLM response into SubTask array.
    ///
    /// Parse stages:
    ///   1. Sanitize (OutputSanitizer — strips fences, think blocks, special tokens)
    ///   2. Extract numbered lines (handles 1., 1), 1:, 1- variations)
    ///   3. Extract tool brackets [tool1, tool2] from each line
    ///   4. Validate tool names against available registry (discard hallucinated)
    ///   5. Build SubTask array
    ///   6. Fallback to single-task if zero steps parsed
    ///
    /// - Parameters:
    ///   - response: Raw LLM output text.
    ///   - availableToolNames: Lowercased set of valid tool names for validation.
    /// - Returns: Array of parsed SubTasks (never empty).
    func parsePlan(from response: String, availableToolNames: Set<String> = []) -> [SubTask] {

        // Stage 1: Sanitize — strip markdown fences, think blocks, special tokens
        let sanitized = OutputSanitizer.sanitize(response)
        let cleaned = sanitized.cleaned

        guard !cleaned.isEmpty else {
            logger.warning("Plan output is empty after sanitization. Falling back to single-task plan.")
            return [SubTask(id: "step_1", description: "Complete the user's request directly")]
        }

        // Stage 2: Extract numbered lines
        // Handles: "1.", "1)", "1:", "1-", "Step 1:", "Step 1." and leading whitespace
        let numberedLinePattern = #"(?m)^\s*(?:Step\s*)?\d+\s*[.):\-]\s*(.+)$"#
        let lineRegex: NSRegularExpression
        do {
            lineRegex = try NSRegularExpression(pattern: numberedLinePattern, options: [])
        } catch {
            logger.error("Failed to compile numbered-line regex: \(error.localizedDescription)")
            return [SubTask(id: "step_1", description: "Complete the user's request directly")]
        }

        let nsRange = NSRange(cleaned.startIndex..., in: cleaned)
        let matches = lineRegex.matches(in: cleaned, range: nsRange)

        guard !matches.isEmpty else {
            logger.warning("No numbered steps found in plan output. Falling back to single-task plan.")
            return [SubTask(id: "step_1", description: "Complete the user's request directly")]
        }

        // Stage 3 + 4 + 5: Parse each line → extract brackets → validate → build SubTask
        let bracketPattern = #"\[([^\]]+)\]\s*$"#
        let bracketRegex = try? NSRegularExpression(pattern: bracketPattern, options: [])

        var subtasks: [SubTask] = []

        for (index, match) in matches.enumerated() {
            guard let contentRange = Range(match.range(at: 1), in: cleaned) else { continue }
            var lineContent = String(cleaned[contentRange]).trimmingCharacters(in: .whitespaces)

            // Stage 3: Extract tool brackets
            var validatedHints: [String]? = nil

            if let bracketRegex,
               let bracketMatch = bracketRegex.firstMatch(in: lineContent, range: NSRange(lineContent.startIndex..., in: lineContent)),
               let bracketContentRange = Range(bracketMatch.range(at: 1), in: lineContent) {

                let bracketContent = String(lineContent[bracketContentRange])
                let rawHints = bracketContent
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }

                // Stage 4: Validate against available tool registry
                var validated: [String] = []
                for hint in rawHints {
                    if availableToolNames.contains(hint.lowercased()) {
                        validated.append(hint)
                    } else {
                        logger.warning("Discarding unknown tool hint '\(hint)' in step \(index + 1).")
                    }
                }

                validatedHints = validated.isEmpty ? nil : validated

                // Remove the bracket suffix from the description
                if let bracketFullRange = Range(bracketMatch.range, in: lineContent) {
                    lineContent = String(lineContent[lineContent.startIndex..<bracketFullRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                }
            }

            // Stage 5: Build SubTask
            let stepID = "step_\(index + 1)"
            let description = lineContent.trimmingCharacters(in: .whitespaces)

            guard !description.isEmpty else { continue }

            subtasks.append(SubTask(
                id: stepID,
                description: description,
                toolHints: validatedHints
            ))
        }

        // Stage 6: Fallback
        guard !subtasks.isEmpty else {
            logger.warning("All parsed steps had empty descriptions. Falling back to single-task plan.")
            return [SubTask(id: "step_1", description: "Complete the user's request directly")]
        }

        // Cap to configured max
        if subtasks.count > planningConfig.maxSubtasks {
            subtasks = Array(subtasks.prefix(planningConfig.maxSubtasks))
        }

        logger.info("Parsed \(subtasks.count) subtask(s) from numbered list.")
        return subtasks
    }
}
