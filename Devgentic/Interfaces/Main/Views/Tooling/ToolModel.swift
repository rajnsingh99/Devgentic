//
//  ToolModel.swift
//  LocalServer
//
//  Created by Raj Singh on 20/09/25.
//

import Foundation
import Hummingbird

// MARK: - API Data Models

/// The JSON request body sent to execute a tool.
struct ExecuteToolRequest: Decodable {
    let name: String
    let arguments: [String: AnyCodable]
}

/// The JSON response body sent back with the tool's output.
struct ExecuteToolResponse: ResponseEncodable {
    let result: String
}


// MARK: - Client-Side Executable Tooling Foundation

/// Defines the JSON schema for a single property within a tool's parameters.
struct ToolParameterProperty: Codable, Hashable {
    let type: String
    let description: String?
}

/// Defines the JSON schema for a tool's parameters, following a standard format.
struct ToolParameters: Codable, Hashable {
    let type: String
    let properties: [String: ToolParameterProperty]
    let required: [String]
}

/// A universal protocol for any tool that the Swift client application can run directly.
/// This ensures a consistent structure for defining, displaying, and executing tools.
protocol ExecutableTool {
    /// A unique, programmatic name for the tool (e.g., "execute_shell").
    var name: String { get }
    
    /// A user-friendly description of what the tool does, for display in the UI.
    var description: String { get }
    
    /// The schema defining the tool's required input arguments.
    var parameters: ToolParameters { get }
    
    /// The asynchronous method that contains the tool's core logic.
    /// - Parameter arguments: A dictionary containing the arguments, conforming to the `parameters` schema.
    /// - Returns: A `String` representing the output or result of the tool's execution.
    /// - Throws: An error if the tool execution fails.
    func execute(arguments: [String: Any]) async throws -> String
}
