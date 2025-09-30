//
//  ContentView.swift
//  Devgentic
//
//  Created by Raj Singh on 27/09/25.
//

import SwiftUI

// IMPORTANT: This view acts as the modal interface for adding a new connection.
struct AddMcpConnectionView: View {
    @Environment(\.dismiss) var dismiss // For programmatic sheet dismissal
    
    // The MCPManager is passed in from the parent view (MCPLibraryView)
    @ObservedObject var manager: MCPManager
    
    // The closure now uses the generic ToolDefinition.
    var onToolAdded: ((String, ServerDefinition, [ToolDefinition]) -> Bool)?
    
    @State private var configInput: String = """
    {
      "mcpServers": {
        "brave-search": {
          "command": "npx",
          "args": [
            "-y",
            "@modelcontextprotocol/server-brave-search"
          ],
          "env": {
            "BRAVE_API_KEY": "YOUR_API_KEY_HERE"
          }
        }
      }
    }
    """
    
    // State to manage the duplicate alert
    @State private var isShowingDuplicateAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            
            Text("Add MCP Server")
                .font(.title)
                .fontWeight(.bold)
            
            VStack(alignment: .leading) {
                Text("Servers Configuration JSON")
                    .font(.headline)
                TextEditor(text: $configInput)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 250)
                    .padding(5)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.5), lineWidth: 1))
            }

            statusAndToolView
            
            Spacer() // Pushes the controls to the bottom
            
            bottomControls // New location for buttons
        }
        .padding()
        .frame(minWidth: 600, minHeight: 600)
        // Alert for showing duplicate server message
        .alert("Duplicate Server", isPresented: $isShowingDuplicateAlert) {
            Button("OK") { }
        } message: {
            Text("A tool with this server name already exists in your library.")
        }
    }
    
    private var bottomControls: some View {
        HStack {
            // Cancel Button (Left)
            Button("Cancel") {
                Task {
                    // Always clean up the process when cancelling
                    await manager.disconnect()
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)

            Spacer()
            
            // Add Tool to Library button (Visible only after successful connection)
            if let result = manager.successfulConnectionResult {
                Button("Add Tool to Library") {
                    // Pass the server definition from the result to the closure.
                    if let wasAdded = onToolAdded?(result.serverName, result.serverDefinition, result.tools), wasAdded {
                        // Success: The tool was not a duplicate and was added.
                        Task { await manager.disconnect() } // Clean up the connection after saving
                        dismiss()
                    } else {
                        // Failure: The tool was a duplicate. Show an alert.
                        isShowingDuplicateAlert = true
                    }
                }
                .tint(.blue)
                .keyboardShortcut(.defaultAction)
                
            // Connect Button / Progress View (Right)
            } else if manager.isConnecting {
                ProgressView()
                    .padding(.horizontal, 20)
            } else {
                // Only show Connect button if not successfully connected AND not connecting
                Button("Connect") {
                    manager.configureAndConnect(jsonString: configInput)
                }
                .disabled(configInput.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return)
            }
        }
    }
    
    private var statusAndToolView: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading) {
                Text("Status")
                    .font(.headline)
                if let message = manager.statusMessage {
                    Text(message.text)
                        .foregroundColor(message.isError ? .red : .green)
                } else {
                    Text("Enter server configuration and connect.")
                        .foregroundColor(.secondary)
                }
            }
            .frame(minHeight: 30)
            
            VStack(alignment: .leading) {
                Text("Available Tools")
                    .font(.headline)
                if let result = manager.successfulConnectionResult {
                    List(result.tools, id: \.name) { tool in
                        VStack(alignment: .leading) {
                            Text(tool.name)
                                .fontWeight(.semibold)
                            Text(tool.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                } else if manager.activeServer != nil && manager.availableTools.isEmpty {
                    Text("No tools found on the active server.")
                        .foregroundColor(.secondary)
                } else {
                    Text("Connect to a server to view available tools.")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
