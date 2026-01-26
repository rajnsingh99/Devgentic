//
//  ContentView.swift
//  Devgentic
//
//  Created by Raj Singh on 27/09/25.
//
//  Updated on 19/10/25 to add state management for a new UI-based configuration form.
//  Updated on 20/10/25 to implement the TabView and UI form structure.
//  Updated on 21/10/25 to add data synchronization between the UI form and JSON editor.
//  Updated on 22/10/25 to implement reverse synchronization from JSON to the UI form.
//

import SwiftUI

// MARK: - MCP Configuration Data Models

/// The top-level configuration structure that holds a dictionary of server definitions.
struct MCPConfiguration: Codable {
    let mcpServers: [String: ServerDefinition]
}

/// A unified server definition that works for both local and remote servers.
struct ServerDefinition: Codable, Hashable {
    // Properties for Local Process
    let command: String?
    let args: [String]?
    let env: [String: String]?
    
    // Properties for Remote URL
    let url: String?
    let authentication: [String: String]?

    /// A single, flexible initializer that provides default nil values for all optional properties.
    /// This allows us to create a ServerDefinition for either a local or remote type without causing compiler errors.
    init(command: String? = nil, args: [String]? = nil, env: [String: String]? = nil, url: String? = nil, authentication: [String: String]? = nil) {
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.authentication = authentication
    }
}


// MARK: - State Management Models for UI Form

/// An enum to represent the type of server connection the user can configure.
enum ConnectionType: String, CaseIterable, Identifiable {
    case localProcess = "Local Process"
    case remoteURL = "Remote URL"
    var id: Self { self }
}

/// A simple, identifiable struct to manage key-value pairs in the UI, like environment variables.
struct KeyValueItem: Identifiable, Hashable {
    let id = UUID()
    var key: String = ""
    var value: String = ""
}

/// The main data model for our configuration form. This struct will hold all the user's input from the UI fields.
struct ServerConfigFormData: Hashable {
    var serverName: String = ""
    var connectionType: ConnectionType = .localProcess
    
    // Properties for Local Process
    var command: String = ""
    var arguments: String = "" // Using a single string for simplicity, will be split by spaces
    var environmentVariables: [KeyValueItem] = [KeyValueItem()] // Start with one empty item
    
    // Properties for Remote URL
    var url: String = ""
    var authenticationToken: String = ""
}


// IMPORTANT: This view acts as the modal interface for adding a new connection.
struct AddMcpConnectionView: View {
    @Environment(\.dismiss) var dismiss // For programmatic sheet dismissal
    
    // The MCPManager is passed in from the parent view (MCPLibraryView)
    @ObservedObject var manager: MCPManager
    
    // The closure now uses the generic ToolDefinition.
    var onToolAdded: ((String, ServerDefinition, [ToolDefinition]) -> Bool)?
    
    // State for the JSON TextEditor
    @State private var configInput: String = ""
    
    // State to manage the duplicate alert
    @State private var isShowingDuplicateAlert = false
    
    // MARK: - New State for UI Form
    /// This state variable holds all the data for the new UI-based configuration form.
    @State private var formData = ServerConfigFormData()
    
    /// This state controls which tab (UI Form or JSON) is currently selected.
    @State private var selectedTab: Int = 0
    
    /// This state tracks whether the text in the JSON editor is valid.
    @State private var isJSONValid: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            
            Text("Add MCP Server")
                .font(.title)
                .fontWeight(.bold)
            
