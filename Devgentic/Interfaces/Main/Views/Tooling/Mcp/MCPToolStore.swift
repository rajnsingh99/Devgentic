// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    /// ⚠️ TEST SEAM (register KC-37, the KC-52 shape). When set, receives exactly the messages the
    /// config-blob integrity paths log — an `updateTool`/`deleteTool` whose `mcpConfigData` cannot
    /// yield an env-key set, and an `addTool` whose definition cannot be encoded. Those paths used
    /// to be silent, and silence is the whole defect: an orphaned secret nobody was told about.
    /// One message for the sink and the logger alike; the seam cannot drift from the log.
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

    /// Resolves the model context, LOGGING the user-visible consequence when it is missing.
    ///
    /// ⚠️ Every caller used a bare `guard let context = mainContext else { return }` — eight of them
    /// (G53). `mainContext` is nil only when `configureContainer` has not run, which should not
    /// happen after launch; but if it ever does, the user's action vanished with no error, no
    /// message and nothing in the log. "Should not happen" is exactly when a log matters, because
    /// there is nothing else left to diagnose from.
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

    /// Adds a new tool source. `secrets` carries the env values + auth token
    /// the user typed into the form; we persist them to Keychain under the
    /// newly-generated source ID, never inline. Returns the new source ID so
    /// callers (e.g. the form) can clean up any temp-ID Keychain entries.
    @discardableResult
    /// - Parameter id: the new source's identity. Caller-supplied (defaulting to a fresh UUID) so a
    ///   credential that must be written BEFORE the row exists — the OAuth bundle, register KC-5 —
    ///   can be keyed on the final identity. See `MCPServerAddFlow`.
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

        // Encode the definition BEFORE any secret is written. ⚠️ Register KC-38: the `try?` that
        // used to build this blob could null it after `persistSecrets` had already stored the env
        // values — creating exactly the row `deleteTool` cannot clean up, a source whose env-key
        // names never reached disk while their secrets sit in the Keychain. Failing the add is
        // cheap here: nothing has been written yet, so there is nothing to clean up.
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

    /// Is `serverName` already taken by a DIFFERENT source?
    ///
    /// Adding a server checked for duplicates; renaming one did not, so an edit could
    /// produce two servers with the same name. That name is the user's only handle on a
    /// server in the sidebar, in tool categories and in every log line, so two of them is a
    /// genuine ambiguity rather than a cosmetic one.
    func isServerNameTaken(_ serverName: String, excluding sourceID: UUID? = nil) -> Bool {
        let trimmed = serverName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        return sources.contains { source in
            source.id != sourceID
                && source.serverName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmed
        }
    }

    /// Enables or disables a server without touching its configuration or secrets.
    ///
    /// Disabling disconnects immediately: leaving a live session behind would keep the
    /// child process running and the tools callable, which is precisely what the user just
    /// asked to stop.
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

            // Capture the previous env-key set so we can purge any keys the
            // user removed in this edit. Read before mutating mcpConfigData.
            //
            // ⚠️ Register KC-37: the `try?` that used to sit here turned an UNDECODABLE (or
            // MISSING) blob into an empty key set, so the purge below silently skipped — any
            // env-var secret the user had removed kept its Keychain entry with nothing left
            // pointing at it, and nothing said why. An unknowable key set purges NOTHING (the
            // key names live in the blob, and deleting on an uncertain read is the KC-1
            // hazard), but the skip must be stated, not silent.
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
            // ⚠️ Assign only on success. `try?` here nulled the column on an encoder throw, replacing
            // a WORKING saved configuration — command, args, envKeys, url, auth, transport — with
            // nothing, silently and with no log. The server then failed to connect with no
            // indication that its configuration had been erased rather than misconfigured (G90).
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

            // Cascade-delete child tool defs and rebuild from `newTools`.
            // CR-64: read what must survive BEFORE the children are deleted.
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

            // Replace secrets atomically: purge removed env keys, then write
            // the new set. Auth scopes are reconciled by `persistSecrets`.
            //
            // ⚠️ `delete`, NOT `clear`, and that is correct here — do not "fix" it. The KC-1 hazard
            // is a secret being destroyed because its VALUE could not be read; these keys come from
            // the blob (`previousEnvKeys` vs the form's `envKeys`), never from the Keychain, so an
            // unreadable Keychain cannot fabricate a removal. Reaching this line means the user
            // genuinely deleted the row from the form, and a guarded `clear` would refuse that
            // legitimate removal during an outage and silently keep a secret they asked to drop.
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
                // ⚠️ These keys NAME the Keychain entries to purge, and they live INSIDE the blob
                // being deleted. If the blob cannot be decoded we cannot know what to purge, and the
                // secrets outlive the source with nothing left pointing at them (G22). Silent before;
                // the row still gets deleted (the user asked for that), but the orphaning is stated.
                //
                // ⚠️ Register KC-38: the nil branch returned an empty key set in complete silence —
                // a blob that was never persisted (the addTool defect, now fixed at the source)
                // deleted its row while its env-var secrets stayed in the Keychain unnamed and
                // unexplained. Same consequence as the undecodable case below, so it gets the same
                // log: the row goes, the orphaning is stated, nothing is guessed at.
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
                // Tear the live session down BEFORE dropping the record. Deleting only the
                // SwiftData row left the MCP client and its child process running with no
                // owner and no UI entry — the server kept holding its port/pipes until the
                // app quit, and the user had no way to reach it.
                Task { @MainActor in
                    await MCPClientService.shared.disconnect(sourceId: targetID)
                    logger.info("[MCP-LIFECYCLE] Disconnected session for deleted source \(targetID).")
                }

                // Withdraw the grant at the provider, not just locally. Purging Keychain
                // alone left OAuth tokens valid at the issuer until natural expiry, so
                // "remove this server" did not actually revoke the access the user granted
                // it. Fire-and-forget: it reads the bundle before `purgeAll` deletes it.
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

    /// Replace the tool list for an existing source without touching its
    /// `mcpConfigData` or any Keychain secrets. Used by the
    /// `tools/list_changed` listener — the underlying ServerDefinition,
    /// auth, and env keys are unchanged; only the tools themselves moved.
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

            // CR-64: read what must survive BEFORE the children are deleted.
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
    /// ⚠️ TEST SEAM (registers KC-1 / KC-17): deliberately not `private`. This function touches no
    /// `ModelContext` — only `MCPSecretStore` — so a test can drive it directly with an injected
    /// Keychain and prove the WIRING, not just the policy. That distinction is load-bearing here:
    /// `MCPSecretStore.clear` refusing to delete an unreadable secret is worth nothing if this
    /// function calls `delete` instead, and a test of `clear` alone cannot catch that.
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

        // ⚠️⚠️ RECONCILE TO A TARGET — DO NOT WIPE FIRST. This used to delete `.bearerToken` and
        // `.apiKeyHeaderValue` unconditionally and only THEN hit
        // `guard let header = secrets.authorizationHeader else { return }`. So any save that failed
        // to materialise a header — which is every save where the Keychain could not be read, since
        // the form hydrates the field with `?? ""` and `buildRuntimeSecrets` only sets a header for
        // a non-empty secret — destroyed the stored credential on its way to an early return. The
        // user renamed a server and lost its token. Registers KC-1 and KC-17.
        //
        // Deciding the target state first makes the early return impossible: the scope that should
        // hold the secret is never cleared on the way to writing it.
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

        // Clear every auth scope that is NOT the target, so a scheme change leaves no orphan.
        // ⚠️ `clear`, never `delete`: an unreadable secret is kept, not destroyed.
        for scope in [MCPSecretScope.bearerToken, .apiKeyHeaderValue] where scope != target?.scope {
            MCPSecretStore.shared.clear(scope: scope, sourceID: sourceID)
        }
        if case .oauth = definition.auth {
            // ⚠️ Register KC-14: the bundle is owned by the container layer, but THIS layer
            // reconciles its binding on every save. A bundle PROVABLY bound to a different
            // URL than `definition` is cleared (a guarded clear — an unreadable bundle is
            // kept, not destroyed), so a repurposed row can never keep riding on another
            // host's tokens. Everything that cannot be proven — a legacy unbound bundle, an
            // undecodable blob, an unparseable URL — is KEPT: `MCPOAuthBinding` refuses to
            // attach those at the runtime layer instead, and the form gate is what demands
            // a re-auth. This reconcile is hygiene; the attach check is the enforcement.
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

    /// Walks every persisted MCP source and refreshes any OAuth bundle that
    /// is within 5 minutes of expiry. Runs on a background Task per source so
    /// we don't serialize on the slowest provider, and swallows all errors —
    /// failure here just means the next tool call will hit the reactive
    /// refresh path in `DynamicMCPTool` instead.
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

    /// - Parameter preserving: stored blobs that could not be read and are being handed back as
    ///   placeholders (`blobsToPreserve`, CR-64). Each non-nil one is written back byte-for-byte
    ///   instead of encoding the placeholder over it.
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
