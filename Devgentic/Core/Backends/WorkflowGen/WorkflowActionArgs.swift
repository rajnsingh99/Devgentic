// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowActionArgs.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "WorkflowActionArgs")

/// Assembles a tool's JSON arguments for an Action node from its per-argument template bindings, each resolved via
/// `WorkflowTemplate` and coerced to the JSON type the tool's parameter schema declares. Unbound arguments are omitted:
/// optional ones fall back to defaults, and a missing required one surfaces as a decode error from the tool wrapper.
enum WorkflowActionArgs {

    /// Builds the JSON `Data` payload for a tool invocation.
    /// - Parameters: `bindings` maps argument name to template string (e.g. `["body": "{{ input }}"]`); `schema` drives type
    /// coercion; `input`/`inputJSON`/`variables` are the template resolution context (upstream data).
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
            // An unresolved placeholder stays verbatim in the text but is about to become a tool argument, which would then receive
            // the literal `{{ var.x }}`; log it at warning with the expression, never the resolved values.
            if !unresolved.isEmpty {
                logger.warning("[WF_EXEC] Action argument '\(argName)' rendered with \(unresolved.count) UNRESOLVED placeholder(s): [\(unresolved.map { "{{\($0)}}" }.joined(separator: ", "))]. CONSEQUENCE: the tool receives the literal placeholder text inside this argument — it will fail validation on it or act on it as data. Check the binding's spelling against the upstream's JSON keys and the workflow's variable names.")
            }
            let declaredType = schema.properties[argName]?.type.lowercased()
            args[argName] = coerce(resolved, to: declaredType)
        }

        // A loud failure, never a silent `{}`: swallowing the error would discard every correctly-resolved argument when any
        // one value is unencodable, so the tool would run on `{}` with no evidence in the log.
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
            // `isFinite` matters: `Double("nan")` and `Double("inf")` parse in Swift, and a non-finite `.number` throws at JSON
            // serialization and would lose every argument; fall back to `.string` and let the tool report a validation error.
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
