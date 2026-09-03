//
//  WorkflowTemplate.swift
//  Devgentic
//
//  Mustache-style template rendering for Code nodes, extended with JSON path
//  access. Resolves these placeholder forms in a single pass:
//
//    {{ input }}              → raw upstream text
//    {{ input.json }}         → upstream structured output, as compact JSON
//    {{ input.json.a.b.0 }}   → a field/array-index path into the structured output
//    {{ input.parsed }}       → THIS node's input text, parsed as JSON
//    {{ input.parsed.a.b.0 }} → a path into that
//    {{ var.name }}           → a workflow variable (raw string)
//    {{ var.name.a.b }}       → a JSON path into a variable that holds JSON text
//
//  Single-pass design is intentionally injection-safe: matches are located in the
//  *original* template and each is replaced exactly once, so substituted values
//  (which may themselves contain `{{ var.x }}`-looking text) are never re-scanned.
//  This replaces the previous two-step `replacingOccurrences` ordering hack.
//
//  Unresolved placeholders are left verbatim — a missing variable or bad path
//  surfaces visibly in the output rather than silently becoming empty.
//

import Foundation

enum WorkflowTemplate {

    /// Renders `template`, substituting the supported `{{ … }}` placeholders.
    /// - Parameters:
    ///   - template: The raw template string.
    ///   - input: Raw upstream text (for `{{ input }}`).
    ///   - inputJSON: Upstream structured output, if any (for `{{ input.json… }}`).
    ///   - variables: Workflow variables (for `{{ var.… }}`).
    static func render(
        _ template: String,
        input: String,
        inputJSON: JSONValue?,
        variables: [String: String]
    ) -> String {
        renderReportingUnresolved(template, input: input, inputJSON: inputJSON, variables: variables).rendered
    }

    /// The `{{ input.parsed… }}` prefix (register EIO-11).
    ///
    /// ⚠️ **DELIBERATELY SEPARATE FROM `input.json`, and the distinction is the design.**
    /// `input.json` means "a producing upstream DECLARED structured output" — it reads a typed
    /// `JSONValue` that some node actually emitted, and it is nil at a top-level entry node because
    /// nothing upstream produced anything. `input.parsed` means "parse whatever text is in my input
    /// slot", which at an entry node is the user's message.
    ///
    /// The row this closes asked for the implicit version: make an entry node's `{{ input.json.x }}`
    /// parse the chat box. That was rejected for three reasons, all still true.
    ///   • It converts a FAIL-LOUD into a FAIL-SILENT for one binding shape. Today an unresolvable
    ///     `{{ input.json.city }}` fires the EIO-6 unresolved-placeholder warning and the tool
    ///     rejects the literal; afterwards it would resolve quietly to whatever the message author
    ///     put there. That is the opposite direction from EIO-6 and EIO-8, both of which were fixed
    ///     by making this exact family of failures LOUDER.
    ///   • `JSONValue.parseStructured` extracts JSON from a ```-fenced block inside ordinary prose,
    ///     so an implicit rule would let a normal-looking Slack or Discord message silently become
    ///     the run's structured input. (This is not a new capability — `WorkflowActionArgs.coerce`
    ///     already parses remote text for `array`/`object` parameters — but it would become one the
    ///     author never asked for.)
    ///   • It would have to land at FOUR entry seams (the Code arm, the Action arm, the
    ///     sub-workflow inherit, the entry-skip pass-through) or those surfaces would disagree about
    ///     what the chat box is — this register's dominant failure mode.
    /// Making it an expression the author TYPES removes all three: the assertion is at the call
    /// site, it works at every node rather than only at an entry one, and `{{ input.json… }}` keeps
    /// the meaning four in-app help strings already promise.
    private static let parsedInputPrefix = "input.parsed"

    /// `render`, plus the placeholder EXPRESSIONS that did not resolve (register EIO-6).
    ///
    /// ⚠️ Leaving an unresolved placeholder verbatim in the output is deliberate and stays — a bad
    /// path being VISIBLE in the rendered text is the design. What was missing is the report: an
    /// Action node coerced the literal `{{ var.status }}` into a tool argument and neither layer
    /// said a word, so the tool failed (or acted on placeholder text) with nothing in the log
    /// naming which binding, which expression, or the consequence. Callers that route arguments to
    /// TOOLS use this and log; display-oriented callers may keep plain `render`.
    static func renderReportingUnresolved(
        _ template: String,
        input: String,
        inputJSON: JSONValue?,
        variables: [String: String]
    ) -> (rendered: String, unresolved: [String]) {
        guard template.contains("{{") else { return (template, []) }
        guard let regex = placeholderRegex else { return (template, []) }

        let ns = template as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: template, range: fullRange)
        guard !matches.isEmpty else { return (template, []) }

        // [EIO-11] Parsed at most ONCE per render, and only when the template asks for it — the
        // asymmetry with `inputJSON` (which arrives already typed) would otherwise mean one parse
        // of the whole input per placeholder.
        //
        // ⚠️ The `contains` gate is a COST optimisation, not a behavioural one: removing it is an
        // EQUIVALENT MUTANT and survives the battery on purpose. Every template that never writes
        // `input.parsed` would simply parse its input and throw the result away. Noted so the
        // survivor is a known equivalent rather than an unexplained one.
        let parsedInput: JSONValue? = template.contains(parsedInputPrefix)
            ? JSONValue.parseStructured(input) : nil

