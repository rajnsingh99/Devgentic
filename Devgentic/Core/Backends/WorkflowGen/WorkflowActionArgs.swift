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

            let resolved = WorkflowTemplate.render(
                template,
                input: input,
                inputJSON: inputJSON,
                variables: variables
            )
            let declaredType = schema.properties[argName]?.type.lowercased()
            args[argName] = coerce(resolved, to: declaredType)
        }

        return (try? JSONValue.object(args).toJSONData()) ?? Data("{}".utf8)
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
            if let d = Double(trimmed) { return .number(d) }
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
