// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatTemplateFingerprinter.swift
//  Devgentic
//
//  Phase 1 — Dialect taxonomy expansion (2026-04-22).
//  Analyzes a raw Jinja chat_template string extracted from tokenizer_config.json
//  and identifies the exact native tool-calling dialect the model was trained on.
//  Takes precedence over special-token substring scans in MLXTokenizerAnalyzer
//  because the chat template is ground truth for how the model renders tool calls.
//
//  Each rule inspects structural markers in the Jinja source itself (string literals,
//  property references, tag names, key order) rather than special tokens alone —
//  two models can share tool tokens but emit formats with different key semantics
//  (e.g., Llama uses "parameters", Qwen uses "arguments").
//

import Foundation
import OSLog

private let logger = DGLogger(category: "ChatTemplateFingerprinter")

/// Inspects a raw Jinja chat_template and returns the specific `ModelDialect`
/// the model was trained to emit for tool calls.
///
/// Returns `nil` if no known fingerprint matches — caller falls back to the
/// legacy special-token heuristic in `MLXTokenizerAnalyzer`.
enum ChatTemplateFingerprinter {

    /// Top-level dispatch. Rules ordered most-specific first — more specific fingerprints
    /// (those looking for distinctive literal markers) run before looser structural ones.
    ///
    /// Logs the matched dialect on hit, and the miss on miss, so operators can trace
    /// why a particular model got routed to a given dialect.
    static func detect(chatTemplate: String) -> ModelDialect? {
        // 1. DeepSeek V3.2 — brand new `<｜DSML｜...>` XML namespace (most specific).
        if isDeepSeekV32Template(chatTemplate) {
            logger.info("Fingerprint matched: .deepseekV32Dsml (DeepSeek-V3.2 DSML XML)")
            return .deepseekV32Dsml
        }

        // 2. DeepSeek V3.1 — full-width pipes but NO code fence rendering (distinct from V3).
        //    Must run before V3's rule to avoid misclassification.
        if isDeepSeekV31Template(chatTemplate) {
            logger.info("Fingerprint matched: .deepseekV31Flat (DeepSeek-V3.1 no-fence)")
            return .deepseekV31Flat
        }

        // 3. DeepSeek V3 — full-width Unicode pipes + code fence rendering.
        if isDeepSeekV3Template(chatTemplate) {
            logger.info("Fingerprint matched: .deepseekV3JsonFence (DeepSeek-V3 / DeepSeek-R1)")
            return .deepseekV3JsonFence
        }

        // 4. Phi-4-mini functools — distinctive `functools[` literal.
        if isPhiFunctoolsTemplate(chatTemplate) {
            logger.info("Fingerprint matched: .phiFunctoolsBracket (Phi-4-mini / Firefunction-v2)")
            return .phiFunctoolsBracket
        }

        // 5. Command-R7B — distinctive `<|START_ACTION|>` token.
        //    Must run before older Command-R rule (which has weaker signals).
        if isCommandR7BTemplate(chatTemplate) {
            logger.info("Fingerprint matched: .commandR7BAction (Command-R7B / Command-A)")
            return .commandR7BAction
        }

        // 6. Command-R / R+ — `Action:` markdown directive + `tool_name` key (unique to Cohere).
        if isCommandRTemplate(chatTemplate) {
            logger.info("Fingerprint matched: .commandRAction (Command-R / Command-R+)")
            return .commandRAction
        }

        // 7. Qwen3-Coder deep XML — distinctive `<function=` + `<parameter=` co-occurrence.
        //    Must run before generic Qwen rule since Qwen3-Coder also mentions `<tool_call>`.
        if isQwen3CoderDeepXmlTemplate(chatTemplate) {
            logger.info("Fingerprint matched: .qwen3CoderDeepXml (Qwen3-Coder 30B/480B)")
            return .qwen3CoderDeepXml
        }

        // 8. Granite 3.x — `<|start_of_role|>` + array rendering (`tool_calls | map` or `tool_calls | tojson`).
        //    Must run before Granite 4 since both share `<|start_of_role|>`.
        if isGraniteLegacyTemplate(chatTemplate) {
            logger.info("Fingerprint matched: .graniteLegacyArray (Granite 3.0/3.1/3.2/3.3)")
            return .graniteLegacyArray
        }

        // 9. Granite 4.x — `<|start_of_role|>` + per-tool-call loop rendering.
        if isGranite4Template(chatTemplate) {
            logger.info("Fingerprint matched: .granite4ToolCall (Granite 4.x)")
            return .granite4ToolCall
        }

        // 10. Mistral v11 — has BOTH `[TOOL_CALLS]` AND `[ARGS]` literals.
        //    Must run before v3 which only looks for `[TOOL_CALLS]`.
        if isMistralV11Template(chatTemplate) {
            logger.info("Fingerprint matched: .mistralV11Flat (Mistral 2025+ flat syntax)")
            return .mistralV11Flat
        }

        // 11. Mistral v3 — `[TOOL_CALLS]` + JSON array rendering, older Tekken tokenizer.
        if isMistralV3Template(chatTemplate) {
            logger.info("Fingerprint matched: .mistralV3Array (Mistral v0.3 / Nemo / Mixtral)")
            return .mistralV3Array
        }

        // 12. Pythonic — Llama 3.2 1B/3B + xLAM. Template often reuses Llama 3.x base
        //    but the MODEL outputs pythonic — detect by explicit pythonic example in
        //    the template OR distinctive `|python_start|` / `|python_end|` markers.
        //    Must run before generic Llama 3 rule (which matches the same `parameters` key).
        if isPythonicTemplate(chatTemplate) {
            logger.info("Fingerprint matched: .pythonicBracketList (Llama-3.2 small / xLAM / ToolACE)")
            return .pythonicBracketList
        }

        // 13. Llama 3.x — uses `"parameters"` key (the distinguishing marker vs Qwen's `"arguments"`).
        //    Must run before Qwen/Hermes since both use JSON but with different key names.
        if isLlama3Template(chatTemplate) {
            logger.info("Fingerprint matched: .llama3JsonSingle (Llama-3.1/3.2/3.3)")
            return .llama3JsonSingle
        }

        // 14. Qwen/Hermes — uses `"arguments"` key in `<tool_call>` wrapper.
        if isQwenHermesTemplate(chatTemplate) {
            logger.info("Fingerprint matched: .qwenHermesToolCall (Qwen2.5/3, Hermes-2/3-Pro)")
            return .qwenHermesToolCall
        }

        logger.info("Fingerprint: no match — caller will fall back to token heuristics")
        return nil
    }