        var result = ""
        var unresolved: [String] = []
        var cursor = 0
        for match in matches {
            let whole = match.range
            // Text between the previous placeholder and this one.
            if whole.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: whole.location - cursor))
            }
            let expr = ns.substring(with: match.range(at: 1))
            if let resolved = resolve(expr, input: input, inputJSON: inputJSON,
                                      parsedInput: parsedInput, variables: variables) {
                result += resolved
            } else {
                result += ns.substring(with: whole) // leave the placeholder untouched
                unresolved.append(expr)
            }
            cursor = whole.location + whole.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return (result, unresolved)
    }

    /// THE placeholder pattern. ⚠️ Compiled ONCE and shared by the renderer and
    /// `referencedVariableNames(in:)` — a design-time lint that found placeholders with its own
    /// regex could disagree with the engine about what even IS a placeholder, which is the drift
    /// register `EXA-10` was filed to prevent. `NSRegularExpression` is thread-safe for matching.
    private static let placeholderRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#)

    /// The variable names a `{{ var.… }}` expression may resolve to, IN THE ORDER `resolve` tries
    /// them: the exact key first, then the first dot segment. Empty for anything that is not a
    /// `var.` reference.
    ///
    /// ⚠️ FACTORED OUT OF `resolve`, which now calls it — the ordering is defined in exactly one
    /// place. A lint that re-implemented "which variable does this reference" would false-warn on
    /// canvases that run: for `{{ var.result.status }}`, an exact-key-only reader warns when the
    /// canvas writes `result`, and a first-segment-only reader warns when it writes `result.status`.
    /// BOTH names are authorable — `outputVariable` is an unvalidated free-text field, so a dotted
    /// variable name is storable — so only the ordered UNION is correct.
    ///
    /// ⚠️ The trim is EIO-5's and is load-bearing twice over: the regex already strips the outer
    /// whitespace, and this strips what a user typed as `{{ var. status }}`. Skipping it makes a
    /// lint extract `" status"`, which no writer set contains, so it false-warns on a template the
    /// engine resolves fine — EIO-5's exact bug, re-created one layer up.
    nonisolated static func variableCandidates(for expr: String) -> [String] {
        guard expr.hasPrefix("var.") else { return [] }
        let remainder = String(expr.dropFirst("var.".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return [] }
        let segments = remainder.split(separator: ".").map(String.init)
        guard segments.count >= 2 else { return [remainder] }
        return [remainder, segments[0]]
    }

    /// Every `{{ var.… }}` reference in a template, as one ordered candidate list per placeholder
    /// (register EXA-10). The `input` family is excluded by `variableCandidates`, so
    /// `{{ input.json.status }}` is never mistaken for a variable read.
    ///
    /// Pure and `nonisolated` (WF-UI5) so the extraction is truth-tableable — and so the DESIGN-TIME
    /// lint and the RUNTIME resolver read the same two functions rather than two parsers.
    nonisolated static func referencedVariableNames(in template: String) -> [[String]] {
        guard template.contains("{{"), let regex = placeholderRegex else { return [] }
        let ns = template as NSString
        return regex.matches(in: template, range: NSRange(location: 0, length: ns.length))
            .map { variableCandidates(for: ns.substring(with: $0.range(at: 1))) }
            .filter { !$0.isEmpty }
    }

    /// Resolves a single placeholder expression to its replacement text, or `nil`
    /// when it can't be resolved (placeholder is then left verbatim by the caller).
    private static func resolve(
        _ expr: String,
        input: String,
        inputJSON: JSONValue?,
        parsedInput: JSONValue?,
        variables: [String: String]
    ) -> String? {
        // --- input family ---
        if expr == "input" { return input }
        if expr == "input.json" { return inputJSON?.templateString }
        if expr.hasPrefix("input.json.") {
            let path = String(expr.dropFirst("input.json.".count))
            return inputJSON?.value(atDotPath: path)?.templateString
        }
        // [EIO-11] `input.parsed…` — the author asserting "treat my input text as JSON". See
        // `parsedInputPrefix` for why this is an explicit expression rather than a change to
        // `input.json`'s meaning. `parsedInput` is parsed ONCE per render by the caller, not once
        // per placeholder, so a template with ten references parses one time.
        if expr == parsedInputPrefix { return parsedInput?.templateString }
        if expr.hasPrefix(parsedInputPrefix + ".") {
            let path = String(expr.dropFirst((parsedInputPrefix + ".").count))
            return parsedInput?.value(atDotPath: path)?.templateString
        }

        // --- var family ---
        // ⚠️ The candidate NAMES and their ORDER come from `variableCandidates`, which the
        // design-time lint reads too (register EXA-10). Deriving them here as well is what would
        // let the panel and the engine disagree about which variable a placeholder means.
        let candidates = variableCandidates(for: expr)
        guard let exact = candidates.first else { return nil }

        // Exact key match first — preserves variable names that contain dots
        // and keeps the common `{{ var.name }}` case backward-compatible.
        if let raw = variables[exact] { return raw }

        // Otherwise treat the first segment as the variable name and the rest
        // as a JSON path into that variable's value (lazy-parsed as JSON).
        guard candidates.count >= 2, let raw = variables[candidates[1]] else { return nil }
        guard let json = JSONValue.parseStructured(raw) else { return nil }
        let segments = exact.split(separator: ".").map(String.init)
        return json.value(at: Array(segments.dropFirst()))?.templateString
    }
}
