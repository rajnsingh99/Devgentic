// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowTemplate.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Renders `{{ … }}` templates for Code nodes in one pass: `input`, `input.json…`, `input.parsed…`, `var.…` placeholders.
/// Matches are found in the original template and replaced once, so substituted values are never re-scanned;
/// unresolved placeholders stay verbatim so a missing variable or bad path is visible in the output.
enum WorkflowTemplate {

    /// Renders `template`, substituting the supported `{{ … }}` placeholders.
    /// - Parameters: `input` is the raw upstream text, `inputJSON` the upstream structured output (if any),
    ///   and `variables` the workflow variables.
    static func render(
        _ template: String,
        input: String,
        inputJSON: JSONValue?,
        variables: [String: String]
    ) -> String {
        renderReportingUnresolved(template, input: input, inputJSON: inputJSON, variables: variables).rendered
    }

    // Why: an explicit expression, not an implicit `input.json` parse: that would make an unresolved warning resolve silently.
    /// The `{{ input.parsed… }}` prefix: parses this node's own input text as JSON, at any node.
    /// Separate from `input.json`, which reads a typed value a producing upstream declared (nil at an entry node).
    private static let parsedInputPrefix = "input.parsed"

    // Why: an unresolved placeholder stays verbatim so a bad path is visible; the returned list lets tool callers log it.
    /// `render`, plus the placeholder expressions that did not resolve.
    /// Callers that route arguments to tools use this and log; display-oriented callers may keep plain `render`.
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

        // Parsed at most once per render, and only when the template asks for it: `inputJSON` arrives typed,
        // but parsing `input` per placeholder would re-parse the whole input each time.
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

    // Why: one regex for both: a lint with its own pattern could disagree with the engine about what a placeholder is.
    /// The placeholder pattern, compiled once and shared by the renderer and `referencedVariableNames(in:)`.
    /// `NSRegularExpression` is thread-safe for matching.
    private static let placeholderRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#)

    // Why: both names are authorable, so a lint needs this ordered union; the trim covers `{{ var. status }}`.
    /// The variable names a `{{ var.… }}` expression may resolve to, in the order `resolve` tries them:
    /// exact key, then first dot segment. Empty for anything that is not a `var.` reference.
    nonisolated static func variableCandidates(for expr: String) -> [String] {
        guard expr.hasPrefix("var.") else { return [] }
        let remainder = String(expr.dropFirst("var.".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return [] }
        let segments = remainder.split(separator: ".").map(String.init)
        guard segments.count >= 2 else { return [remainder] }
        return [remainder, segments[0]]
    }

    /// Every `{{ var.… }}` reference in a template, as one ordered candidate list per placeholder.
    /// The `input` family is excluded by `variableCandidates`, so `{{ input.json.status }}` is not read as a variable.
    /// Pure and `nonisolated`: the design-time lint and the runtime resolver read the same functions.
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
        // `input.parsed…`: the author asserting the input text is JSON; the caller parses it once per render.
        if expr == parsedInputPrefix { return parsedInput?.templateString }
        if expr.hasPrefix(parsedInputPrefix + ".") {
            let path = String(expr.dropFirst((parsedInputPrefix + ".").count))
            return parsedInput?.value(atDotPath: path)?.templateString
        }

        // var family: the candidate names and their order come from `variableCandidates`, which the design-time lint also reads.
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
