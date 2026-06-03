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
        guard template.contains("{{") else { return template }
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#) else {
            return template
        }

        let ns = template as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: template, range: fullRange)
        guard !matches.isEmpty else { return template }

        var result = ""
        var cursor = 0
        for match in matches {
            let whole = match.range
            // Text between the previous placeholder and this one.
            if whole.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: whole.location - cursor))
            }
            let expr = ns.substring(with: match.range(at: 1))
            if let resolved = resolve(expr, input: input, inputJSON: inputJSON, variables: variables) {
                result += resolved
            } else {
                result += ns.substring(with: whole) // leave the placeholder untouched
            }
            cursor = whole.location + whole.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return result
    }

    /// Resolves a single placeholder expression to its replacement text, or `nil`
    /// when it can't be resolved (placeholder is then left verbatim by the caller).
    private static func resolve(
        _ expr: String,
        input: String,
        inputJSON: JSONValue?,
        variables: [String: String]
    ) -> String? {
        // --- input family ---
        if expr == "input" { return input }
        if expr == "input.json" { return inputJSON?.templateString }
        if expr.hasPrefix("input.json.") {
            let path = String(expr.dropFirst("input.json.".count))
            return inputJSON?.value(atDotPath: path)?.templateString
        }

        // --- var family ---
        if expr.hasPrefix("var.") {
            let remainder = String(expr.dropFirst("var.".count))
            guard !remainder.isEmpty else { return nil }

            // Exact key match first — preserves variable names that contain dots
            // and keeps the common `{{ var.name }}` case backward-compatible.
            if let raw = variables[remainder] { return raw }

            // Otherwise treat the first segment as the variable name and the rest
            // as a JSON path into that variable's value (lazy-parsed as JSON).
            let segments = remainder.split(separator: ".").map(String.init)
            guard segments.count >= 2, let raw = variables[segments[0]] else { return nil }
            guard let json = JSONValue.parseStructured(raw) else { return nil }
            return json.value(at: Array(segments.dropFirst()))?.templateString
        }

        return nil
    }
}
