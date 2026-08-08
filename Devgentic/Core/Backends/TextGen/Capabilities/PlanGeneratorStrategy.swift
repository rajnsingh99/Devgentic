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

/// What a plan-generation call produced: a usable plan, or a request to ask the
/// user ONE clarifying question first (only when the call allowed clarification).
enum PlanGenerationOutcome: Sendable {
    case plan([SubTask])
    case clarificationNeeded(question: String)
}

struct PlanGeneratorStrategy: Sendable {

    /// Planning config — provides maxSubtasks and subtaskToolFiltering.
    let planningConfig: PlanningCapabilityConfig

    init(planningConfig: PlanningCapabilityConfig = PlanningCapabilityConfig()) {
        self.planningConfig = planningConfig
    }

    // MARK: - Plan Generation

    /// - Parameter allowClarification: when true, the prompt offers the model a
    ///   `CLARIFY: <question>` escape hatch for tasks too vague to plan; the caller
    ///   raises the question as a HITL and re-plans with the answer. The re-plan
    ///   call passes false (single round — the model must then commit to a plan).
    func generatePlan(
        model: any LLMProvider,
        context: SemanticContext,
        allowClarification: Bool = false
    ) async throws -> (outcome: PlanGenerationOutcome, usage: TokenUsage) {
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

        // #16: give the planner the same framing the executor will have — the agent's
        // instructions (role/constraints) and the recent conversation history — so references
        // like "now do the same for the other folder" resolve and the plan respects the agent's
        // constraints. Both are omitted when empty, so a context-free plan call is unchanged.
        let instructionsSection: String = {
            guard let instr = context.instructions,
                  !instr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
            return "<instructions>\n\(instr)\n</instructions>\n\n"
        }()
        let historySection: String = {
            guard let history = context.recentHistory,
                  !history.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
            return "<conversation_history>\n\(history)\n</conversation_history>\n\n"
        }()
        let contextNote = (instructionsSection.isEmpty && historySection.isEmpty)
            ? ""
            : " Use the instructions and conversation history above only as context — plan steps for the task only."

        // Environment facts for the PLANNER. The execution stage already gets these,
        // but the planner did not — so plans had no anchored base path and each
        // subtask's executor independently re-guessed the location (observed live:
        // one subtask wrote to ~/Desktop, the next to ~/). Giving the planner the
        // home dir + absolute-path guidance lets it bake a consistent base directory
        // into the step text. Home is an absolute path (never a tilde) — small models
        // copy it verbatim.
        let env = context.environmentFacts
        let environmentSection = """
        <environment>
        - Home: \(env.homeDirectory)
        - Date: \(env.currentDate)
        - Paths: use absolute paths; the user's folders are under \(env.homeDirectory) (Desktop, Documents, Downloads)
        </environment>

        """

        // Pre-plan clarification the user already answered (round 2) — rendered
        // adjacent to the task so the answer shapes the plan.
        let clarificationSection: String = {
            guard let clarification = context.latestClarification else { return "" }
            return """

            <clarification>
            Q: \(clarification.query)
            A: \(clarification.response)
            </clarification>
            """
        }()

        // Clarification contract: offered only on the FIRST plan call. The re-plan
        // call (and profiles with the feature off) must commit to a plan.
        let clarifyInstruction = allowClarification
            ? "\nIf the task is too vague or ambiguous to plan concretely, do NOT guess — respond with exactly one line:\nCLARIFY: <one specific question for the user>\nOtherwise output ONLY the numbered list."
            : "\nDo not ask for clarification — make reasonable assumptions.\nOutput ONLY the numbered list."

        // Single user message — no system message. Order: context (instructions, history,
        // environment) → task (+ answered clarification) → tools → format instructions (recency).
        let prompt = instructionsSection + historySection + environmentSection + """
        <task>
        \(context.originalQuery)
        </task>
        """ + clarificationSection + """


        <tools>
        \(toolsSection)
        </tools>

        Break the task into at most \(maxSteps) numbered steps.\(contextNote)
        Each step should be one concrete action.\(bracketInstruction)\(clarifyInstruction)
        """

        let messages: [[String: String]] = [
            ["role": "user", "content": prompt]
        ]

        let (response, reportedUsage) = try await model.generateWithUsage(messages: messages, tools: nil, responseSchema: nil)
        // Prefer the provider's real token counts; fall back to a chars÷4 estimate only when
        // the provider didn't report usage (e.g. MLX), so plan generation is still counted (#10b).
        let usage = reportedUsage ?? .estimated(inputChars: prompt.count, outputChars: response.count)

        // Clarification wins ONLY when the response contains no usable plan — a model
        // that emits both a numbered list and a stray CLARIFY line planned anyway.
        if allowClarification, let question = Self.extractClarificationQuestion(from: response) {
            return (.clarificationNeeded(question: question), usage)
        }

        let availableToolNames = Set(context.availableTools.map { $0.name.lowercased() })
        let plan = parsePlan(
            from: response,
            availableToolNames: availableToolNames,
            // Fallback single-task plans must carry the REAL task, not a placeholder —
            // the subtask's description becomes the inner run's entire userInput.
            fallbackDescription: context.originalQuery
        )
        return (.plan(plan), usage)
    }

