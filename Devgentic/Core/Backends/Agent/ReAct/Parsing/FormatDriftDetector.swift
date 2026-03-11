//
//  FormatDriftDetector.swift
//  Devgentic
//
//  Stage 2 of the Dialect-Anchored Cascade.
//  Runs a ranked series of lightweight signal probes to detect whether the model
//  drifted from its expected dialect into a known alternative format.
//
//  Created by Raj Singh on 10/03/26.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "FormatDriftDetector")

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

    init(excludedDialect: ModelDialect) {
        self.probes = Self.buildProbeList(excluding: excludedDialect)
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

    private static func buildProbeList(excluding dialect: ModelDialect) -> [any FormatProbe] {
        var probes: [any FormatProbe] = [
            PythonicTagProbe(),      // 1. Most distinctive — unique token
            DeepXMLProbe(),          // 2. Qwen-Coder specific tags
            BracketHashProbe(),      // 3. Devstral specific
            YAMLInXMLProbe(),        // 4. Requires both XML + YAML signal
            GenericToolsXMLProbe()   // 5. <tools>/<tool> wrappers (Qwen3, generic)
        ]

        // Only add standard XML probe if primary dialect is NOT already MistralXML
        if dialect != .mistralXML {
            probes.append(StandardXMLProbe())
        }

        // Only add ReAct markdown probe if primary is NOT already ReActMarkdown
        if dialect != .reactMarkdown {
            probes.append(ReActMarkdownProbe())
        }

        probes.append(ArrayInversionProbe())    // 7. JSON array starting with [
        probes.append(FlatJSONLeakageProbe())   // 8. Least specific — broad string match

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

/// Probe 8: Flat JSON Leakage — `"tool_name"` or `"tool_calls"` appearing in text content.
/// Least specific probe; catches miscellaneous JSON leakage patterns.
struct FlatJSONLeakageProbe: FormatProbe {
    let probeID = "flat-json-leakage"
    func detect(in text: String) -> DetectedFormat? {
        (text.contains("\"tool_name\"") || text.contains("\"tool_calls\"")) ? .flatJSONLeakage : nil
    }
}
