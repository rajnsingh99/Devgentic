//
//  ParseOutcome.swift
//  Devgentic
//
//  Two distinct parse-related types live here:
//
//  1. `ParseConfidence` — internal to `CognitiveParsePipeline`. A stage-level
//     confidence signal used by `classifyOutcome` to decide whether drift
//     detection and fallback stages should fire. Not carried on the step.
//
//  2. `ParseOutcome` — carried on `ModernCognitiveStep`. The terminator and
//     executor pattern-match on this to distinguish genuine completion from
//     parse failure, and to build targeted corrective alerts per failure mode.
//
//  3. `ParseFailureReason` — typed causes of parse failure, each carrying
//     enough context to build both a UI chip and a model-directed retry alert.
//
//  Created by Raj Singh on 10/03/26.
//

import Foundation

// MARK: - Parse Confidence (Pipeline-Internal)

/// Internal to `CognitiveParsePipeline`: classifies whether a stage's result
/// warrants running subsequent fallback stages. Not exposed on the step.
enum ParseConfidence: Sendable {

    /// Stage produced a high-confidence result. Pipeline returns it directly.
    case confident(ModernCognitiveStep)

    /// Stage produced a result but extraction may be incomplete. Pipeline continues
    /// to drift detection and fallback parsing.
    case degraded(ModernCognitiveStep)

    /// Stage could not extract any meaningful structure.
    case failed

    /// Extracts the `ModernCognitiveStep` regardless of confidence tier.
    var step: ModernCognitiveStep? {
        switch self {
        case .confident(let s), .degraded(let s): return s
        case .failed: return nil
        }
    }

    var isConfident: Bool {
        if case .confident = self { return true }
        return false
    }
}

// MARK: - Parse Outcome (Step-Level)

/// The verdict the parser/pipeline renders about a single LLM response.
/// Carried on `ModernCognitiveStep` so the terminator and executor can tell
/// apart the three semantically distinct "zero tool calls" situations.
enum ParseOutcome: Sendable, Equatable {

    /// Tool calls were extracted and validated. `toolCalls` is non-empty.
    case success

    /// The model intentionally produced no tool calls (task complete, text-only answer).
    /// `toolCalls` is empty and no parse error occurred.
    case genuineCompletion

    /// Parsing or validation failed. `toolCalls` is empty, but the emptiness is
    /// *our* inability to decode the response, not the model signalling completion.
    /// The executor should inject a typed corrective alert and retry.
    case failed(ParseFailureReason)
}

// MARK: - Parse Failure Reason

/// Typed causes of parse failure. Each case carries enough context for both a
/// UI chip and a model-directed corrective alert.
enum ParseFailureReason: Sendable, Equatable, Codable {

    /// Model produced no parseable output at all (generation may have been
    /// truncated, or the model ignored the schema entirely).
    case emptyOutput

    /// Text present but contains no structured output and no drift signals —
    /// pure prose when a tool call was required.
    case noStructuredOutput(snippet: String)

    /// Model described the tool call in prose without emitting structured output.
    /// e.g. "I will now call list_directory on /tmp".
    case proseDescribedIntent(snippet: String)

    /// JSON was present but failed syntactic decode (unescaped control chars,
    /// trailing comma, single quotes, etc.).
    case malformedJSON(syntaxDetail: String, rawSnippet: String)

    /// JSON decoded cleanly but used the wrong key names.
    /// e.g. `function_name` instead of `name`, `parameters` instead of `arguments`.
    case schemaKeyMismatch(expectedKeys: [String], foundKeys: [String], rawSnippet: String)

    /// Tool name doesn't match any registered tool and no alias/fuzzy resolution
    /// produced a schema-compatible candidate.
    case unknownToolName(attempted: String, suggestions: [String])

    /// Tool name resolved via alias or fuzzy match, but arguments don't fit the
    /// target tool's schema (missing required args, unexpected args).
    case argSchemaMismatch(attempted: String, resolvedTo: String, missingArgs: [String], unexpectedArgs: [String])

    /// Model emitted a different dialect than configured (e.g. XML in a native-JSON flow).
    case dialectDrift(expected: String, detected: String)

    /// Model emitted a registered tool name in plain prose without structural
    /// tool-call syntax (e.g. `codebase_map path: "/some/path"` — a function-call-
    /// shaped text that no parser recognizes). Distinct from `.proseDescribedIntent`
    /// because we have confidence about WHICH tool the model attempted, so the
    /// corrective alert can be targeted: "you wrote `codebase_map` in prose, use
    /// this JSON shape instead".
    case toolNameInProse(toolName: String, snippet: String)

    /// Model called a tool that IS registered for this agent but is currently
    /// hidden from the schema by a runtime gate (e.g. `update_project_context`
    /// before the reading-gate unlocks). Distinct from `.unknownToolName` because
    /// the call isn't a hallucination — the model is calling a real tool that
    /// will become available later. `unlockHint` is the human-readable reason
    /// the tool is locked, shown to both the user (chip) and the model (alert).
    case gatedTool(attempted: String, unlockHint: String)
}

// MARK: - UI + Model Alert Surfacing

extension ParseFailureReason {

