// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FormatDriftDetector.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "FormatDriftDetector")

// MARK: - Detected Format

/// Enumerates all known non-standard formats that local models can drift into.
/// Each case maps to a concrete parser via `ParserFactory.createFallbackParser(for:)`.
enum DetectedFormat: String, Sendable {
    case pythonicTag       // <|python_tag|>  (Llama 3.1)
    case deepXML           // <function=...><parameter=...>  (Qwen-Coder)
    case bracketHash       // <Functions#...>  (Devstral)
    case yamlInXML         // <tool_calls> + YAML body
    case genericToolsXML   // <tools>...</tools> or <tool>...</tool>  (Qwen3, generic wrappers)
    case standardXML       // <tool_call>...</tool_call>  (when primary wasn't MistralXML)
    case reactMarkdown     // Action: / Action Input:  (when primary wasn't ReActMarkdown)
    case arrayInversion    // Starts with [ after trim, contains "name" key
    case flatJSONLeakage   // "tool_name" or "tool_calls" appearing in content
    case dynamicToolTag    // <tool_name>{JSON}</tool_name>  (Mistral native — tag IS the tool name)
    case functionCallTag   // <functioncall>...</functioncall>  (some fine-tuned models)
    case gorillaFunction   // <<function>>name(args)  (Gorilla-style format)
}

// MARK: - Format Probe Protocol

/// A lightweight signal scanner that checks for a single specific drift pattern.
/// Probes are stateless, ordered by specificity (most-specific first) in the detector.
protocol FormatProbe: Sendable {
    /// A stable identifier for logging.
    var probeID: String { get }
    /// Returns the detected format if this probe's pattern matches, nil otherwise.
    func detect(in sanitizedText: String) -> DetectedFormat?
}

// MARK: - Drift Telemetry

/// Telemetry payload logged when a drift fallback succeeds.
struct FormatDriftEvent: Sendable {
    let expectedDialect: ModelDialect
    let detectedFormat: DetectedFormat
    let modelId: String
    let toolCount: Int
    let iteration: Int
    let timestamp: Date
}

// MARK: - Format Drift Detector

/// Runs a ranked probe list against sanitized text to detect format drift.
/// Instantiated per-call with the expected dialect excluded from detection.
struct FormatDriftDetector: Sendable {

    private let probes: [any FormatProbe]

    init(excludedDialect: ModelDialect, knownToolNames: Set<String> = []) {
        self.probes = Self.buildProbeList(excluding: excludedDialect, knownToolNames: knownToolNames)
    }

    /// Scans sanitized text for drift signals.
    /// Returns the first (most specific) detected format, or nil if no drift is found.
    func detect(in sanitizedText: String) -> DetectedFormat? {
        for probe in probes {
            if let format = probe.detect(in: sanitizedText) {
                logger.info("FormatDriftDetector: Probe '\(probe.probeID)' matched -> \(format.rawValue)")
                return format
            }
        }
        return nil
    }

    /// Quick check: does the text contain ANY drift signal at all?
    /// Used to classify a zero-tool-call result as "degraded" vs "confident".
    func containsAnySignal(in sanitizedText: String) -> Bool {
        return detect(in: sanitizedText) != nil
    }

    // MARK: - Probe Construction

