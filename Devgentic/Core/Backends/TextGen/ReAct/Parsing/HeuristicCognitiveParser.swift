//
//  HeuristicCognitiveParser.swift
//  Devgentic
//
//  Created by Raj Singh on 05/03/26.
//


import Foundation
import OSLog

private let logger = DGLogger(category: "HeuristicCognitiveParser")


// MARK: - Shared Parsing Heuristics

/// A collection of robust JSON parsing heuristics and fallback mechanisms.
/// Designed to rescue structurally volatile responses from local or less capable models.
struct HeuristicCognitiveParser: CognitiveParserProtocol {
    
    /// Conformance to CognitiveParserProtocol.
    func parse(rawResponse: String) -> ModernCognitiveStep {
        return Self.parseLegacyResponse(rawResponse)
    }

    /// Parses a raw string response into a LeanCognitiveStep using a tiered strategy.
    private struct LegacyArraySchema: Decodable {
        let content: String
        let tool_calls: [LegacyToolCall]
        
        struct LegacyToolCall: Decodable {
            let name: String
            let arguments: [String: JSONValue]
        }
    }

    private struct LegacySingleSchema: Decodable {
        let content: String
        let tool_name: String?
        let arguments: [String: JSONValue]?
    }

    /// Nested content wrapper: `{"content": {"thought": "...", "tool_calls": [...]}}`
    /// Some models (especially small MLX models) nest the entire response inside `content` as an object
    /// instead of using `content` as a string. This schema unwraps the inner structure.
    private struct NestedContentSchema: Decodable {
        let content: NestedContent

        struct NestedContent: Decodable {
            let thought: String?
            let tool_calls: [LegacyArraySchema.LegacyToolCall]?
        }
    }

    /// Bare tool call object: `{"name": "tool", "arguments": {...}}`
    /// No `content` wrapper — the model emitted just the raw call.
    /// Handles both "arguments" and "parameters" keys for flexibility.
    private struct BareToolCallSchema: Decodable {
        let name: String
        let arguments: [String: JSONValue]?
        let parameters: [String: JSONValue]?
    }

    /// Parses a raw string response into a ModernCognitiveStep using a tiered legacy shield strategy.
    static func parseLegacyResponse(_ rawText: String) -> ModernCognitiveStep {
        // --- 1. Markdown Sanitization ---
        var cleanText = rawText
        if cleanText.contains("```json") {
            cleanText = cleanText.components(separatedBy: "```json").last ?? cleanText
        }
        if cleanText.contains("```") {
            cleanText = cleanText.components(separatedBy: "```").first ?? cleanText
        }

        cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)

        // --- 2. Outermost Object Extraction ---
        guard let jsonString = extractOutermostJSON(from: cleanText) else {
            // Static method — no TraceContext to emit a structured SpanEvent against.
            // We still stamp the classified category on the DGLogger call so ring-buffer
            // analytics can filter/aggregate parse failures by taxonomy. Full SpanEvent
            // classification for parser sites would require threading TraceContext through
            // the parser API, which is a future refactor.
            logger.error(
                "❌ [JSONParser] Failed to find valid JSON object. Raw text: \(rawText.prefix(500))",
                category: .parseJsonEmpty,
                metadata: ["raw_length": "\(rawText.count)"]
            )

            // Recovery A: Lenient regex-based extraction directly on raw text.
            if let lenient = attemptLenientExtraction(from: cleanText) {
                logger.info(
                    "✅ [JSONParser] Lenient extraction recovered from malformed JSON (no balanced braces)."
                )
                return lenient
            }

            // Recovery B: Markdown-field format ("content: <text>\ntool_calls: <value>")
            if let recovered = extractFromMarkdownFieldFormat(cleanText) {
                logger.info("✅ [JSONParser] Recovered reasoning from markdown-field format.")
                return recovered
            }

            // No JSON braces found AND no markdown-field format AND no lenient recovery.
            // Text is either empty or pure prose. Let the pipeline's inferFailureReason
            // classify it — we pass no parseOutcome override so the default derivation
            // (`toolCalls.isEmpty → .genuineCompletion`) applies. The pipeline's Stage 2+
            // will override with `.failed(...)` if drift signals exist; otherwise empty
            // tool calls + no signals is treated as a text-only completion.
            return ModernCognitiveStep(reasoning: rawText, toolCalls: [])
        }