    // MARK: - Rules

    /// Qwen2.5/3 Instruct, Qwen3 base, Hermes-2-Pro, Hermes-3, and structurally
    /// identical fine-tunes.
    ///
    /// Canonical Jinja fragment for this family:
    /// ```
    /// {%- for tool_call in message.tool_calls %}
    ///     {{- '<tool_call>\n{"name": "' }}
    ///     {{- tool_call.name }}
    ///     {{- '", "arguments": ' }}
    ///     {{- tool_call.arguments | tojson }}
    ///     {{- '}\n</tool_call>' }}
    /// {%- endfor %}
    /// ```
    ///
    /// Distinguishing properties vs. related formats:
    /// - Singular `<tool_call>` tag (Jamba/MiniMax use plural `<tool_calls>`; Granite 3.0 uses `<|tool_call|>`).
    /// - Per-iteration loop over `message.tool_calls` rendering one JSON object per block
    ///   (Granite 3.1+ / MiniMax-M1 render a single JSON ARRAY inside one wrapper).
    /// - `"name"` key hardcoded before `"arguments"` in the template literals.
    /// - Not a deep-XML format (Qwen-Coder uses `<function=...><parameter=...>`).
    private static func isQwenHermesTemplate(_ t: String) -> Bool {
        // 1. Must emit the singular `<tool_call>` wrapper.
        guard t.contains("<tool_call>") else { return false }

        // 2. Exclude Jamba/MiniMax/Hunyuan plural `<tool_calls>` wrapper dialects.
        if t.contains("<tool_calls>") { return false }

        // 3. Exclude Qwen3-Coder deep-XML (has `<function=` children inside the wrapper).
        if t.contains("<function=") { return false }

        // 4. Must render per-tool properties inside a loop, NOT serialize the whole array.
        //    Granite-style templates emit `tool_calls | tojson` (array-at-once);
        //    Qwen/Hermes reference `tool_call.name` / `tool_call.arguments` individually.
        let hasPerToolReference =
            t.contains("tool_call.name") ||
            t.contains("tool_call.function.name") ||
            t.contains("tool_call[\"name\"]") ||
            t.contains("tool_call['name']")

        let rendersArrayAtOnce =
            t.contains("tool_calls | tojson") ||
            t.contains("tool_calls|tojson") ||
            t.contains("tool_calls | map")

        if rendersArrayAtOnce { return false }
        guard hasPerToolReference else { return false }

        // 5. Must reference the `arguments` key (Llama 3 uses `parameters` instead —
        //    that's a different dialect routed elsewhere).
        let usesArgumentsKey =
            t.contains("tool_call.arguments") ||
            t.contains("tool_call[\"arguments\"]") ||
            t.contains("tool_call['arguments']") ||
            t.contains("\"arguments\"")

        return usesArgumentsKey
    }