    /// Short label for the timeline warning chip.
    var uiChipLabel: String {
        switch self {
        case .emptyOutput:
            return "No response"
        case .noStructuredOutput:
            return "No tool call emitted"
        case .proseDescribedIntent:
            return "Described, didn't call"
        case .malformedJSON:
            return "JSON syntax error"
        case .schemaKeyMismatch:
            return "Wrong schema keys"
        case .unknownToolName(let attempted, _):
            return "Unknown tool: \(attempted)"
        case .argSchemaMismatch(let attempted, let resolved, _, _):
            return "\(attempted) → \(resolved), wrong args"
        case .dialectDrift(_, let detected):
            return "Wrong format (\(detected))"
        case .toolNameInProse(let toolName, _):
            return "`\(toolName)` in prose, not structured"
        case .gatedTool(let attempted, _):
            return "Tool locked: \(attempted)"
        }
    }

    /// Longer tooltip/detail explanation shown on hover.
    var uiTooltip: String {
        switch self {
        case .emptyOutput:
            return "The model produced no output. It may have been truncated or lost context."
        case .noStructuredOutput(let snippet):
            return "The model produced prose but no structured tool call. Snippet: \(snippet.prefix(120))"
        case .proseDescribedIntent(let snippet):
            return "The model described a tool call in prose instead of emitting it as structured output. Snippet: \(snippet.prefix(120))"
        case .malformedJSON(let detail, _):
            return "JSON could not be decoded: \(detail)"
        case .schemaKeyMismatch(let expected, let found, _):
            return "Expected keys: \(expected.joined(separator: ", ")). Received: \(found.joined(separator: ", "))."
        case .unknownToolName(let attempted, let suggestions):
            if suggestions.isEmpty {
                return "Tool '\(attempted)' is not registered for this agent."
            }
            return "Tool '\(attempted)' is not registered. Similar registered tools: \(suggestions.joined(separator: ", "))."
        case .argSchemaMismatch(_, let resolved, let missing, let unexpected):
            var parts: [String] = []
            if !missing.isEmpty   { parts.append("missing: \(missing.joined(separator: ", "))") }
            if !unexpected.isEmpty { parts.append("unexpected: \(unexpected.joined(separator: ", "))") }
            return "Arguments for '\(resolved)' did not match its schema. \(parts.joined(separator: "; "))."
        case .dialectDrift(let expected, let detected):
            return "Expected '\(expected)' format but detected '\(detected)'."
        case .toolNameInProse(let toolName, let snippet):
            return "The model wrote the tool name '\(toolName)' in plain prose instead of emitting a structured tool call. Snippet: \(snippet.prefix(120))"
        case .gatedTool(let attempted, let unlockHint):
            return "'\(attempted)' is registered but not yet available. \(unlockHint)"
        }
    }

    /// Directive text injected into the next iteration's working memory so the
    /// model can course-correct instead of repeating the same mistake.
    func modelCorrectiveAlert(availableToolNames: [String]) -> String {
        switch self {
        case .emptyOutput:
            return "Your last response was empty. Emit a tool call or call `final_answer` to finish. Available tools: \(availableToolNames.joined(separator: ", "))."

        case .noStructuredOutput:
            return "You produced prose with no structured tool call. Emit a JSON tool call or call `final_answer` to finish. Available tools: \(availableToolNames.joined(separator: ", "))."

        case .proseDescribedIntent:
            return "You described a tool call in prose. Actually emit the structured tool call — don't narrate it. Available tools: \(availableToolNames.joined(separator: ", "))."

        case .malformedJSON(let detail, _):
            return "Your JSON failed to decode: \(detail). Escape newlines inside strings with \\n, use double quotes, and produce strict JSON syntax."

        case .schemaKeyMismatch(let expected, let found, _):
            return "You used keys \(found) but this API expects \(expected). Correct shape: {\"name\": \"...\", \"arguments\": {...}}."

        case .unknownToolName(let attempted, let suggestions):
            if suggestions.isEmpty {
                return "Tool `\(attempted)` does not exist. Use one of: \(availableToolNames.joined(separator: ", ")). Call `final_answer` if you are finished."
            }
            return "Tool `\(attempted)` does not exist. Did you mean: \(suggestions.joined(separator: ", "))? Call `final_answer` if you are finished."

        case .argSchemaMismatch(let attempted, let resolved, let missing, let unexpected):
            var hints: [String] = []
            if !missing.isEmpty   { hints.append("missing required args: \(missing.joined(separator: ", "))") }
            if !unexpected.isEmpty { hints.append("unexpected args: \(unexpected.joined(separator: ", "))") }
            return "Tool `\(resolved)` (you called it `\(attempted)`) has a schema mismatch — \(hints.joined(separator: "; ")). Retry with the correct argument names."

        case .dialectDrift(let expected, let detected):
            return "This provider expects \(expected) format. You emitted \(detected). Emit JSON tool calls of shape {\"name\": \"...\", \"arguments\": {...}}."

        case .toolNameInProse(let toolName, let snippet):
            // Targeted corrective alert — names the specific tool the model attempted
            // and shows the structural shape it should use instead.
            return "You wrote `\(toolName)` in plain prose (`\(snippet.prefix(80))`), but this provider expects a structured JSON tool call. Emit: {\"name\": \"\(toolName)\", \"arguments\": {...}}. Do not describe the tool call in prose — emit the JSON object directly."

        case .gatedTool(let attempted, let unlockHint):
            return "Tool `\(attempted)` is not available yet — \(unlockHint). Continue exploring with the tools that ARE available: \(availableToolNames.joined(separator: ", ")). Call `final_answer` if you're finished."
        }
    }
}