            // TabView to switch between the UI form and the raw JSON editor.
            TabView(selection: $selectedTab) {
                formView
                    .tabItem {
                        Label("Form", systemImage: "list.bullet.clipboard")
                    }
                    .tag(0)
                
                jsonEditorView
                    .tabItem {
                        Label("JSON", systemImage: "curlybraces.square")
                    }
                    .tag(1)
            }
            .frame(height: 280)


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
        .onAppear(perform: generateJSON) // Generate initial JSON when view appears
    }
    
    // MARK: - UI Subviews
    
    /// The main view for the UI-based configuration form.
    private var formView: some View {
        Form {
            TextField("Server Name", text: $formData.serverName)
            
            Picker("Connection Type", selection: $formData.connectionType) {
                ForEach(ConnectionType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            
            // Conditionally show the relevant section based on the selected connection type.
            if formData.connectionType == .localProcess {
                localProcessSection
            } else {
                remoteURLSection
            }
        }
        .padding(.top, 10)
        .onChange(of: formData) { _, _ in
            // To prevent an infinite loop, only generate JSON if the user is not on the JSON tab.
            if selectedTab != 1 {
                generateJSON()
            }
        }
    }
    
    /// A view containing the fields for configuring a local process server.
    private var localProcessSection: some View {
        Section(header: Text("Local Process Details").font(.headline)) {
            TextField("Command", text: $formData.command)
                .help("The executable to run (e.g., 'npx', 'python').")
            TextField("Arguments", text: $formData.arguments)
                .help("Command-line arguments, separated by spaces.")
            
            environmentVariablesSection
        }
    }
    
    /// A view for managing environment variables for a local process.
    private var environmentVariablesSection: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Environment Variables")
                Spacer()
                Button(action: {
                    formData.environmentVariables.append(KeyValueItem())
                }) {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
            }
            
            ForEach($formData.environmentVariables) { $item in
                HStack {
                    TextField("Key", text: $item.key)
                    TextField("Value", text: $item.value)
                    Button(action: {
                        formData.environmentVariables.removeAll { $0.id == item.id }
                    }) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                }
            }
        }
        .padding(.top, 5)
    }
    
    /// A view containing the fields for configuring a remote URL-based server.
    private var remoteURLSection: some View {
        Section(header: Text("Remote Server Details").font(.headline)) {
            TextField("Server URL", text: $formData.url)
                .help("The WebSocket URL of the remote server (e.g., 'ws://127.0.0.1:8080').")
            SecureField("Authentication Token", text: $formData.authenticationToken)
                .help("The Bearer token for authentication, if required.")
        }
    }
    
    /// The view for the raw JSON editor.
    private var jsonEditorView: some View {
        VStack(alignment: .leading) {
            Text("Server Configuration JSON")
                .font(.headline)
            TextEditor(text: $configInput)
                .font(.system(.body, design: .monospaced))
                .padding(5)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isJSONValid ? Color.gray.opacity(0.5) : Color.red, lineWidth: 1)
                )
                .onChange(of: configInput) { _, _ in
                    parseJSONAndUpdateForm()
                }
        }
        .padding(.vertical)
    }
    
    private var bottomControls: some View {
        HStack {
            Button("Cancel") {
                Task {
                    await manager.disconnect()
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)

            Spacer()
            
            if let result = manager.successfulConnectionResult {
                Button("Add Tool to Library") {
                    if let wasAdded = onToolAdded?(result.serverName, result.serverDefinition, result.tools), wasAdded {
                        Task { await manager.disconnect() }
                        dismiss()
                    } else {
                        isShowingDuplicateAlert = true
                    }
                }
                .tint(.blue)
                .keyboardShortcut(.defaultAction)
                
            } else if manager.isConnecting {
                ProgressView()
                    .padding(.horizontal, 20)
            } else {
                Button("Connect") {
                    manager.configureAndConnect(jsonString: configInput)
                }
                .disabled(configInput.trimmingCharacters(in: .whitespaces).isEmpty || !isJSONValid)
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
    
    // MARK: - Data Synchronization Logic
    
    /// Generates a JSON string from the current `formData` and updates the `configInput` state.
    private func generateJSON() {
        // Sanitize the server name to ensure it's a valid key in the JSON object.
        let serverKey = formData.serverName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        
        guard !serverKey.isEmpty else {
            self.configInput = """
            {
              "mcpServers": {}
            }
            """
            return
        }

        var serverDef: ServerDefinition
        
        if formData.connectionType == .localProcess {
            let args = formData.arguments.split(whereSeparator: \.isWhitespace).map(String.init)
            let env = Dictionary(
                uniqueKeysWithValues: formData.environmentVariables
                    .filter { !$0.key.isEmpty }
                    .map { ($0.key, $0.value) }
            )
            serverDef = ServerDefinition(command: formData.command, args: args, env: env)
        } else {
            let auth: [String: String]? = formData.authenticationToken.isEmpty ? nil : ["token": formData.authenticationToken]
            serverDef = ServerDefinition(url: formData.url, authentication: auth)
        }
        
        let config = MCPConfiguration(mcpServers: [serverKey: serverDef])
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        do {
            let data = try encoder.encode(config)
            self.configInput = String(data: data, encoding: .utf8) ?? ""
            self.isJSONValid = true
        } catch {
            self.configInput = "Error generating JSON: \(error.localizedDescription)"
            self.isJSONValid = false
        }
    }
    
    /// Parses the `configInput` JSON string and updates the `formData` state to match.
    private func parseJSONAndUpdateForm() {
        guard let data = configInput.data(using: .utf8) else {
            isJSONValid = false
            return
        }
        
        do {
            let config = try JSONDecoder().decode(MCPConfiguration.self, from: data)
            
            guard let (serverName, serverDef) = config.mcpServers.first else {
                self.formData = ServerConfigFormData()
                isJSONValid = true
                return
            }
            
            var newFormData = ServerConfigFormData()
            newFormData.serverName = serverName
            
            if let command = serverDef.command {
                newFormData.connectionType = .localProcess
                newFormData.command = command
                newFormData.arguments = serverDef.args?.joined(separator: " ") ?? ""
                newFormData.environmentVariables = serverDef.env?.map { KeyValueItem(key: $0.key, value: $0.value) } ?? []
                if newFormData.environmentVariables.isEmpty {
                    newFormData.environmentVariables.append(KeyValueItem())
                }
            } else if let url = serverDef.url {
                newFormData.connectionType = .remoteURL
                newFormData.url = url
                newFormData.authenticationToken = serverDef.authentication?["token"] ?? ""
            }
            
            self.formData = newFormData
            isJSONValid = true
            
        } catch {
            isJSONValid = false
        }
    }
}