    // MARK: - Clarification Extraction

    /// Returns the model's clarifying question when the response is a `CLARIFY:` line
    /// and contains NO parseable numbered steps (a plan always wins). Nil otherwise.
    static func extractClarificationQuestion(from response: String) -> String? {
        let cleaned = OutputSanitizer.sanitize(response).cleaned
        guard !cleaned.isEmpty else { return nil }

        // A numbered list anywhere means the model planned — ignore stray CLARIFY text.
        let numberedLinePattern = #"(?m)^\s*(?:Step\s*)?\d+\s*[.):\-]\s*(.+)$"#
        if let lineRegex = try? NSRegularExpression(pattern: numberedLinePattern),
           lineRegex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) != nil {
            return nil
        }

        let clarifyPattern = #"(?im)^\s*CLARIFY\s*:\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: clarifyPattern),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let questionRange = Range(match.range(at: 1), in: cleaned)
        else { return nil }

        let question = String(cleaned[questionRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return question.isEmpty ? nil : question
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
    ///   - fallbackDescription: Description for the single-task fallback plan.
    ///     `generatePlan` passes the ORIGINAL QUERY — the generic placeholder default
    ///     produced a subtask whose inner run had no task at all (observed live:
    ///     gemma4 asked "Please provide a request so I can assist you." because the
    ///     placeholder was its entire task).
    /// - Returns: Array of parsed SubTasks (never empty).
    func parsePlan(
        from response: String,
        availableToolNames: Set<String> = [],
        fallbackDescription: String = "Complete the user's request directly"
    ) -> [SubTask] {

        // Stage 1: Sanitize — strip markdown fences, think blocks, special tokens
        let sanitized = OutputSanitizer.sanitize(response)
        let cleaned = sanitized.cleaned

        guard !cleaned.isEmpty else {
            logger.warning("Plan output is empty after sanitization. Falling back to single-task plan.")
            return [SubTask(id: "step_1", description: fallbackDescription)]
        }

        // Stage 2: Extract numbered lines
        // Handles: "1.", "1)", "1:", "1-", "Step 1:", "Step 1." and leading whitespace
        let numberedLinePattern = #"(?m)^\s*(?:Step\s*)?\d+\s*[.):\-]\s*(.+)$"#
        let lineRegex: NSRegularExpression
        do {
            lineRegex = try NSRegularExpression(pattern: numberedLinePattern, options: [])
        } catch {
            logger.error("Failed to compile numbered-line regex: \(error.localizedDescription)")
            return [SubTask(id: "step_1", description: fallbackDescription)]
        }

        let nsRange = NSRange(cleaned.startIndex..., in: cleaned)
        let matches = lineRegex.matches(in: cleaned, range: nsRange)

        guard !matches.isEmpty else {
            logger.warning("No numbered steps found in plan output. Falling back to single-task plan.")
            return [SubTask(id: "step_1", description: fallbackDescription)]
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

                // Remove the bracket suffix from the description. A tool-only step
                // ("3. [list_directory]") must not vanish — keep the bracket content
                // as the description so the plan's shape survives. (Observed live:
                // gemma4 emitted an all-tool-only plan; every description emptied and
                // the whole plan collapsed to the single-task fallback.)
                if let bracketFullRange = Range(bracketMatch.range, in: lineContent) {
                    let stripped = String(lineContent[lineContent.startIndex..<bracketFullRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    lineContent = stripped.isEmpty
                        ? bracketContent.trimmingCharacters(in: .whitespaces)
                        : stripped
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
            return [SubTask(id: "step_1", description: fallbackDescription)]
        }

        // Cap to configured max — logged for the same reason as the twin site in
        // `PlanningCapability`: a silent truncation is indistinguishable from a short plan.
        if subtasks.count > planningConfig.maxSubtasks {
            let generated = subtasks.count
            let dropped = generated - planningConfig.maxSubtasks
            subtasks = Array(subtasks.prefix(planningConfig.maxSubtasks))
            logger.warning("""
                [PLANNING] Parsed plan truncated: \(generated) subtask(s) parsed but Max Subtasks \
                is \(planningConfig.maxSubtasks). CONSEQUENCE: \(dropped) step(s) were DISCARDED \
                and will not be attempted — raise Max Subtasks if the task needs them.
                """)
        }

        logger.info("Parsed \(subtasks.count) subtask(s) from numbered list.")
        return subtasks
    }
}