    /// Llama-3.1 / 3.2 / 3.3 JSON native format.
    ///
    /// Canonical Jinja fragment (from meta-llama's tool_use chat template):
    /// ```
    /// {%- if tools is not none %}
    ///     You have access to the following functions...
    ///     {%- for t in tools %}
    ///         {{- t | tojson(indent=4) }}
    ///     {%- endfor %}
    ///     ...
    ///     Return a JSON object: {"name": function name, "parameters": dictionary...
    /// {%- endif %}
    /// ```
    ///
    /// Distinguishing properties:
    /// - Uses `"parameters"` key literal (Qwen/Hermes use `"arguments"`).
    /// - Often references `<|python_tag|>` for builtin-tool routing.
    /// - Template raises exception for `len(message.tool_calls) > 1` — single-call-only.
    /// - Uses `<|eot_id|>` or `<|eom_id|>` turn terminators (distinct from `<|im_end|>`).
    private static func isLlama3Template(_ t: String) -> Bool {
        // 1. Must mention `parameters` key — the distinguishing marker.
        let usesParametersKey =
            t.contains("\"parameters\"") ||
            t.contains("tool_call.parameters") ||
            t.contains("'parameters'")
        guard usesParametersKey else { return false }

        // 2. Must NOT use `arguments` as the primary key (that's Qwen/Hermes).
        //    Allow `arguments` in comments/descriptions but not as emitted key.
        //    Heuristic: if `"parameters"` AND a loop over tools exists, it's Llama-style.
        let hasToolLoop =
            t.contains("{%- for t in tools") ||
            t.contains("{% for t in tools") ||
            t.contains("{%- for tool in tools") ||
            t.contains("{% for tool in tools")
        guard hasToolLoop else { return false }

        // 3. Llama-specific terminators or markers (any one is enough signal).
        let hasLlamaMarkers =
            t.contains("<|eot_id|>") ||
            t.contains("<|eom_id|>") ||
            t.contains("<|python_tag|>") ||
            t.contains("<|start_header_id|>")

        return hasLlamaMarkers
    }

