//
//  BackendSelectorPopup.swift
//  Devgentic
//
//  Created by Raj Singh on 05/07/25.
//

import SwiftUI
import os

// MARK: - Main Popup View
struct BackendSelectorPopup: View {

    // MARK: - State Bindings
    // --- UPDATED: Receive the whole configuration object ---
    @ObservedObject var configuration: BackendConfiguration
    @Binding var isPresented: Bool
    
    // MARK: - Environment
    @Environment(\.openWindow) var openWindow

    // MARK: - Data Sources
    @ObservedObject var agentStore: AgentStore
    @ObservedObject var llmIntegrationStore: LLMIntegrationStore

    // MARK: - Computed Properties for Data Filtering
    private var agents: [AgentProfileModel] {
        agentStore.agents.sorted { $0.name < $1.name }
    }
    private var localIntegrations: [LLMIntegrationModel] {
        llmIntegrationStore.integrations.filter { $0.providerType == .ollama }.sorted { $0.displayName < $1.displayName }
    }
    private var remoteIntegrations: [LLMIntegrationModel] {
        llmIntegrationStore.integrations.filter { $0.providerType == .remote }.sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            let showAgentColumn = !agentStore.agents.isEmpty
            let showLocalColumn = !localIntegrations.isEmpty
            let showRemoteColumn = !remoteIntegrations.isEmpty

            // Column 1: Agents
            if showAgentColumn {
                AgentColumnView(
                    configuration: configuration,
                    agents: agents,
                    onSelect: {
                        self.isPresented = false
                    },
                    onEdit: { agentID in
                        openWindow(id: "agent-config", value: agentID)
                        self.isPresented = false
                    }
                )
                .frame(minWidth: 180, idealWidth: 200)
            }

            if showAgentColumn && (showLocalColumn || showRemoteColumn) {
                Divider()
            }

            // Column 2: Local LLMs
            if showLocalColumn {
                LLMColumnView(
                    title: "Local Models",
                    backendTypeForColumn: .ollama,
                    integrations: localIntegrations,
                    configuration: configuration,
                    onSelect: {
                        self.isPresented = false
                    },
                    onEdit: { integrationID in
                        llmIntegrationStore.selectedIntegrationID = integrationID
                        openWindow(id: "llm-integrations")
                        self.isPresented = false
                    }
                )
                .frame(minWidth: 180, idealWidth: 200)
            }
            
            if showLocalColumn && showRemoteColumn {
                Divider()
            }

            // Column 3: Remote LLMs
            if showRemoteColumn {
                LLMColumnView(
                    title: "Remote Models",
                    backendTypeForColumn: .remote,
                    integrations: remoteIntegrations,
                    configuration: configuration,
                    onSelect: {
                        self.isPresented = false
                    },
                    onEdit: { integrationID in
                        llmIntegrationStore.selectedIntegrationID = integrationID
                        openWindow(id: "llm-integrations")
                        self.isPresented = false
                    }
                )
                .frame(minWidth: 180, idealWidth: 200)
            }
        }
        .padding(.vertical, 8)
        .frame(maxHeight: 450)
        .fixedSize(horizontal: false, vertical: true)
    }
}


// MARK: - Agent Column View
private struct AgentColumnView: View {
    @ObservedObject var configuration: BackendConfiguration
    let agents: [AgentProfileModel]
    let onSelect: () -> Void
    let onEdit: (UUID) -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 5) {
            Text("Agents")
                .font(.headline)
                .padding(.bottom, 4)
            
            ScrollView {
                VStack(alignment: .center, spacing: 0) {
                    ForEach(agents) { agent in
                        let isSelected = configuration.selectedBackend == .agent && configuration.selectedAgentID == agent.id
                        
                        ItemCell(
                            name: agent.name,
                            detail: agent.role,
                            isSelected: isSelected
                        )
                        .onTapGesture(count: 2) { onEdit(agent.id) }
                        .onTapGesture(count: 1) {
                            configuration.selectedBackend = .agent
                            configuration.selectedAgentID = agent.id
                            self.onSelect()
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}


// MARK: - LLM Integration Column View
private struct LLMColumnView: View {
    let title: String
    let backendTypeForColumn: BackendType
    let integrations: [LLMIntegrationModel]
    @ObservedObject var configuration: BackendConfiguration
    let onSelect: () -> Void
    let onEdit: (UUID) -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 5) {
            Text(title)
                .font(.headline)
                .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .center, spacing: 0) {
                    ForEach(integrations) { integration in
                        let isSelected = configuration.selectedBackend == backendTypeForColumn && configuration.selectedIntegrationID == integration.id
                        
                        ItemCell(
                            name: integration.displayName,
                            detail: integration.providerType == .ollama ? integration.ollamaConfig?.modelName : integration.remoteConfig?.modelName,
                            isSelected: isSelected
                        )
                        .onTapGesture(count: 2) { onEdit(integration.id) }
                        .onTapGesture(count: 1) {
                            configuration.selectedBackend = backendTypeForColumn
                            configuration.selectedIntegrationID = integration.id
                            self.onSelect()
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}


// MARK: - Reusable Item Cell
private struct ItemCell: View {
    let name: String
    let detail: String?
    let isSelected: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Spacer()
                VStack(alignment: .center, spacing: 2) {
                    Text(name)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if let detail = detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }

            if isSelected {
                HStack {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .cornerRadius(6)
        .padding(.horizontal, 8)
    }
}
