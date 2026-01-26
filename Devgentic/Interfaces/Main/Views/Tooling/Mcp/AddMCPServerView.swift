//
//  AddMCPServerView.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//

import SwiftUI

// MARK: - Local UI Models

private enum ConnectionType: String, CaseIterable, Identifiable {
    case localProcess = "Local Process"
    case remoteURL = "Remote URL"
    var id: Self { self }
}

private struct KeyValueItem: Identifiable, Hashable {
    let id = UUID()
    var key: String = ""
    var value: String = ""
}

private struct ServerConfigFormData: Hashable {
    var serverName: String = ""
    var connectionType: ConnectionType = .localProcess
    
    // Local
    var command: String = ""
    var arguments: String = ""
    var environmentVariables: [KeyValueItem] = [KeyValueItem()]
    
    // Remote
    var url: String = ""
    var authenticationToken: String = ""
}

// MARK: - Main View

struct AddMCPServerView: View {
    @Environment(\.dismiss) var dismiss
    
    // NEW: Edit Mode Properties with default nil to maintain backward compatibility
    var existingSource: ToolSource? = nil
    
    var onToolAdded: ((String, ServerDefinition, [ToolDefinition]) -> Bool)?
    // NEW: Callback for updates
    var onToolUpdated: ((UUID, String, ServerDefinition, [ToolDefinition]) -> Void)? = nil
    
    // MARK: - State
    
    @State private var formData = ServerConfigFormData()
    @State private var configInput: String = ""
    @State private var selectedTab: Int = 0
    
    // Connection State
    @State private var isConnecting = false
    @State private var activeError: MCPUserError? = nil // UPDATED: Using structured error
    @State private var discoveredTools: [ToolDefinition]? = nil
    @State private var verifiedConfig: ServerDefinition? = nil
    @State private var tempSourceId: UUID = UUID()
    
    @State private var isShowingDuplicateAlert = false
    @State private var isJSONValid = true
    
    // MARK: - Body
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            
            // MODIFIED: Dynamic Title
            Text(existingSource == nil ? "Add MCP Server (V2)" : "Edit MCP Server")
                .font(.title)
                .fontWeight(.bold)
            
            TabView(selection: $selectedTab) {
                formView
                    .tabItem { Label("Form", systemImage: "list.bullet.clipboard") }
                    .tag(0)
                
                jsonEditorView
                    .tabItem { Label("JSON", systemImage: "curlybraces.square") }
                    .tag(1)
            }
            .frame(height: 300)
            
            Divider()
            
            statusSection
            
            Spacer()
            