    /// Mistral v3 (Tekken tokenizer) — JSON array format.
    ///
    /// Canonical Jinja fragment:
    /// ```
    /// {%- if tools %}
    ///     [AVAILABLE_TOOLS]{{ tools | tojson }}[/AVAILABLE_TOOLS]
    /// {%- endif %}
    /// ...
    /// [TOOL_CALLS][{"name": ..., "arguments": ..., "id": "xxxxxxxxx"}]</s>
    /// ```
    ///
    /// Distinguishing properties:
    /// - Has `[AVAILABLE_TOOLS]` literal (tool definitions go in brackets).
    /// - Has `[TOOL_CALLS]` literal (calls go in brackets).
    /// - Renders tool_calls as JSON **array** (vs v11 which emits flat name+ARGS).
    /// - Does NOT contain `[ARGS]` literal (that's v11's marker).
    /// - Uses `<s>` / `</s>` tokens (Tekken tokenizer family).
    private static func isMistralV3Template(_ t: String) -> Bool {
        // 1. Must have both [TOOL_CALLS] AND [AVAILABLE_TOOLS] literals.
        guard t.contains("[TOOL_CALLS]"), t.contains("[AVAILABLE_TOOLS]") else { return false }
        // 2. MUST NOT have [ARGS] literal — that's v11's distinguishing marker.
        if t.contains("[ARGS]") { return false }
        return true
    }

    /// Mistral v11 (2025+ flat syntax) — name+ARGS marker format.
    ///
    /// Canonical Jinja fragment:
    /// ```
    /// {%- for tool_call in message.tool_calls %}
    ///     [TOOL_CALLS]{{ tool_call.name }}[ARGS]{{ tool_call.arguments | tojson }}
    /// {%- endfor %}
    /// ```
    ///
    /// Distinguishing properties:
    /// - Has `[TOOL_CALLS]` AND `[ARGS]` literals co-occurring.
    /// - Parallel calls = multiple concatenated `[TOOL_CALLS]name[ARGS]{...}` blocks.
    /// - Models: Mistral-Small-3.1+, Devstral-Small-2505+, Mistral-Medium 2025+.
    private static func isMistralV11Template(_ t: String) -> Bool {
        // Both literals co-occur only in v11; v3 has [TOOL_CALLS] but never [ARGS].
        return t.contains("[TOOL_CALLS]") && t.contains("[ARGS]")
    }

    /// Phi-4-mini Instruct / Firefunction-v2 `functools[]` format.
    ///
    /// Canonical output:
    /// ```
    /// functools[{"name": "search", "arguments": {"q": "weather"}}]
    /// ```
    ///
    /// Template renders the literal `functools[` as the opening marker.
    /// Very distinctive — no other mainstream family uses this marker.
    private static func isPhiFunctoolsTemplate(_ t: String) -> Bool {
        return t.contains("functools[")
    }

    /// DeepSeek-V3 / DeepSeek-R1 native tool format.
    ///
    /// Uses full-width Unicode tokens (U+FF5C for pipes, U+2581 for underscore):
    /// ```
    /// <｜tool▁calls▁begin｜><｜tool▁call▁begin｜>function<｜tool▁sep｜>name
    /// ```json
    /// {"arg":"value"}
    /// ```<｜tool▁call▁end｜><｜tool▁calls▁end｜>
    /// ```
    ///
    /// Distinguishing properties:
    /// - Contains `<｜tool▁sep｜>` or `<｜tool▁calls▁begin｜>` (full-width chars).
    /// - Must NOT confuse with ASCII `<|tool_call|>` (Granite) or `<|tool_sep|>` if any.
    /// - DeepSeek-R1-Distill-Llama/Qwen variants do NOT use this — they inherit the
    ///   host family's template. Only pure DeepSeek-V3/R1 match.
    private static func isDeepSeekV3Template(_ t: String) -> Bool {
        // Full-width pipe `｜` = U+FF5C; full-width underscore `▁` = U+2581.
        // These are the distinctive Unicode characters that distinguish DeepSeek's
        // custom tokens from Granite's ASCII-pipe `<|tool_call|>` style.
        let deepseekMarkers = [
            "<｜tool▁sep｜>",
            "<｜tool▁calls▁begin｜>",
            "<｜tool▁call▁begin｜>",
            "<｜DSML｜"   // future-proof hint for V3.2 DSML format (not yet supported but detect family)
        ]
        return deepseekMarkers.contains { t.contains($0) }
    }

