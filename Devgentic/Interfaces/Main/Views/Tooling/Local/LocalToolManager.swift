//
//  ToolManager.swift
//  LocalServer
//
//  Created by Raj Singh on 20/09/25.
//

import Foundation

/// A singleton class that manages the registration and execution of all client-side tools.
///
/// This manager acts as a central registry, allowing other parts of the application to
/// discover available tools and execute them with a consistent interface.
@MainActor
final class LocalToolManager {
    
    /// The shared singleton instance of the `ToolManager`.
    static let shared = LocalToolManager()
    
    /// A private registry to store tool instances, keyed by their unique `name`.
    private var toolRegistry: [String: ExecutableTool] = [:]

    /// Private initializer to enforce the singleton pattern.
    ///
    /// When the manager is initialized, it automatically registers all available
    /// inbuilt tools. This is the single place where new tools should be added.
    private init() {
        // Register the original shell tool
        register(tool: TerminalTool())

        // Register File System Tools
        register(tool: ListDirectoryTool())
        register(tool: ReadFileTool())
        register(tool: WriteFileTool())
        register(tool: DeleteFileTool())
        
        // Register System Interaction & Information Tools
        register(tool: GetClipboardContentTool())
        register(tool: SetClipboardContentTool())
        register(tool: GetSystemStatsTool())
        
        // Register Application Control Tools
        register(tool: OpenApplicationTool())
        register(tool: RunAppleScriptTool())
    }

    /// Registers a tool instance, making it available for execution.
    /// - Parameter tool: An instance of a class or struct that conforms to `ExecutableTool`.
    private func register(tool: ExecutableTool) {
        toolRegistry[tool.name] = tool
    }

    /// Provides a list of all currently registered tools.
    ///
    /// This is useful for UI components that need to display available tools to the user,
    /// for example, in the agent configuration screen.
    /// - Returns: An array of objects conforming to `ExecutableTool`.
    func availableTools() -> [ExecutableTool] {
        return Array(toolRegistry.values)
    }

    /// Finds and executes a tool by its name with a given set of arguments.
    ///
    // This method provides a safe way to run tools, with error handling for cases
    /// where a tool is not found or fails during execution.
    /// - Parameters:
    ///   - name: The unique name of the tool to execute (e.g., "execute_shell").
    ///   - arguments: A dictionary of arguments to pass to the tool's `execute` method.
    /// - Returns: A `String` containing the tool's output or an error message.
    func execute(name: String, arguments: [String: Any]) async -> String {
        guard let tool = toolRegistry[name] else {
            return "Error: Tool '\(name)' not found in the client-side registry."
        }
        
        // Some tools need to run on the main thread
        if let tool = tool as? any MainActorExecutableTool {
             return await tool.run(arguments: arguments)
        } else {
            do {
                return try await tool.execute(arguments: arguments)
            } catch {
                return "Error executing tool '\(name)': \(error.localizedDescription)"
            }
        }
    }
}

/// A helper protocol for tools that must be run on the main actor.
@MainActor protocol MainActorExecutableTool: ExecutableTool {}

extension MainActorExecutableTool {
    /// A wrapper function to handle execution and error catching on the main actor.
    func run(arguments: [String: Any]) async -> String {
        do {
            return try await execute(arguments: arguments)
        } catch {
            return "Error executing tool '\(name)': \(error.localizedDescription)"
        }
    }
}

