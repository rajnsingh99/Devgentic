//
//  DevgenticTool.swift
//  Devgentic
//
//  Created by Devgentic Architect
//
//  The owned Tool protocol replacing OpenFoundationModels.Tool.
//  Tools accept Decodable arguments decoded directly from JSON Data,
//  eliminating the GeneratedContent intermediary.
//

import Foundation

// MARK: - Tool Protocol

/// The contract for all executable tools in the Devgentic Agent Engine.
/// Tools declare their schema using the existing `ToolParameters` type
/// and accept arguments decoded via standard `JSONDecoder`.
protocol DevgenticTool: Sendable {
    associatedtype Arguments: Decodable & Sendable

    /// The programmatic name of the tool (e.g., "execute_shell").
    var name: String { get }

    /// A description of what the tool does, for prompt injection.
    var description: String { get }

    /// The JSON Schema for the tool's parameters, using the existing ToolParameters type.
    var parameterSchema: ToolParameters { get }

    /// Executes the tool with the given arguments.
    /// - Parameter arguments: Decoded arguments matching the schema.
    /// - Returns: A string representation of the tool's output.
    func call(arguments: Arguments) async throws -> String
}

// MARK: - Schema Builder

/// Convenience builder for constructing `ToolParameters` schemas.
/// Replaces the verbose `DynamicGenerationSchema` + `GenerationSchema` construction from OFM.
enum SchemaBuilder {

    /// Creates a ToolParameters object schema with the given properties.
    /// - Parameters:
    ///   - properties: An array of property definitions (name, type, description).
    ///   - required: An array of required property names.
    /// - Returns: A ToolParameters instance representing the JSON Schema.
    static func object(
        properties: [(name: String, type: String, description: String)],
        required: [String]
    ) -> ToolParameters {
        var props: [String: ToolParameterProperty] = [:]
        for prop in properties {
            props[prop.name] = ToolParameterProperty(type: prop.type, description: prop.description)
        }
        return ToolParameters(type: "object", properties: props, required: required)
    }

    /// Creates a ToolParameters with no properties (for tools that require no arguments).
    static func empty() -> ToolParameters {
        return ToolParameters(type: "object", properties: [:], required: [])
    }
}