    private static func buildProbeList(excluding dialect: ModelDialect, knownToolNames: Set<String> = []) -> [any FormatProbe] {
        var probes: [any FormatProbe] = []

        // Skip PythonicTagProbe when primary is .llama3JsonSingle — the Llama3 parser
        // natively strips `<|python_tag|>` markers before JSON decoding.
        if dialect != .llama3JsonSingle {
            probes.append(PythonicTagProbe())     // 1. Most distinctive — unique token
        }

        // Skip DeepXMLProbe (matches <function=NAME> + <parameter=KEY>) when primary
        // IS Qwen3-Coder — that's exactly its native shape.
        if dialect != .qwen3CoderDeepXml {
            probes.append(DeepXMLProbe())         // 2. Qwen-Coder specific tags
        }

        probes.append(BracketHashProbe())         // 3. Devstral legacy specific
        probes.append(YAMLInXMLProbe())           // 4. Requires both XML + YAML signal
        probes.append(GenericToolsXMLProbe())     // 5. <tools>/<tool> wrappers (Qwen3, generic)

        // StandardXMLProbe catches `<tool_call>...</tool_call>` drift. Skip for all
        // dialects whose primary parser owns that wrapper shape.
        let dialectsOwningToolCallWrapper: Set<ModelDialect> = [
            .mistralXML, .qwenHermesToolCall, .graniteLegacyArray,
            .granite4ToolCall, .qwen3CoderDeepXml
        ]
        if !dialectsOwningToolCallWrapper.contains(dialect) {
            probes.append(StandardXMLProbe())
        }

        // Only add ReAct markdown probe if primary is NOT already ReActMarkdown.
        if dialect != .reactMarkdown {
            probes.append(ReActMarkdownProbe())
        }

        probes.append(FunctionCallTagProbe())   // 8. <functioncall>...</functioncall>
        probes.append(GorillaFunctionProbe())   // 9. <<function>>name(args)

        // Skip DynamicToolTagProbe for dialects whose primary output contains
        // `<tool_call>{JSON}</tool_call>` — the probe's structural pattern
        // `<([a-z][a-z0-9_]*)>\s*\{...\}\s*</\1>` falsely matches `tool_call` tag.
        let dialectsOwningDynamicToolTag: Set<ModelDialect> = [
            .qwenHermesToolCall, .granite4ToolCall
        ]
        if !dialectsOwningDynamicToolTag.contains(dialect) {
            probes.append(DynamicToolTagProbe(knownToolNames: knownToolNames))
        }

        // ArrayInversionProbe matches `[... "name" ...]` — this IS the primary shape for
        // all array-format dialects. Skip the probe for them — primary parsers own it.
        let dialectsOwningJsonArray: Set<ModelDialect> = [
            .mistralV3Array, .phiFunctoolsBracket, .graniteLegacyArray,
            .commandRAction, .commandR7BAction
        ]
        if !dialectsOwningJsonArray.contains(dialect) {
            probes.append(ArrayInversionProbe())    // 11. JSON array starting with [
        }

        probes.append(FlatJSONLeakageProbe())   // 12. Least specific — broad string match

        return probes
    }
}

// MARK: - Concrete Probes

/// Probe 1: `<|python_tag|>` marker used by Llama 3.1 tool-calling variants.
struct PythonicTagProbe: FormatProbe {
    let probeID = "pythonic-tag"
    func detect(in text: String) -> DetectedFormat? {
        text.contains("<|python_tag|>") ? .pythonicTag : nil
    }
}

/// Probe 2: Deep XML (Qwen-Coder) — `<function=` AND `<parameter=` co-occurring.
struct DeepXMLProbe: FormatProbe {
    let probeID = "deep-xml"
    func detect(in text: String) -> DetectedFormat? {
        (text.contains("<function=") && text.contains("<parameter=")) ? .deepXML : nil
    }
}

/// Probe 3: Bracket/Hash — `<Functions#` marker from Devstral/OpenHands.
struct BracketHashProbe: FormatProbe {
    let probeID = "bracket-hash"
    func detect(in text: String) -> DetectedFormat? {
        text.contains("<Functions#") ? .bracketHash : nil
    }
}

/// Probe 4: YAML-in-XML — `<tool_calls>` tag with YAML-style `- name:` body.
struct YAMLInXMLProbe: FormatProbe {
    let probeID = "yaml-in-xml"
    func detect(in text: String) -> DetectedFormat? {
        guard text.contains("<tool_calls>") else { return nil }
        // Verify YAML list pattern: "- name:" on its own line
        guard let regex = try? NSRegularExpression(
            pattern: #"^\s*-\s+name:"#,
            options: .anchorsMatchLines
        ), regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else {
            return nil
        }
        return .yamlInXML
    }
}

/// Probe 5: Standard XML wrapper — `<tool_call>...</tool_call>` with JSON body.
/// Only added when the primary dialect is NOT MistralXML (which already handles this).
struct StandardXMLProbe: FormatProbe {
    let probeID = "standard-xml"
    func detect(in text: String) -> DetectedFormat? {
        (text.contains("<tool_call>") && text.contains("</tool_call>")) ? .standardXML : nil
    }
}