            bottomControls
        }
        .padding()
        .frame(minWidth: 600, minHeight: 700) // Increased height for error view
        .alert("Duplicate Server", isPresented: $isShowingDuplicateAlert) {
            Button("OK") { }
        } message: {
            Text("A tool with this server name already exists in your library.")
        }
        // MODIFIED: Changed from generateJSON to setupView to handle pre-filling data
        .onAppear(perform: setupView)
        .onDisappear {
            Task {
                await MCPClientService.shared.disconnect(sourceId: tempSourceId)
            }
        }
    }
    
    // MARK: - Subviews
    
    private var formView: some View {
        Form {
            TextField("Server Name", text: $formData.serverName)
            
            Picker("Connection Type", selection: $formData.connectionType) {
                ForEach(ConnectionType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            
            if formData.connectionType == .localProcess {
                localProcessSection
            } else {
                remoteURLSection
            }
        }
        .padding(.top, 10)
        .onChange(of: formData) { _, _ in
            if selectedTab != 1 { generateJSON() }
        }
    }
    
    private var localProcessSection: some View {
        Section(header: Text("Local Process Details").font(.headline)) {
            TextField("Command", text: $formData.command)
                .help("The executable (e.g., 'npx', 'uvx', 'python3').")
            
            TextField("Arguments", text: $formData.arguments)
                .help("Arguments separated by spaces.")
            
            VStack(alignment: .leading) {
                HStack {
                    Text("Environment Variables")
                    Spacer()
                    Button {
                        formData.environmentVariables.append(KeyValueItem())
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
                
                ForEach($formData.environmentVariables) { $item in
                    HStack {
                        TextField("Key", text: $item.key)
                        TextField("Value", text: $item.value)
                        Button {
                            formData.environmentVariables.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.red)
                    }
                }
            }
            .padding(.top, 5)
        }
    }
    
    private var remoteURLSection: some View {
        Section(header: Text("Remote Server Details").font(.headline)) {
            TextField("Server URL", text: $formData.url)
                .help("ws:// or http:// URL")
            SecureField("Authentication Token", text: $formData.authenticationToken)
        }
    }
    
    private var jsonEditorView: some View {
        VStack(alignment: .leading) {
            Text("Configuration JSON")
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
    
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Status")
                .font(.headline)
            
            if isConnecting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Testing connection via Login Shell...")
                        .foregroundColor(.secondary)
                }
                
            } else if let error = activeError {
                // NEW: Rich Error Troubleshooting View
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundColor(.red)
                            .font(.title3)
                        Text(error.title)
                            .fontWeight(.bold)
                            .foregroundColor(.red)
                    }
                    
                    Text(error.message)
                        .font(.body)
                    
                    HStack(alignment: .top) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(.orange)
                        Text(error.suggestion)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                    
                    if let raw = error.rawLog {
                        DisclosureGroup("Show Raw Logs") {
                            ScrollView {
                                Text(raw)
                                    .font(.caption.monospaced())
                                    .padding(5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 60)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(4)
                        }
                    }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.3), lineWidth: 1))
                
            } else if let tools = discoveredTools {
                Text("✅ Connected! Found \(tools.count) tools.")
                    .foregroundColor(.green)
                
                List(tools, id: \.name) { tool in
                    VStack(alignment: .leading) {
                        Text(tool.name).fontWeight(.semibold)
                        Text(tool.description).font(.caption).foregroundColor(.secondary)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            } else {
                Text("Ready to connect.")
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var bottomControls: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            
            Spacer()
            
            if discoveredTools != nil {
                // MODIFIED: Dynamic Button Label
                Button(existingSource == nil ? "Add to Library" : "Save Changes") {
                    saveAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Test Connection") {
                    testConnection()
                }
                .disabled(isConnecting || formData.serverName.isEmpty)
                .keyboardShortcut(.return)
            }
        }
    }
    
    // MARK: - Logic
    
    // NEW: Setup Logic for Edit Mode
    private func setupView() {
        if let source = existingSource, let def = source.serverDefinition {
            // Populate form from existing definition
            formData.serverName = source.serverName
            
            if let cmd = def.command {
                formData.connectionType = .localProcess
                formData.command = cmd
                formData.arguments = def.args?.joined(separator: " ") ?? ""
                formData.environmentVariables = def.env?.map { KeyValueItem(key: $0.key, value: $0.value) } ?? [KeyValueItem()]
            } else if let url = def.url {
                formData.connectionType = .remoteURL
                formData.url = url
                formData.authenticationToken = def.authentication?["token"] ?? ""
            }
            
            // Generate initial JSON from the populated form
            generateJSON()
        } else {
            // Default setup for Add Mode
            generateJSON()
        }
    }
    
    private func testConnection() {
        guard let config = buildServerDefinition() else {
            // Manually create a simple config error
            activeError = MCPUserError(
                title: "Invalid Configuration",
                message: "The server definition is incomplete.",
                suggestion: "Please check that all required fields (Command/URL) are filled out.",
                rawLog: nil
            )
            return
        }
        
        isConnecting = true
        activeError = nil
        discoveredTools = nil
        verifiedConfig = nil
        
        Task {
            do {
                let result = try await MCPClientService.shared.connect(sourceId: tempSourceId, config: config)
                
                await MainActor.run {
                    self.discoveredTools = result.tools
                    self.verifiedConfig = config
                    self.isConnecting = false
                }
            } catch {
                await MainActor.run {
                    // Analyze the error to produce user-friendly output
                    self.activeError = MCPErrorAnalyzer.analyze(error: error)
                    self.isConnecting = false
                }
            }
        }
    }
    
    private func saveAndDismiss() {
        guard let config = verifiedConfig, let tools = discoveredTools else { return }
        
        // MODIFIED: Handle both Edit and Add scenarios
        if let existing = existingSource, let onToolUpdated = onToolUpdated {
            // Update Mode
            onToolUpdated(existing.id, formData.serverName, config, tools)
            Task { await MCPClientService.shared.disconnect(sourceId: tempSourceId) }
            dismiss()
        } else if let onToolAdded = onToolAdded {
            // Add Mode
            let success = onToolAdded(formData.serverName, config, tools)
            if success {
                Task { await MCPClientService.shared.disconnect(sourceId: tempSourceId) }
                dismiss()
            } else {
                isShowingDuplicateAlert = true
            }
        }
    }
    
    // MARK: - JSON Sync Logic
    
    private func buildServerDefinition() -> ServerDefinition? {
        if formData.connectionType == .localProcess {
            let args = formData.arguments.split(whereSeparator: \.isWhitespace).map(String.init)
            let env = Dictionary(
                uniqueKeysWithValues: formData.environmentVariables
                    .filter { !$0.key.isEmpty }
                    .map { ($0.key, $0.value) }
            )
            return ServerDefinition(command: formData.command, args: args, env: env)
        } else {
            let auth: [String: String]? = formData.authenticationToken.isEmpty ? nil : ["token": formData.authenticationToken]
            return ServerDefinition(url: formData.url, authentication: auth)
        }
    }
    
    private func generateJSON() {
        let serverKey = formData.serverName.isEmpty ? "new-server" : formData.serverName
        guard let def = buildServerDefinition() else { return }
        
        let config = MCPConfiguration(mcpServers: [serverKey: def])
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(config) {
            self.configInput = String(data: data, encoding: .utf8) ?? ""
            self.isJSONValid = true
        }
    }
    
    private func parseJSONAndUpdateForm() {
        guard let data = configInput.data(using: .utf8) else { isJSONValid = false; return }
        
        do {
            let config = try JSONDecoder().decode(MCPConfiguration.self, from: data)
            guard let (name, def) = config.mcpServers.first else { return }
            
            var newForm = ServerConfigFormData()
            newForm.serverName = name
            
            if let cmd = def.command {
                newForm.connectionType = .localProcess
                newForm.command = cmd
                newForm.arguments = def.args?.joined(separator: " ") ?? ""
                newForm.environmentVariables = def.env?.map { KeyValueItem(key: $0.key, value: $0.value) } ?? [KeyValueItem()]
            } else if let url = def.url {
                newForm.connectionType = .remoteURL
                newForm.url = url
                newForm.authenticationToken = def.authentication?["token"] ?? ""
            }
            
            self.formData = newForm
            isJSONValid = true
        } catch {
            isJSONValid = false
        }
    }
}
