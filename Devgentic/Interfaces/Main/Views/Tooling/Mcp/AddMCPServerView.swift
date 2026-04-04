//
//  AddMCPServerView.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//  Updated on 04/02/26 for Modern Dashboard UI.
//

import SwiftUI

// MARK: - Local UI Models

private enum ConnectionType: String, CaseIterable, Identifiable {
    case localProcess = "Local Process"
    case remoteURL = "Remote URL"
    var id: Self { self }
    
    var icon: String {
        switch self {
        case .localProcess: return "terminal.fill"
        case .remoteURL: return "network"
        }
    }
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

private enum ConfigMode: String, CaseIterable {
    case wizard = "Visual Config"
    case json = "JSON"
}

// MARK: - Main View

struct AddMCPServerView: View {
    @Environment(\.dismiss) var dismiss
    
    // Edit Mode Properties
    var existingSource: ToolSource? = nil
    
    var onToolAdded: ((String, ServerDefinition, [ToolDefinition]) -> Bool)?
    var onToolUpdated: ((UUID, String, ServerDefinition, [ToolDefinition]) -> Void)? = nil
    
    // MARK: - State
    
    @State private var formData = ServerConfigFormData()
    @State private var configInput: String = ""
    @State private var configMode: ConfigMode = .wizard
    
    // Connection State
    @State private var isConnecting = false
    @State private var activeError: MCPUserError? = nil
    @State private var discoveredTools: [ToolDefinition]? = nil
    @State private var verifiedConfig: ServerDefinition? = nil
    @State private var tempSourceId: UUID = UUID()
    
    @State private var isShowingDuplicateAlert = false
    @State private var isJSONValid = true
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. Header
            headerView
            
            Divider()
            
            // 2. Main Scrollable Content
            ScrollView {
                VStack(spacing: 24) {
                    
                    // Mode Switcher
                    Picker("", selection: $configMode) {
                        ForEach(ConfigMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    
                    if configMode == .wizard {
                        wizardContent
                    } else {
                        jsonEditorContent
                    }
                    
                    // Status / Diagnostics Area
                    statusSection
                }
                .padding()
            }
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            // 3. Footer
            bottomControls
                .padding()
                .background(.regularMaterial)
        }
        .frame(minWidth: 600, minHeight: 700)
        .alert("Duplicate Server", isPresented: $isShowingDuplicateAlert) {
            Button("OK") { }
        } message: {
            Text("A tool with this server name already exists in your library.")
        }
        .task { setupView() }
        .onDisappear {
            Task {
                await MCPClientService.shared.disconnect(sourceId: tempSourceId)
            }
        }
    }
    
    // MARK: - Subviews: Header
    
    private var headerView: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 48, height: 48)
                Image(systemName: existingSource == nil ? "server.rack" : "pencil.and.outline")
                    .font(.title2)
                    .foregroundColor(.accentColor)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(existingSource == nil ? "Connect MCP Server" : "Edit Server Configuration")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Model Context Protocol Integration")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Subviews: Wizard Content
    