/// Probe 6: ReAct Markdown — `Action:` AND `Action Input:` co-occurring.
/// Only added when the primary dialect is NOT ReActMarkdown.
struct ReActMarkdownProbe: FormatProbe {
    let probeID = "react-markdown"
    func detect(in text: String) -> DetectedFormat? {
        let hasAction = text.range(of: #"(?m)^Action:\s*"#, options: .regularExpression) != nil
        let hasInput = text.range(of: "Action Input:", options: .caseInsensitive) != nil
        return (hasAction && hasInput) ? .reactMarkdown : nil
    }
}

/// Probe 5b: Generic Tools XML — `<tools>...</tools>` or `<tool>...</tool>` wrappers.
/// Used by Qwen3 and other models that wrap bare JSON tool calls in generic XML tags.
/// Placed before StandardXMLProbe because `<tools>` is a distinct tag from `<tool_call>`.
struct GenericToolsXMLProbe: FormatProbe {
    let probeID = "generic-tools-xml"
    func detect(in text: String) -> DetectedFormat? {
        // Match <tools>...</tools> (plural)
        if text.contains("<tools>") && text.contains("</tools>") {
            return .genericToolsXML
        }
        // Match <tool>...</tool> (singular, distinct from <tool_call>)
        if text.contains("<tool>") && text.contains("</tool>") {
            return .genericToolsXML
        }
        return nil
    }
}

/// Probe 7: Array Inversion — starts with `[` after trim and contains `"name"` key.
/// Catches LiteLLM proxy errors that dump tool_calls as a JSON array in content.
struct ArrayInversionProbe: FormatProbe {
    let probeID = "array-inversion"
    func detect(in text: String) -> DetectedFormat? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.contains("\"name\"") else { return nil }
        return .arrayInversion
    }
}

/// Probe 8: Dynamic Tool Tag — `<tool_name>{JSON}</tool_name>` where the XML tag itself
/// is the tool name. This is Mistral's native tool-calling format when tools are passed
/// via `applyChatTemplate(tools:)`. Unlike `<tool_call>` (a fixed wrapper), here the tag
/// is dynamic and different for every tool (e.g., `<search_issues>`, `<get_file_contents>`).
///
/// Two-phase detection:
///   Phase B (precise): Checks for `<tag>{...}</tag>` where tag matches a known registered tool.
///   Phase A (structural): Falls back to regex pattern matching `<word>{JSON}</word>` for
///                         hallucinated tool names not in the registry.
struct DynamicToolTagProbe: FormatProbe {
    let probeID = "dynamic-tool-tag"

    /// Known tool names injected from the tool registry at construction time.
    /// When empty, only the structural Phase A runs.
    let knownToolNames: Set<String>

    init(knownToolNames: Set<String> = []) {
        self.knownToolNames = knownToolNames
    }

    func detect(in text: String) -> DetectedFormat? {
        // Phase B (precise): Check for known tool names used as XML tags.
        // Fast O(n) string scan — no regex needed.
        for toolName in knownToolNames {
            if text.contains("<\(toolName)>") && text.contains("</\(toolName)>") {
                return .dynamicToolTag
            }
        }

        // Phase A (structural): Match <identifier>{...JSON...}</identifier> pattern.
        // The identifier must look like a tool name (lowercase + underscores),
        // followed by a JSON object body, and closed with a matching end tag.
        // This catches hallucinated tool names not in the registry.
        let pattern = #"<([a-z][a-z0-9_]*)>\s*\{[\s\S]*?\}\s*</\1>"#
        if text.range(of: pattern, options: .regularExpression) != nil {
            return .dynamicToolTag
        }

        return nil
    }
}

/// Probe 9: FunctionCall Tag — `<functioncall>...</functioncall>` wrappers used by some fine-tuned models.
struct FunctionCallTagProbe: FormatProbe {
    let probeID = "functioncall-tag"
    func detect(in text: String) -> DetectedFormat? {
        (text.contains("<functioncall>") && text.contains("</functioncall>")) ? .functionCallTag : nil
    }
}

/// Probe 10: Gorilla-style — `<<function>>name(args)` format from Gorilla LLM.
struct GorillaFunctionProbe: FormatProbe {
    let probeID = "gorilla-function"
    func detect(in text: String) -> DetectedFormat? {
        text.contains("<<function>>") ? .gorillaFunction : nil
    }
}

/// Probe 11: Flat JSON Leakage — `"tool_name"` or `"tool_calls"` appearing in text content.
/// Least specific probe; catches miscellaneous JSON leakage patterns.
struct FlatJSONLeakageProbe: FormatProbe {
    let probeID = "flat-json-leakage"
    func detect(in text: String) -> DetectedFormat? {
        (text.contains("\"tool_name\"") || text.contains("\"tool_calls\"")) ? .flatJSONLeakage : nil
    }
}
