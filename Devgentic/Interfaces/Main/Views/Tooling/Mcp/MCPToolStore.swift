//
//  MCPToolStore.swift
//  Devgentic
//
//  Created by Raj Singh on 28/09/25.
//
//  Migrated to SwiftData on 26/03/26.
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

    /// Array of tool sources that the UI can observe for changes.
    var sources: [ToolSource] = []

    /// The shared model container, configured once at app startup.
    private(set) var modelContainer: ModelContainer?

    private var mainContext: ModelContext? {
        modelContainer?.mainContext
    }

    /// Call this once from the App init to inject the container. Also runs the
    /// one-time legacy-secrets migration (lifts inline `env` / `authentication`
    /// blobs into Keychain so they're no longer in plaintext on disk) and
    /// kicks off a proactive OAuth-token refresh for any near-expiry bundles.
    func configureContainer(_ container: ModelContainer) {
        self.modelContainer = container
        migrateLegacySecretsIfNeeded()
        fetchTools()
        refreshNearExpiryOAuthBundles()
    }

    /// Private initializer to enforce singleton pattern.
    private init() {}

    // MARK: - Public CRUD Methods

    /// Adds a new tool source. `secrets` carries the env values + auth token
    /// the user typed into the form; we persist them to Keychain under the
    /// newly-generated source ID, never inline. Returns the new source ID so
    /// callers (e.g. the form) can clean up any temp-ID Keychain entries.
    @discardableResult
    func addTool(
        serverName: String,
        serverDefinition: ServerDefinition,
        secrets: MCPRuntimeSecrets,
        newTools: [ToolDefinition]
    ) -> UUID? {
        guard let context = mainContext else { return nil }

        let newID = UUID()
        let item = MCPToolItem(
            id: newID,
            serverName: serverName,
            mcpConfigData: try? JSONEncoder().encode(serverDefinition)
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
        guard let context = mainContext else { return }

        let targetID = id
        let predicate = #Predicate<MCPToolItem> { $0.id == targetID }
        var descriptor = FetchDescriptor<MCPToolItem>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            guard let item = try context.fetch(descriptor).first else {
                logger.warning("MCPToolStore: Tool source with ID \(id) not found for update.")
                return
            }

            // Capture the previous env-key set so we can purge any keys the
            // user removed in this edit. Read before mutating mcpConfigData.
            let previousEnvKeys: Set<String> = {
                guard let data = item.mcpConfigData,
                      let prev = try? JSONDecoder().decode(ServerDefinition.self, from: data),
                      let keys = prev.envKeys else { return [] }
                return Set(keys)
            }()

            item.serverName = serverName
            item.mcpConfigData = try? JSONEncoder().encode(serverDefinition)

            // Cascade-delete child tool defs and rebuild from `newTools`.
            for existingTool in item.tools {
                context.delete(existingTool)
            }
            item.tools.removeAll()
            for tool in newTools {
                let child = createToolDefinitionModel(from: tool)
                item.tools.append(child)
            }

            // Replace secrets atomically: purge removed env keys, then write
            // the new set. Auth scopes are always overwritten.
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
        guard let context = mainContext else { return }

        let targetID = toolSource.id
        let predicate = #Predicate<MCPToolItem> { $0.id == targetID }
        var descriptor = FetchDescriptor<MCPToolItem>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            if let item = try context.fetch(descriptor).first {
                let envKeys: Set<String> = {
                    guard let data = item.mcpConfigData,
                          let def = try? JSONDecoder().decode(ServerDefinition.self, from: data),
                          let keys = def.envKeys else { return [] }
                    return Set(keys)
                }()
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

    /// Replace the tool list for an existing source without touching its
    /// `mcpConfigData` or any Keychain secrets. Used by the
    /// `tools/list_changed` listener — the underlying ServerDefinition,
    /// auth, and env keys are unchanged; only the tools themselves moved.
    func replaceTools(forSourceID sourceID: UUID, with newTools: [ToolDefinition]) {
        guard let context = mainContext else { return }

        let predicate = #Predicate<MCPToolItem> { $0.id == sourceID }
        var descriptor = FetchDescriptor<MCPToolItem>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            guard let item = try context.fetch(descriptor).first else {
                logger.warning("MCPToolStore.replaceTools: source \(sourceID) not found.")
                return
            }

            for existingTool in item.tools {
                context.delete(existingTool)
            }
            item.tools.removeAll()

            for tool in newTools {
                let child = createToolDefinitionModel(from: tool)
                item.tools.append(child)
            }

            saveContext()
            fetchTools()
        } catch {
            logger.error("MCPToolStore.replaceTools: \(error.localizedDescription)")
        }
    }

    // MARK: - Secret persistence

    /// Writes every secret in `secrets` to Keychain under `sourceID`. The
    /// `definition` is consulted only for the auth-scheme shape; we don't
    /// persist auth tokens whose scheme was set to `.none`.
    ///
    /// Idempotency: clears every auth scope first, then writes the one that
    /// matches the new scheme. This way a scheme change (bearer → apiKey,
    /// oauth → none, etc.) never leaves orphaned secrets in Keychain.
    /// The OAuth *bundle* is owned by the container layer (`AddMCPServerContainerView.handleAdd/Update`)
    /// since it requires a richer Codable shape than this method handles —
    /// we just clear it on scheme transitions away from oauth.
    private func persistSecrets(
        _ secrets: MCPRuntimeSecrets,
        definition: ServerDefinition,
        sourceID: UUID
    ) {
        // Env values
        for (key, value) in secrets.env {
            MCPSecretStore.shared.store(value, for: .envValue(key: key), sourceID: sourceID)
        }

        // Wipe every auth scope first. The single "right" scope gets re-written
        // below when the scheme requires it.
        MCPSecretStore.shared.delete(scope: .bearerToken, sourceID: sourceID)
        MCPSecretStore.shared.delete(scope: .apiKeyHeaderValue, sourceID: sourceID)
        if case .oauth = definition.auth {
            // Keep the oauth bundle — container layer manages it.
        } else {
            MCPSecretStore.shared.delete(scope: .oauthBundle, sourceID: sourceID)
        }

        guard let header = secrets.authorizationHeader else { return }

        switch definition.auth {
        case .none:
            break
        case .bearer:
            // Strip the "Bearer " prefix the runtime carries — Keychain stores
            // the raw token only, so it can be reused if the scheme changes.
            let token = header.value.hasPrefix("Bearer ")
                ? String(header.value.dropFirst("Bearer ".count))
                : header.value
            MCPSecretStore.shared.store(token, for: .bearerToken, sourceID: sourceID)
        case .apiKeyHeader:
            MCPSecretStore.shared.store(header.value, for: .apiKeyHeaderValue, sourceID: sourceID)
        case .oauth:
            // Bundle persistence happens in the container layer.
            break
        }
    }

    // MARK: - Proactive OAuth refresh

    /// Walks every persisted MCP source and refreshes any OAuth bundle that
    /// is within 5 minutes of expiry. Runs on a background Task per source so
    /// we don't serialize on the slowest provider, and swallows all errors —
    /// failure here just means the next tool call will hit the reactive
    /// refresh path in `DynamicMCPTool` instead.
    private func refreshNearExpiryOAuthBundles() {
        guard let context = mainContext else { return }
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

    // MARK: - Legacy migration

    /// One-time pass: read any pre-Phase-1 `mcpConfigData` blobs (which carry
    /// inline `env` / `authentication` payloads), lift the secret material
    /// into Keychain, and re-encode the blob in the new shape. Idempotent —
    /// keyed by a UserDefaults flag so it never runs twice.
    private func migrateLegacySecretsIfNeeded() {
        guard let context = mainContext else { return }

        let migrationKey = "mcp.secrets.migrated.v1"
        if UserDefaults.standard.bool(forKey: migrationKey) {
            return
        }

        do {
            let descriptor = FetchDescriptor<MCPToolItem>()
            let items = try context.fetch(descriptor)
            var migratedCount = 0
            for item in items {
                guard let data = item.mcpConfigData,
                      let legacy = try? JSONDecoder().decode(LegacyServerDefinition.self, from: data) else {
                    continue
                }

                // Only proceed if the blob actually has legacy secrets — a
                // ServerDefinition encoded post-migration won't decode the
                // legacy keys (they'll just be nil), so this branch no-ops.
                let hasLegacyEnv = !(legacy.env?.isEmpty ?? true)
                let hasLegacyAuth = !(legacy.authentication?.isEmpty ?? true)
                guard hasLegacyEnv || hasLegacyAuth else { continue }

                // Lift env values into Keychain.
                var envKeys: [String] = []
                if let env = legacy.env {
                    for (k, v) in env where !v.isEmpty {
                        MCPSecretStore.shared.store(v, for: .envValue(key: k), sourceID: item.id)
                        envKeys.append(k)
                    }
                }

                // Lift bearer-style token (the only legacy auth shape we ever
                // wrote) into Keychain and set scheme to `.bearer`.
                var auth: MCPAuthenticationScheme = .none
                if let token = legacy.authentication?["token"], !token.isEmpty {
                    MCPSecretStore.shared.store(token, for: .bearerToken, sourceID: item.id)
                    auth = .bearer
                }

                let migrated = ServerDefinition(
                    command: legacy.command,
                    args: legacy.args,
                    envKeys: envKeys.isEmpty ? nil : envKeys.sorted(),
                    url: legacy.url,
                    auth: auth
                )
                item.mcpConfigData = try? JSONEncoder().encode(migrated)
                migratedCount += 1
            }

            if migratedCount > 0 {
                try context.save()
                logger.info("Migrated \(migratedCount) MCP source(s) to Keychain-backed secrets.")
            }
            UserDefaults.standard.set(true, forKey: migrationKey)
        } catch {
            // Don't set the migrated flag — we'll retry on next launch.
            logger.error("Legacy-secrets migration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helper Methods

    private func createToolDefinitionModel(from tool: ToolDefinition) -> MCPToolDefinitionModel {
        MCPToolDefinitionModel(
            name: tool.name,
            toolDescription: tool.description,
            requiresConfirmation: tool.requiresConfirmation,
            parametersData: try? JSONEncoder().encode(tool.parameters),
            title: tool.title,
            iconsData: tool.icons.flatMap { try? JSONEncoder().encode($0) },
            annotationsData: tool.annotations.flatMap { try? JSONEncoder().encode($0) }
        )
    }

    /// Fetches all tool items and updates the published `sources` array.
    private func fetchTools() {
        guard let context = mainContext else { return }

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
        guard let context = mainContext else { return }
        do {
            try context.save()
        } catch {
            logger.error("Failed to save SwiftData context: \(error.localizedDescription)")
        }
    }
}
