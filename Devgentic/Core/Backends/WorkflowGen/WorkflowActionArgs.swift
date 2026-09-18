// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowActionArgs.swift
//  Devgentic
//
//  Assembles a tool's JSON arguments for an Action node from its per-argument
//  template bindings. Each binding is resolved against the upstream data via
//  `WorkflowTemplate`, then coerced to the JSON type the tool's parameter schema
//  declares (string / number / integer / boolean / array / object) so the tool's
//  `Decodable` arguments decode cleanly.
//
//  Unbound arguments (no binding, or a whitespace-only template) are omitted —
//  optional tool args fall back to their defaults; a missing *required* arg
//  surfaces as a clear decode error from the tool wrapper at run time.
//

import Foundation

private let logger = DGLogger(category: "WorkflowActionArgs")

enum WorkflowActionArgs {

    /// Builds the JSON `Data` payload for a tool invocation.
    /// - Parameters:
    ///   - bindings: argument-name → template string (e.g. `["body": "{{ input }}"]`).
    ///   - schema: the tool's parameter schema (drives per-argument type coercion).
    ///   - input/inputJSON/variables: the template resolution context (upstream data).
    static func build(
        bindings: [String: String],
        schema: ToolParameters,
        input: String,
        inputJSON: JSONValue?,
        variables: [String: String]
    ) -> Data {
        var args: [String: JSONValue] = [:]

        for (argName, template) in bindings {
            // Skip unbound arguments — an empty/whitespace template means "not set".
            guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let (resolved, unresolved) = WorkflowTemplate.renderReportingUnresolved(
                template,
                input: input,
                inputJSON: inputJSON,
                variables: variables
            )
            // ⚠️ Register EIO-6 — the silent half. An unresolvable placeholder stays verbatim in
            // the rendered text (by design: visible beats vanished), but it is about to become a
            // TOOL ARGUMENT, where "visible" means the tool receives the literal `{{ var.x }}` and
            // fails — or worse, acts on it. Logged at warning with the EXPRESSION, never the
            // resolved values, preserving the argument-hygiene rule this file already follows.
            if !unresolved.isEmpty {
                logger.warning("[WF_EXEC] Action argument '\(argName)' rendered with \(unresolved.count) UNRESOLVED placeholder(s): [\(unresolved.map { "{{\($0)}}" }.joined(separator: ", "))]. CONSEQUENCE: the tool receives the literal placeholder text inside this argument — it will fail validation on it or act on it as data. Check the binding's spelling against the upstream's JSON keys and the workflow's variable names.")
            }
            let declaredType = schema.properties[argName]?.type.lowercased()
            args[argName] = coerce(resolved, to: declaredType)
        }

        // [WF-EX8] A loud failure, never a silent `{}`. This was `(try? …) ?? Data("{}".utf8)`,
        // which threw away EVERY correctly-resolved argument whenever any single value was
        // unencodable — and the one reachable producer of that (a non-finite Double) is now
        // refused in `coerce` below. Kept as a guarded catch for anything else: the tool then
        // fails on missing arguments with the log naming why, instead of running on `{}` with
        // no evidence anywhere.
        do {
            return try JSONValue.object(args).toJSONData()
        } catch {
            logger.error("[WF_EXEC] Action-node argument payload could not be serialized (\(error.localizedDescription)) — \(args.count) resolved argument(s) DROPPED, tool receives {}. CONSEQUENCE: the tool fails on missing/defaulted arguments; the cause is this serialization, not the bindings. Argument names: [\(args.keys.sorted().joined(separator: ", "))].")
            return Data("{}".utf8)
        }
    }

    /// Coerces a resolved string value into the JSON type the schema declares.
    /// Falls back to a string when the value doesn't parse as the declared type,
    /// letting the tool surface a precise validation error rather than guessing.
    private static func coerce(_ value: String, to type: String?) -> JSONValue {
        switch type {
        case "string":
            return .string(value)

        case "number", "integer":
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            // ⚠️ `isFinite` is load-bearing [WF-EX8]: `Double("nan")` and `Double("inf")` PARSE
            // in Swift, and a non-finite `.number` throws at JSON serialization — which used to
            // discard the ENTIRE argument payload (every other argument included) and invoke the
            // tool with `{}`, silently. An upstream LLM emitting the literal "NaN" into a
            // number-typed binding is the reachable path. Falling back to `.string` is this
            // function's documented contract: the tool surfaces a precise validation error.
            if let d = Double(trimmed), d.isFinite { return .number(d) }
            return .string(value)

        case "boolean":
            switch value.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "1": return .bool(true)
            case "false", "no", "0": return .bool(false)
            default: return .string(value)
            }

        case "array", "object":
            // A JSON object/array string (e.g. from `{{ input.json.items }}`) is
            // parsed back into structured form; otherwise passed through as text.
            if let parsed = JSONValue.parseStructured(value) { return parsed }
            return .string(value)

        default:
            // No declared type (or an unknown one): pass through as a string.
            return .string(value)
        }
    }
}
