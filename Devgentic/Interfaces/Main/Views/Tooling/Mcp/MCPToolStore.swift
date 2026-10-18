// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPToolStore.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "MCPToolStore")

/// Manages all SwiftData operations for MCP tools (MCPToolItem and MCPToolDefinitionModel).
/// This class acts as a single source of truth for tool data and publishes changes to the UI.
@Observable @MainActor
final class MCPToolStore {

    // MARK: - Singleton Instance
    static let shared = MCPToolStore()

    /// Test hook: when set, receives exactly the messages the config-blob integrity paths log.
    /// Those are an `updateTool`/`deleteTool` with an unusable `mcpConfigData`, and an `addTool` that cannot encode.
    /// The sink and the logger share one message, so they cannot drift.
    nonisolated(unsafe) static var blobIntegrityLogSinkForTesting: (@Sendable (String) -> Void)?

    private static func logBlobIntegrity(_ message: String) {
        if let sink = blobIntegrityLogSinkForTesting {
            sink(message)
            return
        }
        logger.error(message)
    }

    /// Array of tool sources that the UI can observe for changes.
    var sources: [ToolSource] = []

    /// The shared model container, configured once at app startup.
    private(set) var modelContainer: ModelContainer?

    private var mainContext: ModelContext? {
        modelContainer?.mainContext
    }

    /// Call this once from the App init to inject the container. Also kicks off a proactive
    /// OAuth-token refresh for any near-expiry bundles.
    func configureContainer(_ container: ModelContainer) {
        self.modelContainer = container
        fetchTools()
        refreshNearExpiryOAuthBundles()
    }

    /// Resolves the model context, logging the user-visible consequence when it is missing.
    /// `mainContext` is nil only before `configureContainer` has run; a bare guard would drop the user's action silently.
    private func requireContext(_ operation: String, consequence: String) -> ModelContext? {
        guard let context = mainContext else {
            logger.error(
                "[MCP-STORE] \(operation) called before the ModelContainer was configured. "
                + "CONSEQUENCE: \(consequence)"
            )
            return nil
        }
        return context
    }

    /// Private initializer to enforce singleton pattern.
    private init() {}

    // MARK: - Public CRUD Methods

    /// Adds a new tool source, persisting `secrets` (env values and auth token) to Keychain under its ID, never inline.
    /// Returns the new source ID so callers (e.g. the form) can clean up any temp-ID Keychain entries.
    @discardableResult
    /// - Parameter id: the new source's identity, caller-supplied (defaulting to a fresh UUID) so a credential that must be
    ///   written before the row exists, such as the OAuth bundle, can be keyed on it. See `MCPServerAddFlow`.
    func addTool(
        id newID: UUID = UUID(),
        serverName: String,
        serverDefinition: ServerDefinition,
        secrets: MCPRuntimeSecrets,
        newTools: [ToolDefinition]
    ) -> UUID? {
        guard let context = requireContext(
            "addTool(serverName: \(serverName))",
            consequence: "the new MCP server was NOT saved and no Keychain secrets were written; the "
                + "form is told the add failed."
        ) else { return nil }

        // Encode the definition before any secret is written: a failed encode must fail the add while nothing is stored,
        // since a secret saved without its env-key names could never be cleaned up by `deleteTool`.
        let configBlob: Data
        do {
            configBlob = BlobVersioning.stamped(
                try JSONEncoder().encode(serverDefinition), version: MCPToolItem.configBlobVersion)
        } catch {
            Self.logBlobIntegrity(
                "[PERSISTENCE] Failed to encode the ServerDefinition for new MCP source "
                + "'\(serverName)' (id \(newID)): \(error). CONSEQUENCE: the server was NOT "
                + "added — no row and no Keychain secrets were written, so there is nothing to "
                + "clean up; re-entering the configuration is the whole recovery."
            )
            return nil
        }

        let item = MCPToolItem(
            id: newID,
            serverName: serverName,
            // Stamped (G19) so a future reader can ask what shape this is instead of guessing.
            mcpConfigData: configBlob
        )

        for tool in newTools {
            let child = createToolDefinitionModel(from: tool)
            item.tools.append(child)
        }

        // Write secrets to Keychain under the *final* sourceID. Done before
        // SwiftData insert so a Keychain failure aborts the whole add.
        persistSecrets(secrets, definition: serverDefinition, sourceID: newID)

        context.insert(item)
        saveContext()
        fetchTools()
        return newID
    }