        // --- 3. Structural Defect Sanitization ---
        let sanitized = sanitizeJSON(jsonString)

        // --- 4. Standard Decoding Attempt ---
        guard let data = sanitized.data(using: .utf8) else {
            logger.error("❌ [JSONParser] Failed to convert string to data.")
            return ModernCognitiveStep(reasoning: rawText, toolCalls: [])
        }

        let decoder = JSONDecoder()

        // Attempt 1: The model successfully output an array (Smart Model)
        if let arrayDecoded = try? decoder.decode(LegacyArraySchema.self, from: data) {
            let pending = arrayDecoded.tool_calls.map {
                PendingToolCall(id: UUID().uuidString, name: $0.name, arguments: $0.arguments)
            }
            return ModernCognitiveStep(
                reasoning: ReasoningQualityFilter.filter(arrayDecoded.content),
                toolCalls: pending
            )
        }

        // Attempt 1.5: Nested Content Wrapper (Small models wrap response inside "content" as object)
        // e.g. {"content": {"thought": "...", "tool_calls": [...]}}
        if let nestedDecoded = try? decoder.decode(NestedContentSchema.self, from: data) {
            let inner = nestedDecoded.content
            let pending = (inner.tool_calls ?? []).map {
                PendingToolCall(id: UUID().uuidString, name: $0.name, arguments: $0.arguments)
            }
            logger.info("✅ [JSONParser] Nested content schema matched. Tools: \(pending.count)")
            return ModernCognitiveStep(
                reasoning: ReasoningQualityFilter.filter(inner.thought),
                toolCalls: pending
            )
        }

        // Attempt 2: Graceful Degradation (Dumb Model used old format)
        if let singleDecoded = try? decoder.decode(LegacySingleSchema.self, from: data) {
            var pending: [PendingToolCall] = []
            if let toolName = singleDecoded.tool_name, toolName != "null", !toolName.isEmpty {
                let args = singleDecoded.arguments ?? [:]
                pending.append(PendingToolCall(id: UUID().uuidString, name: toolName, arguments: args))
            }
            // G7: empty reasoning stays empty. UI renders "Executing <tool>..." from .toolCall events.
            return ModernCognitiveStep(
                reasoning: ReasoningQualityFilter.filter(singleDecoded.content),
                toolCalls: pending
            )
        }

        // Attempt 3: Bare Tool Call (model emitted just {"name": "...", "arguments": {...}})
        if let bareDecoded = try? decoder.decode(BareToolCallSchema.self, from: data) {
            let args = bareDecoded.arguments ?? bareDecoded.parameters ?? [:]
            let pending = [PendingToolCall(id: UUID().uuidString, name: bareDecoded.name, arguments: args)]
            logger.info("✅ [JSONParser] Bare tool call schema matched for tool: \(bareDecoded.name)")
            // G7: no prose was available inside the bare tool-call object. Caller
            // (OllamaLLMProvider.splitProseAndJSON) captures any prose BEFORE the JSON block.
            return ModernCognitiveStep(reasoning: "", toolCalls: pending)
        }

        // Attempt 4: Lenient Extraction
        logger.warning("⚠️ [JSONParser] Standard decode failed, attempting lenient extraction...")
        if let lenient = attemptLenientExtraction(from: sanitized) {
            logger.info("✅ [JSONParser] Lenient extraction succeeded.")
            return lenient
        }

        logger.error("❌ [JSONParser] All parsing strategies exhausted. JSON was: \(sanitized.prefix(500))")

