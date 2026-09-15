// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    ///
    /// ⚠️ `dialect` is the wire format THIS RUN parses back, or nil on a transport-native flow.
    /// It is not optional decoration: five of these arms used to state a shape, and every one of
    /// them stated the `.nativeJSON` envelope — `{"name": …, "arguments": {…}}` — regardless of
    /// what the run could actually read. Sent to a `.mistralV11Flat` run that is a demand for JSON
    /// where `MistralV11Parser` requires `[TOOL_CALLS]name[ARGS]{…}`, so a model that OBEYED failed
    /// again on the next pass. `LLMRetryStrategy` carried the same defect in its own corrective and
    /// was fixed first (invariant 80); this is the sibling on the path parse failures actually take,
    /// since generators return `.failed` rather than throwing.
    ///
    /// ⚠️ nil means SAY NOTHING ABOUT SHAPE, and that is a verdict rather than a gap: on a
    /// transport-native flow the tool call rides in the protocol, so there is no text shape the
    /// model could emit differently and a format instruction is noise it cannot act on.
    ///
    /// ⚠️ The shape text comes from `ModelDialect.formatReminder` — never a literal here — so the
    /// two correctives in this codebase cannot describe the same format differently.
    func modelCorrectiveAlert(availableToolNames: [String], dialect: ModelDialect?) -> String {
        /// " This model's tool-call format is X." — or nothing at all on a native flow.
        /// Leading space included so call sites read as one sentence stream.
        let formatClause = dialect.map { " This model's tool-call format is \($0.formatReminder)." } ?? ""

        switch self {
        case .emptyOutput:
            return "Your last response was empty. Emit a tool call or call `final_answer` to finish. Available tools: \(availableToolNames.joined(separator: ", "))."

        case .noStructuredOutput:
            return "You produced prose with no structured tool call. Emit a tool call, or call `final_answer` to finish.\(formatClause) Available tools: \(availableToolNames.joined(separator: ", "))."

        case .proseDescribedIntent:
            return "You described a tool call in prose. Actually emit the structured tool call — don't narrate it.\(formatClause) Available tools: \(availableToolNames.joined(separator: ", "))."

        case .malformedJSON(let detail, _):
            // The JSON syntax advice is kept only where the arguments really are JSON. For the
            // three dialects where they are not, it would instruct the model away from its own
            // format — `.pythonicBracketList` is SUPPOSED to emit True/False/None.
            let syntaxAdvice = (dialect?.argumentsAreJSON ?? true)
                ? " Escape newlines inside strings with \\n, use double quotes, and produce strict JSON syntax."
                : ""
            return "Your tool call failed to decode: \(detail).\(syntaxAdvice)\(formatClause)"

        case .schemaKeyMismatch(let expected, let found, let rawSnippet):
            // ⚠️ The snippet is the discriminator, and this arm discarded it from the day the enum
            // was declared. `foundKeys` comes from a regex for ASCII `"key":`, so an output the
            // model wrote with smart quotes (`“arguments”`) yields `[]`, and the alert read
            // `You used keys []` — a sentence naming nothing the model did. Every iteration's
            // alert was then byte-identical; in the 2026-09-13 gemma:7b run it failed to land 14
            // times in a row. `.toolNameInProse` below has quoted its snippet all along — same
            // shape here: what was emitted, then the format it should have been.
            //
            // Bounded and single-lined BEFORE quoting. It lands in the scratchpad's un-evictable
            // alert block as one `- [SYSTEM ALERT]` line, and the producers capture up to 200
            // chars of possibly pretty-printed JSON — whitespace is collapsed first so the window
            // holds content rather than indentation. 80 chars matches `.toolNameInProse`.
            let quoted = String(rawSnippet.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80))
            let emitted = quoted.isEmpty ? "" : " (you emitted: `\(quoted)`)"
            let keysClause = found.isEmpty
                ? "Your tool call had none of the keys this API expects: \(expected)"
                : "You used keys \(found) but this API expects \(expected)"
            return "\(keysClause)\(emitted).\(formatClause)"

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
            // ⚠️ This case has ZERO construction sites in the app (verified 2026-09-13) — nothing
            // produces it, so this text has never reached a model. Corrected anyway rather than
            // left as the one arm still carrying the defect, because its first two sentences are
            // the ones a future caller would trust: they named the expected format and then the
            // third sentence contradicted them with the nativeJSON envelope.
            return "This provider expects \(expected) format. You emitted \(detected).\(formatClause)"

        case .toolNameInProse(let toolName, let snippet):
            // Targeted corrective — names the specific tool the model attempted, then the shape
            // this run can actually read. The targeting is why this case exists separately from
            // `.proseDescribedIntent`, so the tool name is kept even though the shape is now
            // generic: "put `X` in that shape" is still a per-tool instruction.
            let shape = dialect.map { " Re-emit `\(toolName)` as a structured tool call in this model's format: \($0.formatReminder)." }
                ?? " Emit it as a structured tool call using this provider's native tool-calling API, not as text."
            return "You wrote `\(toolName)` in plain prose (`\(snippet.prefix(80))`).\(shape) Do not describe the tool call in prose — emit it directly."

        case .gatedTool(let attempted, let unlockHint):
            return "Tool `\(attempted)` is not available yet — \(unlockHint). Continue exploring with the tools that ARE available: \(availableToolNames.joined(separator: ", ")). Call `final_answer` if you're finished."
        }
    }
}