    /// Pythonic bracket-list format used by small Llama 3.2 variants (1B/3B Instruct),
    /// Salesforce xLAM-2, Team-ACE ToolACE-8B, and Llama 4 in pythonic mode.
    ///
    /// Canonical output:
    /// ```
    /// [list_directory(path="/tmp"), write_file(path="/tmp/a.txt", content="hi")]
    /// ```
    ///
    /// Detection challenge: Llama 3.2 1B/3B use the SAME chat_template as Llama 3.1/3.3
    /// (which fingerprints as `.llama3JsonSingle`), but the MODEL is trained to emit
    /// pythonic. Fingerprinting pure template text usually cannot distinguish them.
    ///
    /// We match when we see explicit pythonic-mode template hints:
    /// - `<|python_start|>` / `<|python_end|>` (Llama 4 pythonic mode)
    /// - A pythonic example in the template instruction text
    /// - Distinctive xLAM template signature
    ///
    /// If none match, Llama 3.2 1B/3B fall through to `.llama3JsonSingle` — our
    /// Llama3JsonParser is the right catch since those models OFTEN drift to flat JSON too.
    /// Users can manually pin `.pythonicBracketList` in ProviderConfig to force this path.
    private static func isPythonicTemplate(_ t: String) -> Bool {
        // 1. Explicit pythonic markers (Llama 4).
        if t.contains("<|python_start|>") || t.contains("<|python_end|>") {
            return true
        }
        // 2. Template instructs pythonic format explicitly in its rendered text.
        //    e.g. "Respond with [func_name(args)]" or "Python list of function calls"
        if t.contains("pythonic") || t.contains("Python list of function") {
            return true
        }
        // 3. xLAM / ToolACE — look for distinctive instruction phrases found in their
        //    published chat_templates. (Kept loose; if other families accidentally
        //    match, heuristic drift recovery will still save the parse.)
        if t.contains("[func_name(") || t.contains("Respond with a list of function calls") {
            return true
        }
        return false
    }

    /// DeepSeek V3.2 — brand new `<｜DSML｜...>` XML namespace (late 2025+).
    ///
    /// Canonical output:
    /// ```
    /// <｜DSML｜function_calls>
    ///   <｜DSML｜invoke name="get_weather">
    ///     <｜DSML｜parameter name="location" string="true">Seattle</｜DSML｜parameter>
    ///   </｜DSML｜invoke>
    /// </｜DSML｜function_calls>
    /// ```
    ///
    /// Full-width pipes `｜` (U+FF5C) preserved from earlier DeepSeek tokenizers.
    /// Detection: `<｜DSML｜` substring appears in template (rendered or as instruction).
    private static func isDeepSeekV32Template(_ t: String) -> Bool {
        return t.contains("<\u{FF5C}DSML\u{FF5C}")
    }

    /// DeepSeek V3.1 — same full-width pipe tokens as V3, but the template renders
    /// arguments flat (no ````json ... ``` ` code fence).
    ///
    /// Distinguishing from V3: V3's template includes ` ```json\n{args}\n``` ` literal;
    /// V3.1 does not render a fence around arguments.
    private static func isDeepSeekV31Template(_ t: String) -> Bool {
        // Must have V3-family full-width pipes.
        let hasDeepSeekMarkers =
            t.contains("<\u{FF5C}tool\u{2581}sep\u{FF5C}>") ||
            t.contains("<\u{FF5C}tool\u{2581}calls\u{2581}begin\u{FF5C}>")
        guard hasDeepSeekMarkers else { return false }

        // V3.1 signature: no fenced JSON block in the template. V3 emits `` ```json `` literal.
        let hasFenceRendering = t.contains("```json") || t.contains("``` json")
        return !hasFenceRendering
    }