    /// Whether `serverName` is already taken by a different source.
    /// The name is the user's only handle on a server in the sidebar, tool categories and logs, so duplicates are ambiguous.
    func isServerNameTaken(_ serverName: String, excluding sourceID: UUID? = nil) -> Bool {
        let trimmed = serverName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        return sources.contains { source in
            source.id != sourceID
                && source.serverName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmed
        }
    }

    /// Enables or disables a server without touching its configuration or secrets.
    /// Disabling disconnects immediately: a live session would keep the child process running and its tools callable.
    func setEnabled(_ enabled: Bool, sourceID: UUID) {
        guard let context = mainContext else {
            logger.error("""
                [MCP-STORE] Cannot \(enabled ? "enable" : "disable") source \(sourceID): no \
                ModelContainer injected. The change was NOT persisted and the UI will revert on \
                the next fetch.
                """)
            return
        }

        let targetID = sourceID
        let predicate = #Predicate<MCPToolItem> { $0.id == targetID }
        var descriptor = FetchDescriptor<MCPToolItem>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            guard let item = try context.fetch(descriptor).first else {
                logger.error("[MCP-STORE] Cannot toggle source \(sourceID): no record found. Nothing changed.")
                return
            }
            guard item.isEnabled != enabled else { return }

            item.isEnabled = enabled
            saveContext()
            fetchTools()

            logger.info("""
                [MCP-LIFECYCLE] Server '\(item.serverName)' (\(sourceID)) \
                \(enabled ? "ENABLED" : "DISABLED") by the user. \
                \(enabled ? "It will connect now and its tools become available again." : "Its session is being torn down and its \(item.tools.count) tool(s) will not resolve until re-enabled; configuration and Keychain secrets are kept.")
                """)

            if enabled {
                Task { await MCPConnectionCoordinator.shared.connectIfNeeded(sourceID: sourceID) }
            } else {
                Task { @MainActor in
                    await MCPClientService.shared.disconnect(sourceId: sourceID)
                }
            }
        } catch {
            logger.error("[MCP-STORE] Failed to toggle source \(sourceID): \(error.localizedDescription). The server's enabled state is unchanged.")
        }
    }

    /// Updates an existing tool source configuration and its tools. `secrets`
    /// fully replaces what's currently in Keychain for this source — env-var
    /// removals and auth-scheme changes both take effect.
    func updateTool(
        id: UUID,
        serverName: String,
        serverDefinition: ServerDefinition,
        secrets: MCPRuntimeSecrets,
        newTools: [ToolDefinition]
    ) {
        guard let context = requireContext("updateTool(id:)", consequence: "the edit to this MCP server was DISCARDED — its configuration, tools and Keychain secrets are unchanged on disk.") else { return }

        let targetID = id
        let predicate = #Predicate<MCPToolItem> { $0.id == targetID }
        var descriptor = FetchDescriptor<MCPToolItem>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            guard let item = try context.fetch(descriptor).first else {
                logger.warning("MCPToolStore: Tool source with ID \(id) not found for update.")
                return
            }

            // Capture the previous env-key set to purge keys removed in this edit; read before mutating `mcpConfigData`.
            // An undecodable or missing blob purges nothing (deleting on an uncertain read is unsafe), but the skip is logged.
            let previousEnvKeys: Set<String> = {
                guard let data = item.mcpConfigData else {
                    Self.logBlobIntegrity(
                        "[PERSISTENCE] Updating MCP source '\(serverName)' (id \(id)) whose "
                        + "mcpConfigData is MISSING. CONSEQUENCE: the previous env-key set is "
                        + "unknowable, so NO env-var secrets are purged in this edit — any key the "
                        + "user removed keeps its Keychain entry. Purge leftovers by hand from "
                        + "Keychain Access (search \"\(id.uuidString)\") if this source held credentials."
                    )
                    return []
                }
                do {
                    let prev = try JSONDecoder().decode(ServerDefinition.self, from: data)
                    return Set(prev.envKeys ?? [])
                } catch {
                    Self.logBlobIntegrity(
                        "[PERSISTENCE] Updating MCP source '\(serverName)' (id \(id)) whose "
                        + "mcpConfigData is UNDECODABLE (\(data.count) bytes) — \(error). "
                        + "CONSEQUENCE: the previous env-key set is unknowable, so NO env-var "
                        + "secrets are purged in this edit — any key the user removed keeps its "
                        + "Keychain entry. Purge leftovers by hand from Keychain Access "
                        + "(search \"\(id.uuidString)\") if this source held credentials."
                    )
                    return []
                }
            }()

            item.serverName = serverName
            // Assign only on success: a failed encode must not null the column and erase a working saved configuration.
            do {
                item.mcpConfigData = BlobVersioning.stamped(
                    try JSONEncoder().encode(serverDefinition), version: MCPToolItem.configBlobVersion)
            } catch {
                logger.error(
                    "[PERSISTENCE] Failed to encode ServerDefinition for MCP source '\(serverName)' "
                    + "(id \(id)): \(error). CONSEQUENCE: mcpConfigData is left exactly as it was, so "
                    + "the previously-saved server configuration still works; this edit did NOT "
                    + "reach disk and must be re-applied."
                )
            }

            // Cascade-delete child tool defs and rebuild from `newTools`; read what must survive before the children are deleted.
            let previousByName = Dictionary(item.tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            let preserved = newTools.map { previousByName[$0.name]?.blobsToPreserve(whenRebuiltFrom: $0) }
            for existingTool in item.tools {
                context.delete(existingTool)
            }
            item.tools.removeAll()
            for (tool, keep) in zip(newTools, preserved) {
                let child = createToolDefinitionModel(from: tool, preserving: keep)
                item.tools.append(child)
            }

            // Why: use `delete`, not `clear`: removed keys come from the blob, not the Keychain, so an unreadable Keychain
            // cannot fabricate a removal, and a guarded `clear` would keep a secret the user dropped.
            // Replace secrets atomically: purge removed env keys, then write the new set; `persistSecrets` reconciles auth scopes.
            let newEnvKeys = Set(serverDefinition.envKeys ?? [])
            let removedEnvKeys = previousEnvKeys.subtracting(newEnvKeys)
            for key in removedEnvKeys {
                MCPSecretStore.shared.delete(scope: .envValue(key: key), sourceID: id)
            }
            persistSecrets(secrets, definition: serverDefinition, sourceID: id)

            saveContext()
            fetchTools()
        } catch {
            logger.error("MCPToolStore: Failed to fetch tool item for update: \(error.localizedDescription)")
        }
    }

    /// Deletes a specific tool source. Purges every Keychain secret tied to it
    /// before removing the SwiftData record so we never leave orphaned secrets
    /// in the user's Keychain.
    func deleteTool(toolSource: ToolSource) {
        guard let context = requireContext("deleteTool", consequence: "the MCP source was NOT deleted; its row, tools and Keychain secrets all remain.") else { return }

        let targetID = toolSource.id
        let predicate = #Predicate<MCPToolItem> { $0.id == targetID }
        var descriptor = FetchDescriptor<MCPToolItem>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            if let item = try context.fetch(descriptor).first {
                // These keys name the Keychain entries to purge and live inside the blob being deleted: if it is missing or undecodable,
                // nothing can be purged, so the row is still deleted but the resulting orphaned secrets are logged.
                let envKeys: Set<String> = {
                    guard let data = item.mcpConfigData else {
                        Self.logBlobIntegrity(
                            "[PERSISTENCE] Deleting MCP source '\(item.serverName)' (\(targetID)) whose "
                            + "mcpConfigData is MISSING. CONSEQUENCE: its env-var secrets CANNOT be "
                            + "identified and are left in the Keychain with nothing referencing them. "
                            + "Purge them by hand from Keychain Access (search \"\(targetID.uuidString)\") "
                            + "if this source held credentials."
                        )
                        return []
                    }
                    do {
                        return Set(try JSONDecoder().decode(ServerDefinition.self, from: data).envKeys ?? [])
                    } catch {
                        Self.logBlobIntegrity(
                            "[PERSISTENCE] Deleting MCP source '\(item.serverName)' (\(targetID)) whose "
                            + "mcpConfigData is UNDECODABLE (\(data.count) bytes) — \(error). "
                            + "CONSEQUENCE: its env-var secrets CANNOT be identified and are left in the "
                            + "Keychain with nothing referencing them. Purge them by hand from Keychain "
                            + "Access if this source held credentials."
                        )
                        return []
                    }
                }()
                // Tear the live session down before dropping the record, or the MCP client and its child process would run with no
                // owner and no UI entry, holding its port and pipes until the app quits.
                Task { @MainActor in
                    await MCPClientService.shared.disconnect(sourceId: targetID)
                    logger.info("[MCP-LIFECYCLE] Disconnected session for deleted source \(targetID).")
                }

                // Withdraw the grant at the provider, not just locally, so removing a server revokes the access the user granted.
                // Fire-and-forget; it reads the bundle before `purgeAll` deletes it.
                if let bundle = MCPOAuthCoordinator.loadBundle(sourceID: targetID) {
                    Task { await MCPOAuthCoordinator.revokeTokens(sourceID: targetID, bundle: bundle) }
                }

                MCPSecretStore.shared.purgeAll(sourceID: targetID, knownEnvKeys: envKeys)
                MCPLogStore.shared.purge(sourceID: targetID)

                context.delete(item) // Cascade deletes children
                saveContext()
                fetchTools()
            }
        } catch {
            logger.error("Failed to fetch tool item for deletion: \(error.localizedDescription)")
        }
    }

    /// Swaps the tool list for an existing source without touching its `mcpConfigData` or Keychain secrets.
    /// Used by the `tools/list_changed` listener: only the tools changed, not the definition, auth or env keys.
    func replaceTools(forSourceID sourceID: UUID, with newTools: [ToolDefinition]) {
        guard let context = requireContext("replaceTools(forSourceID:)", consequence: "the freshly-discovered tool list was DISCARDED — this server keeps its previous tools, which may no longer match what it actually offers.") else { return }

        let predicate = #Predicate<MCPToolItem> { $0.id == sourceID }
        var descriptor = FetchDescriptor<MCPToolItem>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            guard let item = try context.fetch(descriptor).first else {
                logger.warning("MCPToolStore.replaceTools: source \(sourceID) not found.")
                return
            }

            // Read what must survive before the children are deleted.
            let previousByName = Dictionary(item.tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            let preserved = newTools.map { previousByName[$0.name]?.blobsToPreserve(whenRebuiltFrom: $0) }
            for existingTool in item.tools {
                context.delete(existingTool)
            }
            item.tools.removeAll()

            for (tool, keep) in zip(newTools, preserved) {
                let child = createToolDefinitionModel(from: tool, preserving: keep)
                item.tools.append(child)
            }

            saveContext()
            fetchTools()
        } catch {
            logger.error("MCPToolStore.replaceTools: \(error.localizedDescription)")
        }
    }

    // MARK: - Secret persistence

    // Why: not `private`: it touches only `MCPSecretStore`, so tests can drive it with an injected Keychain and prove the wiring.
    /// Writes every secret in `secrets` to Keychain under `sourceID`; `definition` only supplies the auth-scheme shape.
    /// Idempotent: clears every non-target auth scope first, so a scheme change never leaves orphaned secrets.
    /// The OAuth bundle is owned by the container layer; it is only cleared here on scheme transitions away from oauth.
    func persistSecrets(
        _ secrets: MCPRuntimeSecrets,
        definition: ServerDefinition,
        sourceID: UUID
    ) {
        // Env values. An empty value routes through `MCPSecretStore.clear`, so a value the form
        // could not read comes back as "" and is REFUSED rather than deleted.
        for (key, value) in secrets.env {
            MCPSecretStore.shared.store(value, for: .envValue(key: key), sourceID: sourceID)
        }

        // Reconcile to a target, do not wipe first: a save that fails to materialise a header (every save where the Keychain
        // could not be read) must not clear the stored credential on its way to an early return.
        let target: (scope: MCPSecretScope, value: String)? = {
            guard let header = secrets.authorizationHeader else { return nil }
            switch definition.auth {
            case .bearer:
                // Strip the "Bearer " prefix the runtime carries — Keychain stores the raw token
                // only, so it can be reused if the scheme changes.
                let token = header.value.hasPrefix("Bearer ")
                    ? String(header.value.dropFirst("Bearer ".count))
                    : header.value
                return (.bearerToken, token)
            case .apiKeyHeader:
                return (.apiKeyHeaderValue, header.value)
            case .none, .oauth:
                // `.oauth`'s bundle is owned by the container layer; `.none` stores nothing.
                return nil
            }
        }()

        // Why: `clear`, never `delete`: an unreadable secret is kept, not destroyed.
        // Clear every auth scope that is not the target, so a scheme change leaves no orphan.
        for scope in [MCPSecretScope.bearerToken, .apiKeyHeaderValue] where scope != target?.scope {
            MCPSecretStore.shared.clear(scope: scope, sourceID: sourceID)
        }
        if case .oauth = definition.auth {
            // The bundle is owned by the container layer, but this layer reconciles its binding on every save: a bundle provably
            // bound to a different URL is cleared (guarded); anything unprovable is kept, and `MCPOAuthBinding` enforces at attach.
            if let storedJSON = MCPSecretStore.shared.retrieve(.oauthBundle, sourceID: sourceID),
               MCPOAuthBinding.isProvablyMisbound(storedJSON: storedJSON, serverURLString: definition.url) {
                MCPSecretStore.shared.clear(scope: .oauthBundle, sourceID: sourceID)
                logger.error(
                    "[MCP-OAUTH] Cleared the OAuth bundle for source \(sourceID.uuidString): it was bound to a different server URL than the saved definition. CONSEQUENCE: this server has no credentials until the user signs in again; no token was sent anywhere under the old binding."
                )
            }
        } else {
            MCPSecretStore.shared.clear(scope: .oauthBundle, sourceID: sourceID)
        }

        // Write the target last, so nothing above can have removed what we are about to store.
        if let target {
            MCPSecretStore.shared.store(target.value, for: target.scope, sourceID: sourceID)
        }
    }

    // MARK: - Proactive OAuth refresh

    /// Refreshes any OAuth bundle within 5 minutes of expiry, on a background Task per source.
    /// Swallows all errors: a failure only means the next tool call takes the reactive refresh path in `DynamicMCPTool`.
    private func refreshNearExpiryOAuthBundles() {
        guard let context = requireContext("refreshNearExpiryOAuthBundles", consequence: "no near-expiry OAuth token is refreshed this launch; affected servers will fail on their next call until re-authenticated.") else { return }
        let descriptor = FetchDescriptor<MCPToolItem>()
        guard let items = try? context.fetch(descriptor) else { return }

        for item in items {
            guard let data = item.mcpConfigData,
                  let def = try? JSONDecoder().decode(ServerDefinition.self, from: data),
                  case .oauth = def.auth,
                  let bundle = MCPOAuthCoordinator.loadBundle(sourceID: item.id),
                  bundle.isAccessTokenNearExpiry() else { continue }

            let sourceID = item.id
            let serverName = item.serverName
            Task { @MainActor in
                do {
                    _ = try await MCPOAuthCoordinator.refresh(sourceID: sourceID)
                    logger.info("Proactively refreshed OAuth tokens for \(serverName)")
                } catch {
                    logger.warning("Proactive OAuth refresh failed for \(serverName): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Private Helper Methods

    /// - Parameter preserving: stored blobs that could not be read and are handed back as placeholders (`blobsToPreserve`).
    ///   Each non-nil one is written back byte-for-byte instead of encoding the placeholder over it.
    private func createToolDefinitionModel(
        from tool: ToolDefinition,
        preserving keep: (parameters: Data?, icons: Data?, annotations: Data?)? = nil
    ) -> MCPToolDefinitionModel {
        if let keep, keep.parameters != nil || keep.icons != nil || keep.annotations != nil {
            logger.notice("[PERSISTENCE] MCP tool '\(tool.name)': keeping \([keep.parameters != nil ? "parameters" : nil, keep.icons != nil ? "icons" : nil, keep.annotations != nil ? "annotations" : nil].compactMap { $0 }.joined(separator: ", ")) stored bytes this build cannot read, instead of overwriting them with the empty placeholder it loaded. CONSEQUENCE: the tool keeps working as it did on this build, and the original schema survives for a build that can read it.")
        }
        return MCPToolDefinitionModel(
            name: tool.name,
            toolDescription: tool.description,
            requiresConfirmation: tool.requiresConfirmation,
            parametersData: keep?.parameters ?? (try? JSONEncoder().encode(tool.parameters))
                .map { BlobVersioning.stamped($0, version: MCPToolDefinitionModel.parametersBlobVersion) },
            title: tool.title,
            iconsData: keep?.icons ?? tool.icons.flatMap { try? JSONEncoder().encode($0) },
            annotationsData: keep?.annotations ?? tool.annotations.flatMap { try? JSONEncoder().encode($0) }
        )
    }

    /// Fetches all tool items and updates the published `sources` array.
    private func fetchTools() {
        guard let context = requireContext("fetchTools", consequence: "the tool-source list is left EMPTY, so every MCP server disappears from the UI and none of their tools resolve.") else { return }

        do {
            let descriptor = FetchDescriptor<MCPToolItem>(
                sortBy: [SortDescriptor(\.serverName, order: .forward)]
            )
            let results = try context.fetch(descriptor)
            self.sources = results.map { $0.toToolSource() }
        } catch {
            logger.error("Failed to fetch tools: \(error.localizedDescription)")
            self.sources = []
        }
    }

    private func saveContext() {
        guard let context = requireContext("saveContext", consequence: "pending MCP changes were NOT written to disk and are lost when the app quits.") else { return }
        do {
            try SharedContextSave.save(context, "MCP tools")
        } catch {
            logger.error("Failed to save SwiftData context: \(error.localizedDescription)")
        }
    }
}

// MARK: - Host bridge

/// The tool-list sink `MCPClientService` writes through. `replaceTools` already had exactly
/// this shape, so conformance is a declaration and nothing more — see MCPHostBridge.swift
/// for why the call is indirect.
extension MCPToolStore: MCPToolListSink {}

/// The source of truth for which MCP servers exist, for `MCPConnectionCoordinator`. Kept
/// separate from `MCPToolListSink` so the client service cannot reach it — see
/// MCPHostBridge.swift.
extension MCPToolStore: MCPSourceStore {}