        // All schemas rejected the JSON despite it being structurally well-formed
        // (extractOutermostJSON succeeded). This is the iter-5-shape failure: valid
        // braces but wrong keys (e.g. `function_name` instead of `name`). Mark it
        // as a typed schema-key-mismatch so the pipeline/terminator route to
        // `.suspectedFormatFailure` instead of silently treating empty toolCalls
        // as `.genuineCompletion`.
        let foundKeys = extractTopLevelKeys(from: sanitized)
        let reason: ParseFailureReason = .schemaKeyMismatch(
            expectedKeys: ["name", "arguments", "tool_calls", "content"],
            foundKeys: foundKeys,
            rawSnippet: String(sanitized.prefix(200))
        )
        return ModernCognitiveStep(
            reasoning: rawText,
            toolCalls: [],
            parseOutcome: .failed(reason)
        )
    }

    /// Extracts the top-level object keys from a JSON-ish string via lightweight regex.
    /// Used to build typed `.schemaKeyMismatch` failure reasons when the object is
    /// syntactically valid but the keys don't match any known schema.
    private static func extractTopLevelKeys(from json: String) -> [String] {
        let pattern = #"\"([A-Za-z_][A-Za-z0-9_]*)\"\s*:"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsString = json as NSString
        let matches = regex.matches(in: json, range: NSRange(location: 0, length: nsString.length))
        let keys = matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: json) else { return nil }
            return String(json[range])
        }
        // Deduplicate while preserving order; top 10 is plenty for diagnostics.
        var seen = Set<String>()
        var unique: [String] = []
        for k in keys where !seen.contains(k) {
            seen.insert(k)
            unique.append(k)
            if unique.count >= 10 { break }
        }
        return unique
    }

    // MARK: - Brace-Depth JSON Extraction

    /// Extracts the outermost JSON object from a string by tracking brace depth.
    private static func extractOutermostJSON(from text: String) -> String? {
        // NOTE (#15): the `prevChar != "\\"` escape heuristic is intentional here — NOT the
        // strict in-string-only `escaped` flag used by BalancedJSONScanner. The heuristic
        // parser runs on malformed / stringified JSON where escaped quotes appear OUTSIDE
        // string spans, and the legacy/native-fallback recovery depends on this looser model.
        // (Switching to the strict flag regressed testFallback_* / testConversationalExit.)
        var depth = 0
        var startIndex: String.Index?
        var inString = false
        var prevChar: Character = "\0"

        for (index, char) in zip(text.indices, text) {
            if char == "\"" && prevChar != "\\" {
                inString.toggle()
            }

            if !inString {
                if char == "{" {
                    if depth == 0 { startIndex = index }
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0, let start = startIndex {
                        return String(text[start...index])
                    }
                }
            }
            prevChar = char
        }

        // Brace-balance recovery: model opened braces but the scan ended with unclosed
        // depth. Common on Q4-quantized local models emitting longer `final_answer`
        // payloads where the outer `}` gets dropped. Append the missing closers and
        // let the downstream decode attempt validate. Bounded cap keeps pathological
        // inputs from producing arbitrary-length payloads. Skip when still inside a
        // string span — unterminated string quotes aren't fixable by brace-balancing.
        if let start = startIndex, depth > 0, depth <= 4, !inString {
            let reconstructed = String(text[start...]) + String(repeating: "}", count: depth)
            logger.info("🔧 [JSONParser] Brace-balance recovery: appended \(depth) closing brace(s) to salvage unbalanced JSON.")
            return reconstructed
        }

        return nil
    }

    // MARK: - JSON Sanitization

    /// Sanitizes common structural defects in LLM-generated JSON (e.g., trailing commas, control characters, Python-style literals).
    private static func sanitizeJSON(_ json: String) -> String {
        var result = json

        // 1. Single-quote to double-quote normalization.
        //    Python-trained models sometimes emit {'key': 'value'} instead of {"key": "value"}.
        //    Only runs when the input has single quotes AND lacks valid double-quoted structure,
        //    or when single quotes co-exist with double quotes in a mixed format.
        result = normalizeSingleQuotes(result)

        // 2. Unquoted key normalization: {key: "val"} → {"key": "val"}
        //    JavaScript-style unquoted object keys are invalid JSON.
        //    Matches a bare identifier after { , [ or newline in key position (before ':').
        //    Only targets keys — values like `null`, `true`, `false` are handled by step 4.
        if let regex = try? NSRegularExpression(
            pattern: #"(?<=[\{\[,\n])\s*([a-zA-Z_]\w*)\s*:"#
        ) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: " \"$1\":")
        }

        // 3. Trailing comma removal: {"key": "val",} → {"key": "val"}
        let trailingCommaPattern = #",\s*([}\]])"#
        if let regex = try? NSRegularExpression(pattern: trailingCommaPattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        // 4. Python-style literal normalization.
        //    Models (especially Llama 3.1) emit Python literals instead of JSON:
        //      NULL / None → null,  True → true,  False → false,  NaN → null
        //    Safe here because sanitizeJSON() only runs on extracted JSON objects
        //    (after brace-depth extraction), not on free-text reasoning.
        //    Word-boundary anchors (\b) prevent corrupting keys like "nullable".
        result = normalizePythonLiterals(result)

        // 5. Unwrap stringified arguments: "arguments": "{...}" → "arguments": {...}
        //    Some models serialize the arguments dict as a JSON string instead of an object.
        //    Detects the pattern and unescapes the inner JSON.
        result = unwrapStringifiedArguments(result)

        // 6. Strip control characters (below 0x20) except standard whitespace.
        result = result.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 || scalar == "\n" || scalar == "\r" || scalar == "\t"
        }.map { String($0) }.joined()

        // 7. Escape raw whitespace control characters that leaked INSIDE string values.
        //    Quantized models (qwen-coder Q4_K_M in particular) sometimes emit a literal LF
        //    inside a JSON string value instead of the two-char sequence `\n`. JSON is strict —
        //    raw LF/CR/TAB inside a `"..."` span is invalid and breaks JSONDecoder. This step
        //    walks the string once, tracks string/escape state, and rewrites raw control
        //    chars only when they appear inside a string span. Valid JSON is untouched
        //    (valid JSON never has these chars unescaped inside strings).
        result = escapeRawControlsInsideStrings(result)

        return result
    }

    /// Replaces raw LF/CR/TAB characters that appear inside JSON string values with their
    /// escape sequences. Leaves identical characters between tokens (whitespace) untouched.
    /// Honors backslash escapes so `\"` inside a string doesn't prematurely close it.
    private static func escapeRawControlsInsideStrings(_ json: String) -> String {
        var result: [Character] = []
        result.reserveCapacity(json.count + 16)
        var inString = false
        var justSawEscape = false

        for char in json {
            if justSawEscape {
                // Previous char was `\` — this char is part of the escape sequence, append as-is.
                result.append(char)
                justSawEscape = false
                continue
            }
            if char == "\\" && inString {
                result.append(char)
                justSawEscape = true
                continue
            }
            if char == "\"" {
                inString.toggle()
                result.append(char)
                continue
            }
            if inString {
                switch char {
                case "\n":
                    result.append("\\"); result.append("n")
                case "\r":
                    result.append("\\"); result.append("r")
                case "\t":
                    result.append("\\"); result.append("t")
                default:
                    result.append(char)
                }
            } else {
                result.append(char)
            }
        }

        return String(result)
    }

    /// Replaces Python-style literals with their JSON equivalents.
    /// Uses word-boundary matching to avoid corrupting embedded strings
    /// (e.g., a key named "nullable" won't be mangled).
    private static func normalizePythonLiterals(_ json: String) -> String {
        var result = json

        // Order matters: longest tokens first to avoid partial matches.
        let replacements: [(pattern: String, replacement: String)] = [
            (#"\bFalse\b"#,  "false"),   // Python bool
            (#"\bTrue\b"#,   "true"),    // Python bool
            (#"\bNone\b"#,   "null"),    // Python null
            (#"\bNULL\b"#,   "null"),    // Uppercase null (MySQL / C-style leak)
            (#"\bNaN\b"#,    "null"),    // Python float NaN → safest as null
        ]

        for (pattern, replacement) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement
            )
        }

        return result
    }

    /// Replaces single quotes used as JSON delimiters with double quotes.
    /// Uses a state-machine approach to walk character-by-character, distinguishing
    /// structural single quotes from apostrophes inside double-quoted strings.
    ///
    /// Safe because this runs only on brace-depth-extracted JSON objects, not free text.
    /// Handles mixed quoting (some keys single-quoted, some double-quoted).
    private static func normalizeSingleQuotes(_ json: String) -> String {
        // Quick bail: no single quotes → nothing to do
        guard json.contains("'") else { return json }

        var result: [Character] = []
        result.reserveCapacity(json.count)
        var inDoubleQuote = false
        var inSingleQuote = false
        var prevChar: Character = "\0"

        for char in json {
            if char == "\"" && !inSingleQuote && prevChar != "\\" {
                inDoubleQuote.toggle()
                result.append(char)
            } else if char == "'" && !inDoubleQuote && prevChar != "\\" {
                // Single quote in a structural position → replace with double quote
                inSingleQuote.toggle()
                result.append("\"")
            } else {
                result.append(char)
            }
            prevChar = char
        }

        return String(result)
    }

    /// Upper bound on the input length for the regex-based recovery helpers below (#15
    /// sub-issue 2). The `(?:[^"\\]|\\.)*` patterns are linear (the two branches are
    /// disjoint), so this is a defensive cap against a pathologically large input causing a
    /// slow scan — not a fix for exponential backtracking. Generous: a cognitive step is a
    /// few KB, and large *valid* JSON still flows through the primary `JSONDecoder` path.
    private static let maxRegexRecoveryLength = 200_000

    /// Detects `"arguments": "{...}"` or `"parameters": "{...}"` patterns where the model
    /// emitted the arguments dict as a JSON-encoded string, and unwraps them to raw objects.
    /// Example: `"arguments": "{\"path\": \"/tmp\"}"` → `"arguments": {"path": "/tmp"}`
    private static func unwrapStringifiedArguments(_ json: String) -> String {
        guard json.count <= maxRegexRecoveryLength else { return json }
        // Match "arguments" or "parameters" followed by a colon and a string that starts with {
        let pattern = #"("(?:arguments|parameters)")\s*:\s*"(\{(?:[^"\\]|\\.)*\})""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else {
            return json
        }

        let nsString = json as NSString
        let matches = regex.matches(in: json, range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return json }

        var result = json
        // Process matches in reverse to preserve ranges
        for match in matches.reversed() {
            guard let keyRange = Range(match.range(at: 1), in: result),
                  let innerRange = Range(match.range(at: 2), in: result) else { continue }

            // Unescape the inner JSON string: \" → ", \\ → \
            var inner = String(result[innerRange])
            inner = inner.replacingOccurrences(of: "\\\"", with: "\"")
            inner = inner.replacingOccurrences(of: "\\\\", with: "\\")

            // Replace the full match: "arguments": "{...}" → "arguments": {...}
            let fullRange = Range(match.range, in: result)!
            let key = String(result[keyRange])
            result.replaceSubrange(fullRange, with: "\(key): \(inner)")
        }

        return result
    }

    // MARK: - Lenient Field Extraction

    /// A fallback heuristic that attempts to extract required fields using regular expressions when standard JSON decoding fails.
    private static func attemptLenientExtraction(from json: String) -> ModernCognitiveStep? {
        guard json.count <= maxRegexRecoveryLength else { return nil }
        func extractStringOrNull(forKey key: String, in text: String) -> String? {
            let stringPattern = #"\"\#(key)\"\s*:\s*\"((?:[^\"\\]|\\.)*)\""#
            if let regex = try? NSRegularExpression(pattern: stringPattern, options: .dotMatchesLineSeparators),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }

            let nullPattern = #"\"\#(key)\"\s*:\s*null"#
            if let regex = try? NSRegularExpression(pattern: nullPattern, options: []),
               regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                return "null"
            }
            return nil
        }

        // Extract content leniently — don't gate tool_calls on content success.
        // A malformed content field (e.g., HTML tags, unquoted value) must NOT
        // prevent recovery of a valid tool_calls array sitting right next to it.
        let rawContent = extractStringOrNull(forKey: "content", in: json)
        let contentReasoning = (rawContent != nil && rawContent != "null") ? rawContent! : ""
        let hasToolCallsKey = json.range(of: "\"tool_calls\"") != nil
        let hasToolNameKey = json.range(of: "\"tool_name\"") != nil

        // If we found neither a content field nor any tool-related keys, this isn't
        // recoverable JSON — return nil so the caller can try other recovery paths.
        if contentReasoning.isEmpty && !hasToolCallsKey && !hasToolNameKey {
            return nil
        }

        // If content extraction failed but tool_calls key exists, try to salvage
        // readable text before "tool_calls"
        let reasoning: String
        if contentReasoning.isEmpty, let toolCallsMarker = json.range(of: "\"tool_calls\"") {
            let beforeTools = String(json[json.startIndex..<toolCallsMarker.lowerBound])
            reasoning = beforeTools
                .replacingOccurrences(of: "\"content\"", with: "")
                .replacingOccurrences(of: #"[{}\[\]":,]"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            reasoning = contentReasoning
        }

        // --- Strategy A: Extract individual tool objects from "tool_calls" array ---
        // Handles malformed arrays (missing commas between elements, keys outside "arguments").
        // Finds each `{"name": "..."}` object inside the array using brace-depth extraction.
        var pending: [PendingToolCall] = []

        if let arrayStart = json.range(of: "\"tool_calls\"") {
            let arrayRegion = String(json[arrayStart.lowerBound...])
            // Find the opening '[' of the array
            if let bracketStart = arrayRegion.firstIndex(of: "[") {
                let innerRegion = String(arrayRegion[bracketStart...])
                pending = extractToolCallsFromArray(innerRegion)
                if !pending.isEmpty {
                    logger.info("✅ [JSONParser] Lenient array extraction recovered \(pending.count) tool call(s).")
                }
            }
        }

        // --- Strategy B: Legacy single-tool format ("tool_name" key) ---
        if pending.isEmpty {
            let extractedTool = extractStringOrNull(forKey: "tool_name", in: json)
            let toolName: String? = (extractedTool == "null" || extractedTool?.isEmpty == true) ? nil : extractedTool

            if let toolName = toolName {
                var arguments: [String: JSONValue]? = nil
                if let argsStart = json.range(of: "\"arguments\""),
                   let extracted = extractOutermostJSON(from: String(json[argsStart.lowerBound...])) {
                    if let argsData = extracted.data(using: .utf8),
                       let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: argsData) {
                        arguments = decoded
                    } else {
                        arguments = [:]
                    }
                } else {
                    arguments = [:]
                }

                if arguments?.isEmpty == true, !reasoning.isEmpty {
                    if let rescued = rescueArgumentsFromContent(toolName: toolName, content: reasoning) {
                        logger.info("🔧 [JSONParser] Rescued arguments from content for tool '\(toolName)'.")
                        arguments = rescued
                    }
                }

                pending.append(PendingToolCall(id: UUID().uuidString, name: toolName, arguments: arguments ?? [:]))
            }
        }

        // G7: empty reasoning stays empty. UI renders tool execution state from .toolCall events.
        // Note: `reasoning` above is kept unfiltered for the `rescueArgumentsFromContent`
        // call path, which mines argument values out of free-text content. Filtering only
        // happens here, at the final boundary, so stub patterns don't leak into the step.
        return ModernCognitiveStep(
            reasoning: ReasoningQualityFilter.filter(reasoning),
            toolCalls: pending
        )
    }

    // MARK: - Array Tool Call Extraction

    /// Extracts individual tool call objects from a potentially malformed JSON array string.
    ///
    /// Walks through the array using brace-depth extraction to isolate each `{...}` block,
    /// then attempts to decode each block individually. Handles:
    /// - Missing commas between array elements
    /// - Keys at the wrong nesting level (e.g., "search_term" outside "arguments")
    /// - Missing "arguments" wrapper
    ///
    /// - Parameter arrayString: The raw string starting from `[` of the tool_calls array.
    /// - Returns: An array of successfully parsed tool calls (may be partial if some fail).
    private static func extractToolCallsFromArray(_ arrayString: String) -> [PendingToolCall] {
        var results: [PendingToolCall] = []
        var searchFrom = arrayString.startIndex

        while searchFrom < arrayString.endIndex {
            let remaining = String(arrayString[searchFrom...])
            guard let objectJSON = extractOutermostJSON(from: remaining) else { break }

            // Advance past this object for the next iteration
            if let objRange = remaining.range(of: objectJSON) {
                searchFrom = arrayString.index(searchFrom, offsetBy: remaining.distance(from: remaining.startIndex, to: objRange.upperBound))
            } else {
                break
            }

            // Try strict decode first
            if let data = objectJSON.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(LegacyArraySchema.LegacyToolCall.self, from: data) {
                results.append(PendingToolCall(id: UUID().uuidString, name: decoded.name, arguments: decoded.arguments))
                continue
            }

            // Lenient: extract "name" via regex, then recover arguments
            let namePattern = #"\"name\"\s*:\s*\"([^\"]+)\""#
            guard let nameRegex = try? NSRegularExpression(pattern: namePattern),
                  let nameMatch = nameRegex.firstMatch(in: objectJSON, range: NSRange(objectJSON.startIndex..., in: objectJSON)),
                  let nameRange = Range(nameMatch.range(at: 1), in: objectJSON) else {
                continue
            }
            let toolName = String(objectJSON[nameRange])

            // Try to decode "arguments" sub-object
            var args: [String: JSONValue] = [:]
            if let argsStart = objectJSON.range(of: "\"arguments\""),
               let argsJSON = extractOutermostJSON(from: String(objectJSON[argsStart.lowerBound...])),
               let argsData = argsJSON.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: argsData) {
                args = decoded
            } else {
                // Fallback: collect all string/null key-value pairs except "name" and "arguments"
                // as flattened arguments (handles keys at wrong nesting level)
                args = extractFlattenedArguments(from: objectJSON, excludingKeys: ["name", "arguments"])
            }

            results.append(PendingToolCall(id: UUID().uuidString, name: toolName, arguments: args))
            logger.info("🔧 [JSONParser] Lenient recovery for tool '\(toolName)' with \(args.count) arg(s).")
        }

        return results
    }

    /// Extracts all key-value pairs from a JSON object string via regex,
    /// excluding specified keys. Handles string values, null, numbers, and booleans.
    /// Used when a model flattens "arguments" keys into the tool call object.
    private static func extractFlattenedArguments(from json: String, excludingKeys: [String]) -> [String: JSONValue] {
        var args: [String: JSONValue] = [:]
        guard json.count <= maxRegexRecoveryLength else { return args }
        let excludeSet = Set(excludingKeys)

        // Match "key": "stringValue"
        let stringPattern = #"\"(\w+)\"\s*:\s*\"((?:[^\"\\]|\\.)*)\""#
        if let regex = try? NSRegularExpression(pattern: stringPattern, options: .dotMatchesLineSeparators) {
            let matches = regex.matches(in: json, range: NSRange(json.startIndex..., in: json))
            for match in matches {
                if let keyRange = Range(match.range(at: 1), in: json),
                   let valRange = Range(match.range(at: 2), in: json) {
                    let key = String(json[keyRange])
                    if !excludeSet.contains(key) {
                        args[key] = .string(String(json[valRange]))
                    }
                }
            }
        }

        // Match "key": null
        let nullPattern = #"\"(\w+)\"\s*:\s*null"#
        if let regex = try? NSRegularExpression(pattern: nullPattern) {
            let matches = regex.matches(in: json, range: NSRange(json.startIndex..., in: json))
            for match in matches {
                if let keyRange = Range(match.range(at: 1), in: json) {
                    let key = String(json[keyRange])
                    if !excludeSet.contains(key) && args[key] == nil {
                        args[key] = .null
                    }
                }
            }
        }

        // Match "key": number (integer or decimal)
        let numPattern = #"\"(\w+)\"\s*:\s*(-?\d+\.?\d*)\b"#
        if let regex = try? NSRegularExpression(pattern: numPattern) {
            let matches = regex.matches(in: json, range: NSRange(json.startIndex..., in: json))
            for match in matches {
                if let keyRange = Range(match.range(at: 1), in: json),
                   let valRange = Range(match.range(at: 2), in: json) {
                    let key = String(json[keyRange])
                    if !excludeSet.contains(key) && args[key] == nil {
                        let numStr = String(json[valRange])
                        if let dblVal = Double(numStr) {
                            args[key] = .number(dblVal)
                        }
                    }
                }
            }
        }

        // Match "key": true/false
        let boolPattern = #"\"(\w+)\"\s*:\s*(true|false)"#
        if let regex = try? NSRegularExpression(pattern: boolPattern) {
            let matches = regex.matches(in: json, range: NSRange(json.startIndex..., in: json))
            for match in matches {
                if let keyRange = Range(match.range(at: 1), in: json),
                   let valRange = Range(match.range(at: 2), in: json) {
                    let key = String(json[keyRange])
                    if !excludeSet.contains(key) && args[key] == nil {
                        args[key] = .bool(String(json[valRange]) == "true")
                    }
                }
            }
        }

        return args
    }

    // MARK: - Content-to-Arguments Rescue

    /// Rescues tool arguments that were mistakenly embedded within the content string by the LLM.
    private static func rescueArgumentsFromContent(toolName: String, content: String) -> [String: JSONValue]? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch toolName {
        case "execute_shell":
            var command = trimmed
            if command.hasPrefix("$") { command = String(command.dropFirst()).trimmingCharacters(in: .whitespaces) }
            let prosePrefixes = ["Running:", "Executing:", "Command:", "Execute:"]
            for prefix in prosePrefixes {
                if command.hasPrefix(prefix) {
                    command = String(command.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                }
            }
            guard !command.isEmpty else { return nil }
            return ["command": JSONValue.string(command)]

        case "list_directory", "read_file", "create_folder", "delete_file", "fs_read_metadata",
             "fs_watch_folder":
            if let path = extractPathFromContent(trimmed) {
                return ["path": JSONValue.string(path)]
            }

        case "fs_smart_search":
            return ["search_term": JSONValue.string(trimmed)]

        case "run_applescript":
            return ["script": JSONValue.string(trimmed)]

        case "open_application":
            let bundlePattern = #"(com\.[a-zA-Z0-9\-\.]+)"#
            if let regex = try? NSRegularExpression(pattern: bundlePattern),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let range = Range(match.range(at: 1), in: trimmed) {
                return ["bundle_identifier": JSONValue.string(String(trimmed[range]))]
            }

        default:
            break
        }

        return nil
    }

    /// Extracts a valid file system path from free-text using pattern matching.
    private static func extractPathFromContent(_ content: String) -> String? {
        let pathPattern = #"(~?/[^\s\"'<>|]+)"#
        if let regex = try? NSRegularExpression(pattern: pathPattern),
           let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
           let range = Range(match.range(at: 1), in: content) {
            return String(content[range]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - Markdown-Field Format Recovery

    /// Recovers content from a bare markdown-field format where the model output
    /// `content: <reasoning text>` and optionally `tool_calls: <value>` without JSON wrapping.
    ///
    /// This format occurs when models wrap field names in triple backticks (e.g. `` ```content``` ``)
    /// which the OutputSanitizer strips, leaving bare `content: ...` text with no JSON braces.
    private static func extractFromMarkdownFieldFormat(_ text: String) -> ModernCognitiveStep? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Must start with "content" followed by optional whitespace and colon
        guard let prefixRegex = try? NSRegularExpression(pattern: #"^content\s*:\s*"#),
              let prefixMatch = prefixRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let prefixRange = Range(prefixMatch.range, in: trimmed) else {
            return nil
        }

        // Extract everything after "content:"
        var reasoning = String(trimmed[prefixRange.upperBound...])

        // Strip trailing "tool_calls: <anything>" if present
        if let toolCallsSuffix = try? NSRegularExpression(pattern: #"\n\s*tool_calls\s*:.*$"#, options: .dotMatchesLineSeparators),
           let suffixMatch = toolCallsSuffix.firstMatch(in: reasoning, range: NSRange(reasoning.startIndex..., in: reasoning)),
           let suffixRange = Range(suffixMatch.range, in: reasoning) {
            reasoning = String(reasoning[..<suffixRange.lowerBound])
        }

        reasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reasoning.isEmpty else { return nil }

        return ModernCognitiveStep(reasoning: reasoning, toolCalls: [])
    }
}