    /// Cohere Command-R7B (Dec 2024+) and Command-A — distinctive `<|START_ACTION|>` token.
    ///
    /// Canonical output:
    /// ```
    /// <|START_OF_TURN_TOKEN|><|CHATBOT_TOKEN|><|START_ACTION|>[
    ///     {"tool_call_id": "0", "tool_name": "search", "parameters": {"q": "x"}}
    /// ]<|END_ACTION|><|END_OF_TURN_TOKEN|>
    /// ```
    ///
    /// Explicit `tool_call_id` is distinctive vs older Command-R.
    private static func isCommandR7BTemplate(_ t: String) -> Bool {
        return t.contains("<|START_ACTION|>") || t.contains("<|END_ACTION|>")
    }

    /// Cohere Command-R / Command-R+ — markdown `Action:` directive + JSON list
    /// using `tool_name` + `parameters` keys (unique key-naming combo for Cohere).
    ///
    /// Canonical output:
    /// ```
    /// Action: ```json
    /// [
    ///     {"tool_name": "search", "parameters": {"q": "weather"}}
    /// ]
    /// ```
    /// ```
    private static func isCommandRTemplate(_ t: String) -> Bool {
        // Needs Action: directive + tool_name key mention (distinguishes from Llama3's parameters).
        guard t.contains("Action:") else { return false }
        return t.contains("\"tool_name\"") || t.contains("tool_name") && t.contains("<|CHATBOT_TOKEN|>")
    }

    /// Qwen3-Coder deep XML — `<function=NAME><parameter=KEY>value</parameter></function>`
    /// wrapped in `<tool_call>...</tool_call>`.
    ///
    /// Canonical output:
    /// ```
    /// <tool_call>
    /// <function=read_file>
    /// <parameter=path>
    /// /path/to/file.txt
    /// </parameter>
    /// </function>
    /// </tool_call>
    /// ```
    ///
    /// Distinguishing from Qwen2.5/3 base: has `<function=` AND `<parameter=` literals.
    private static func isQwen3CoderDeepXmlTemplate(_ t: String) -> Bool {
        return t.contains("<function=") && t.contains("<parameter=")
    }

    /// IBM Granite 3.0 / 3.1 / 3.2 / 3.3 — array-at-once rendering.
    ///
    /// Canonical output:
    ///   3.0: `<|tool_call|>[{"name":"X","arguments":{...}}, ...]<|end_of_text|>`
    ///   3.1+: `<tool_call>[{"name":"X","arguments":{...}}, ...]`
    ///
    /// Both versions: template renders `tool_calls | map('function') | tojson(...)`
    /// — emits the whole array at once, not per-call loop.
    ///
    /// Distinguishing from Granite 4: template has array-at-once render, NOT per-tool-call loop.
    private static func isGraniteLegacyTemplate(_ t: String) -> Bool {
        // Must have Granite role markers.
        let hasGraniteMarkers =
            t.contains("<|start_of_role|>") ||
            t.contains("<|end_of_role|>")
        guard hasGraniteMarkers else { return false }

        // Array-at-once render: `tool_calls | tojson` or `tool_calls | map`.
        let rendersArrayAtOnce =
            t.contains("tool_calls | tojson") ||
            t.contains("tool_calls|tojson") ||
            t.contains("tool_calls | map") ||
            t.contains("tool_calls|map")

        return rendersArrayAtOnce
    }

    /// IBM Granite 4.x — single-object `<tool_call>{JSON}</tool_call>` per call
    /// (Qwen-style). Distinguished from Granite 3.x by per-tool-call loop rendering.
    ///
    /// Canonical output: `<tool_call>{"name":"X","arguments":{...}}</tool_call>`
    /// (or multiple such blocks for parallel calls).
    private static func isGranite4Template(_ t: String) -> Bool {
        let hasGraniteMarkers =
            t.contains("<|start_of_role|>") ||
            t.contains("<|end_of_role|>")
        guard hasGraniteMarkers else { return false }

        // Per-tool-call loop — same signature as Qwen.
        let hasPerToolLoop =
            t.contains("tool_call.name") ||
            t.contains("tool_call.arguments")

        // Must NOT be array-at-once (that's 3.x).
        let rendersArrayAtOnce =
            t.contains("tool_calls | tojson") || t.contains("tool_calls | map")

        return hasPerToolLoop && !rendersArrayAtOnce
    }
}
