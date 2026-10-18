// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AddMCPServerContainerView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// In-window destination for adding or editing an MCP server.
/// Resolves edit mode against `MCPToolStore`; saves and cancellations both return to the Tool Library.
struct AddMCPServerContainerView: View {

    enum Mode: Equatable {
        case add
        case edit(sourceID: UUID)
    }

    let mode: Mode

    @Environment(MainViewRouter.self) private var router

    // Why: editing a cached copy would edit a phantom record after an external delete.
    /// Live source lookup for edit mode.
    /// Reading `MCPToolStore.shared.sources` makes the container track the store, so an external delete shows not-found.
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

    // Why: the Keychain write must happen before the row is inserted.
    /// Returns `.duplicate` when a server with the same name exists, `.failed` when the save did not happen.
    /// `oauthBundle` is non-nil when the user signed in via OAuth and is persisted to Keychain under the new source ID.
    private func handleAdd(
        serverName: String,
        definition: ServerDefinition,
        secrets: MCPRuntimeSecrets,
        tools: [ToolDefinition],
        oauthBundle: MCPOAuthCredentialBundle?
    ) -> MCPAddOutcome {
        MCPServerAddFlow.add(
            serverName: serverName,
            oauthBundle: oauthBundle,
            isDuplicate: { name in
                MCPToolStore.shared.sources.contains { source in
                    source.serverName.caseInsensitiveCompare(name) == .orderedSame
                }
            },
            persistBundle: { bundle, sourceID in
                try MCPOAuthCoordinator.persist(bundle, sourceID: sourceID)
            },
            addTool: { newID in
                MCPToolStore.shared.addTool(
                    id: newID,
                    serverName: serverName,
                    serverDefinition: definition,
                    secrets: secrets,
                    newTools: tools
                )
            },
            discardBundle: { sourceID in
                _ = MCPSecretStore.shared.delete(scope: .oauthBundle, sourceID: sourceID)
            }
        )
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