    private var wizardContent: some View {
        VStack(spacing: 20) {
            // Card 1: Identity
            ModernSection(title: "Server Identity", icon: "tag.fill") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Server Name").font(.caption).fontWeight(.medium)
                    TextField("e.g. 'Brave Search', 'Filesystem'...", text: $formData.serverName)
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transport Type").font(.caption).fontWeight(.medium)
                    Picker("", selection: $formData.connectionType) {
                        ForEach(ConnectionType.allCases) { type in
                            Label(type.rawValue, systemImage: type.icon).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            
            // Card 2: Connection Details
            if formData.connectionType == .localProcess {
                ModernSection(title: "Local Process", icon: "terminal.fill") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Executable Command").font(.caption).fontWeight(.medium)
                        HStack {
                            TextField("e.g. 'npx', 'uvx', 'python3'...", text: $formData.command)
                                .textFieldStyle(.roundedBorder)
                        }
                        Text("The command must be in your system PATH or an absolute path.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Arguments").font(.caption).fontWeight(.medium)
                        TextField("-y @modelcontextprotocol/server-filesystem /Users/...", text: $formData.arguments)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                
                // Card 3: Environment Variables
                ModernSection(title: "Environment Variables", icon: "list.bullet.rectangle.portrait.fill") {
                    VStack(spacing: 8) {
                        ForEach($formData.environmentVariables) { $item in
                            HStack {
                                TextField("KEY", text: $item.key)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 150)
                                
                                Text("=")
                                    .foregroundColor(.secondary)
                                
                                TextField("VALUE", text: $item.value)
                                    .textFieldStyle(.roundedBorder)
                                
                                Button {
                                    formData.environmentVariables.removeAll { $0.id == item.id }
                                } label: {
                                    Image(systemName: "trash.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        
                        Button {
                            formData.environmentVariables.append(KeyValueItem())
                        } label: {
                            Label("Add Variable", systemImage: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .padding(.top, 4)
                    }
                }
                
            } else {
                ModernSection(title: "Remote Connection", icon: "network") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Server URL").font(.caption).fontWeight(.medium)
                        TextField("sse://... or http://...", text: $formData.url)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Auth Token (Optional)").font(.caption).fontWeight(.medium)
                        SecureField("Bearer token...", text: $formData.authenticationToken)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
        .onChange(of: formData) { _, _ in
            generateJSON()
        }
    }
    
    // MARK: - Subviews: JSON Editor
    
    private var jsonEditorContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Configuration JSON")
                .font(.headline)
            TextEditor(text: $configInput)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isJSONValid ? Color.secondary.opacity(0.2) : Color.red, lineWidth: 1)
                )
                .frame(minHeight: 300)
                .onChange(of: configInput) { _, _ in
                    parseJSONAndUpdateForm()
                }
            
            if !isJSONValid {
                Text("Invalid JSON syntax")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }
    
    // MARK: - Subviews: Status & Controls
    
    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Diagnostics", systemImage: "stethoscope")
                .font(.headline)
                .foregroundColor(.secondary)
            
            if isConnecting {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Attempting handshake with server...")
                        .foregroundColor(.primary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
                
            } else if let error = activeError {
                // Error Card
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundColor(.orange)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(error.title).fontWeight(.bold)
                        Text(error.message).font(.body)
                        
                        Divider().padding(.vertical, 4)
                        
                        HStack(alignment: .top) {
                            Text("Fix:").fontWeight(.medium)
                            Text(error.suggestion)
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        
                        if let raw = error.rawLog {
                            DisclosureGroup("Show Raw Log") {
                                Text(raw)
                                    .font(.caption2.monospaced())
                                    .padding(8)
                                    .background(Color.black.opacity(0.8))
                                    .foregroundColor(.green)
                                    .cornerRadius(4)
                            }
                            .font(.caption)
                            .padding(.top, 4)
                        }
                    }
                }
                .padding()
                .background(Color.orange.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.3)))
                .cornerRadius(12)
                
            } else if let tools = discoveredTools {
                // Success Card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                        Text("Connection Successful")
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                        Spacer()
                        Text("\(tools.count) tools found")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(12)
                    }
                    
                    Divider()
                    
                    Text("Available Capabilities:")
                        .font(.caption).fontWeight(.medium).foregroundColor(.secondary)
                    
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 8) {
                        ForEach(tools.prefix(6), id: \.name) { tool in
                            Text(tool.name)
                                .font(.caption2)
                                .padding(6)
                                .frame(maxWidth: .infinity)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(6)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.1)))
                        }
                        if tools.count > 6 {
                            Text("+ \(tools.count - 6) more...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .background(Color.green.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.3)))
                .cornerRadius(12)
                
            } else {
                // Idle State
                Text("Configure settings above and click 'Test Connection' to verify.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [4])))
            }
        }
    }
    
    private var bottomControls: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            
            Spacer()
            
            if discoveredTools != nil {
                Button(existingSource == nil ? "Add to Library" : "Save Changes") {
                    saveAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    testConnection()
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Test Connection")
                    }
                }
                .disabled(isConnecting || formData.serverName.isEmpty)
                .keyboardShortcut(.return)
            }
        }
    }
    
    // MARK: - Logic Implementation
    
    private func setupView() {
        if let source = existingSource, let def = source.serverDefinition {
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
            generateJSON()
        } else {
            generateJSON()
        }
    }
    
    private func testConnection() {
        guard let config = buildServerDefinition() else {
            activeError = MCPUserError(
                title: "Invalid Configuration",
                message: "The server definition is incomplete.",
                suggestion: "Please check that all required fields are filled out.",
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
                    self.activeError = MCPErrorAnalyzer.analyze(error: error)
                    self.isConnecting = false
                }
            }
        }
    }
    
    private func saveAndDismiss() {
        guard let config = verifiedConfig, let tools = discoveredTools else { return }
        if let existing = existingSource, let onToolUpdated = onToolUpdated {
            onToolUpdated(existing.id, formData.serverName, config, tools)
            Task { await MCPClientService.shared.disconnect(sourceId: tempSourceId) }
            dismiss()
        } else if let onToolAdded = onToolAdded {
            let success = onToolAdded(formData.serverName, config, tools)
            if success {
                Task { await MCPClientService.shared.disconnect(sourceId: tempSourceId) }
                dismiss()
            } else {
                isShowingDuplicateAlert = true
            }
        }
    }
    
    private func buildServerDefinition() -> ServerDefinition? {
        if formData.connectionType == .localProcess {
            let args = formData.arguments.split(whereSeparator: \.isWhitespace).map(String.init)
            let env = Dictionary(
                uniqueKeysWithValues: formData.environmentVariables.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) }
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
