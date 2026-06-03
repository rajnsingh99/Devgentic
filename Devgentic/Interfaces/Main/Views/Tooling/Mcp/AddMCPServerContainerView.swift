//
//  AddMCPServerContainerView.swift
//  Devgentic
//
//  In-window destination for adding or editing an MCP server.
//  Replaces the previous `.sheet`-based modal so navigation matches the rest
//  of the app (see ScheduledTaskCreateContainerView, AgentConfigDetailView).
//
//  The container resolves edit mode against `MCPToolStore` and bridges the
//  form's add/update callbacks back into `router.goBack()` so successful
//  saves and cancellations both land on the Tool Library.
//

import SwiftUI

struct AddMCPServerContainerView: View {

    enum Mode: Equatable {
        case add
        case edit(sourceID: UUID)
    }

    let mode: Mode

    @Environment(MainViewRouter.self) private var router

    /// Live source lookup for edit mode. Reading `MCPToolStore.shared.sources`
    /// here makes the container @Observable-track the store, so an external
    /// delete (e.g. from another window) collapses to the not-found state
    /// instead of editing a phantom record.
    private var resolvedSource: ToolSource? {
        if case let .edit(sourceID) = mode {
            return MCPToolStore.shared.sources.first(where: { $0.id == sourceID })
        }
        return nil
    }

    var body: some View {
        switch mode {
        case .add:
            AddMCPServerView(
                existingSource: nil,
                onToolAdded: handleAdd,
                onToolUpdated: nil,
                onDismiss: { router.goBack() }
            )
        case .edit(let sourceID):
            if let source = resolvedSource {
                AddMCPServerView(
                    existingSource: source,
                    onToolAdded: nil,
                    onToolUpdated: handleUpdate,
                    onDismiss: { router.goBack() }
                )
                // Bind the form to the resolved source ID so swapping between
                // edit targets without leaving the route resets all @State.
                .id(sourceID)
            } else {
                ContentNotFoundView(
                    icon: "exclamationmark.triangle",
                    title: "Server Not Found",
                    subtitle: "This MCP server may have been removed. Use the back button to return."
                )
            }
        }
    }

    // MARK: - Save bridges

    /// Returns false if a server with the same name already exists, matching
    /// the previous sheet contract so the form's duplicate alert still fires.
    /// `oauthBundle` is non-nil when the user signed in via the OAuth flow —
    /// persisted to Keychain under the *new* source ID once the store
    /// assigns one.
    private func handleAdd(
        serverName: String,
        definition: ServerDefinition,
        secrets: MCPRuntimeSecrets,
        tools: [ToolDefinition],
        oauthBundle: MCPOAuthCredentialBundle?
    ) -> Bool {
        let exists = MCPToolStore.shared.sources.contains { source in
            source.serverName.caseInsensitiveCompare(serverName) == .orderedSame
        }
        if exists { return false }
        let newID = MCPToolStore.shared.addTool(
            serverName: serverName,
            serverDefinition: definition,
            secrets: secrets,
            newTools: tools
        )
        if let oauthBundle, let newID {
            try? MCPOAuthCoordinator.persist(oauthBundle, sourceID: newID)
        }
        return true
    }

    private func handleUpdate(
        id: UUID,
        serverName: String,
        definition: ServerDefinition,
        secrets: MCPRuntimeSecrets,
        tools: [ToolDefinition]
    ) {
        UnifiedToolStore.shared.updateTool(
            id: id,
            serverName: serverName,
            serverDefinition: definition,
            secrets: secrets,
            newTools: tools
        )
        // Drop the live session so the next tool call reconnects with the new config.
        Task { await MCPClientService.shared.disconnect(sourceId: id) }
    }
}
