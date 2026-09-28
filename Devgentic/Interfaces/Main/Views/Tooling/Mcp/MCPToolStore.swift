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
    /// - Parameter migrateLegacySecrets: whether the one-shot legacy-secrets migration may run this
    ///   launch. Pass the launch-sweep decision — this migration REWRITES `mcpConfigData` blobs and
    ///   moves values into the Keychain, so it belongs to the same destructive class as
    ///   `pruneOldRecords` and the two `reconcileOrphans` sweeps and must be gated identically.
    ///
    ///   ⚠️ It used to run unconditionally from here, which is called synchronously in the App
    ///   struct's initializer — i.e. BEFORE `evaluateLaunchSweep()`. So on the first launch after a
    ///   schema change, the gate correctly deferred the other three sweeps while this one had already
    ///   rewritten secrets against possibly-degraded rows. That defeated the gate for one of the five
    ///   operations it was created to cover (SWIFTDATA_GAP_REGISTER.md G44).
    ///
    ///   Skipping only postpones it: the `mcp.secrets.migrated.v1` flag stays unset, so the next
    ///   launch runs it normally.
    func configureContainer(_ container: ModelContainer, migrateLegacySecrets: Bool) {
        self.modelContainer = container
        if migrateLegacySecrets {
            // ⚠️ REFUSED under XCTest. The test host is the real app on the real store, but its
            // Keychain is an in-memory stand-in (`TestHostKeychain`, registers KC-54/55) — a
            // "successful" secret write here proves nothing, and the blob rewrite that follows it
            // would strip real secrets into a store that vanishes with the process. Same class as
            // `BackendProfileStore.migrateAPIKeysToKeychain`; the flag stays unset, so the app's own
            // next launch runs it normally.
            if TestHost.permits("migrate legacy MCP secrets out of the config blobs into the Keychain", logger: logger) {
                migrateLegacySecretsIfNeeded()
            }
        } else {
            logger.notice(
                "[STARTUP] MCP legacy-secrets migration DEFERRED — the launch sweep is not running "
                + "this launch. CONSEQUENCE: any pre-Keychain inline secrets stay inline for now and "
                + "are migrated on the next launch; MCP servers still connect normally meanwhile."
            )
        }
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

        let item = MCPToolItem(
            id: newID,
            serverName: serverName,
            // Stamped (G19) so a future reader can ask what shape this is instead of guessing.
            mcpConfigData: (try? JSONEncoder().encode(serverDefinition))
                .map { BlobVersioning.stamped($0, version: MCPToolItem.configBlobVersion) }
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
            let previousEnvKeys: Set<String> = {
                guard let data = item.mcpConfigData,
                      let prev = try? JSONDecoder().decode(ServerDefinition.self, from: data),
                      let keys = prev.envKeys else { return [] }
                return Set(keys)
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
            for existingTool in item.tools {
                context.delete(existingTool)
            }
            item.tools.removeAll()
            for tool in newTools {
                let child = createToolDefinitionModel(from: tool)
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
                let envKeys: Set<String> = {
                    guard let data = item.mcpConfigData else { return [] }
                    do {
                        return Set(try JSONDecoder().decode(ServerDefinition.self, from: data).envKeys ?? [])
                    } catch {
                        logger.error(
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

    // MARK: - Legacy migration

    /// One-time pass: read any pre-Phase-1 `mcpConfigData` blobs (which carry
    /// inline `env` / `authentication` payloads), lift the secret material
    /// into Keychain, and re-encode the blob in the new shape. Idempotent —
    /// keyed by a UserDefaults flag so it never runs twice.
    /// ⚠️ TEST SEAM: `defaults` is injectable and this is not `private`, mirroring
    /// `ProviderKeyStore.purgeLegacyPlaintextKeys(defaults:)`. The one-shot flag lives in
    /// `UserDefaults`, so without this a test could neither run the migration (the flag is already
    /// set on any machine that has launched the app) nor avoid writing to the developer's real
    /// preferences domain to clear it. Production always uses `.standard`.
    func migrateLegacySecretsIfNeeded(defaults: UserDefaults = .standard) {
        guard let context = requireContext("migrateLegacySecretsIfNeeded", consequence: "the one-shot legacy-secrets migration did not run; inline secrets stay in plaintext on disk and it retries next launch.") else { return }

        let migrationKey = "mcp.secrets.migrated.v1"
        if defaults.bool(forKey: migrationKey) {
            return
        }

        do {
            let descriptor = FetchDescriptor<MCPToolItem>()
            let items = try context.fetch(descriptor)
            var migratedCount = 0
            var migrationFailures = 0
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

                // ⚠️⚠️ EVERY `store` RESULT IS LOAD-BEARING HERE — register KC-6. These returns used
                // to be discarded, and execution fell through to the blob rewrite below, which
                // replaces the legacy shape with one that carries only env KEY NAMES and no secret
                // material. So a Keychain write that failed left the secret in NEITHER place: gone
                // from the blob, never written to the Keychain, unrecoverable.
                //
                // And this is not a rare path. It runs unattended at launch over every source, and
                // the launch most likely to fail is the FIRST ONE AFTER AN UPDATE — precisely when
                // a re-signed binary makes macOS re-prompt for Keychain access and an unattended
                // login-item launch has nobody there to answer it.
                //
                // The rule the encode failure below already follows: do not count it as migrated if
                // it did not persist. This applies it to the Keychain half too.
                var secretsPersisted = true

                // Lift env values into Keychain.
                var envKeys: [String] = []
                if let env = legacy.env {
                    for (k, v) in env where !v.isEmpty {
                        if !MCPSecretStore.shared.store(v, for: .envValue(key: k), sourceID: item.id) {
                            secretsPersisted = false
                            logger.error(
                                "[MCP-SECRETS] Legacy migration could not write env value '\(k)' for "
                                + "MCP source '\(item.serverName)' (id \(item.id)) to the Keychain. "
                                + "CONSEQUENCE: this source's blob is NOT rewritten, so the secret "
                                + "stays readable in its legacy inline form and the migration is "
                                + "retried on the next launch."
                            )
                        }
                        envKeys.append(k)
                    }
                }

                // Lift bearer-style token (the only legacy auth shape we ever
                // wrote) into Keychain and set scheme to `.bearer`.
                var auth: MCPAuthenticationScheme = .none
                if let token = legacy.authentication?["token"], !token.isEmpty {
                    if MCPSecretStore.shared.store(token, for: .bearerToken, sourceID: item.id) {
                        auth = .bearer
                    } else {
                        secretsPersisted = false
                        logger.error(
                            "[MCP-SECRETS] Legacy migration could not write the bearer token for MCP "
                            + "source '\(item.serverName)' (id \(item.id)) to the Keychain. "
                            + "CONSEQUENCE: this source's blob is NOT rewritten, so the token stays "
                            + "in its legacy inline form and the server keeps working; the migration "
                            + "is retried on the next launch."
                        )
                    }
                }

                // ⚠️ Bail BEFORE the rewrite. The blob is the only remaining copy of any secret
                // whose Keychain write failed, so leaving it byte-intact is what makes this
                // recoverable. `migrationFailures` keeps the one-shot flag unset so it retries.
                guard secretsPersisted else {
                    migrationFailures += 1
                    continue
                }

                let migrated = ServerDefinition(
                    command: legacy.command,
                    args: legacy.args,
                    envKeys: envKeys.isEmpty ? nil : envKeys.sorted(),
                    url: legacy.url,
                    auth: auth
                )
                // ⚠️ Same rule as `updateTool`, and it matters more here: this runs unattended at
                // launch over EVERY source. A `try?` would have nulled a working configuration while
                // the secrets had already been moved to the Keychain, leaving the source unusable
                // and unrecoverable. Don't count it as migrated if it did not persist, or the
                // `mcp.secrets.migrated.v1` flag would be set for a source that still needs it.
                do {
                    item.mcpConfigData = BlobVersioning.stamped(
                        try JSONEncoder().encode(migrated), version: MCPToolItem.configBlobVersion)
                    migratedCount += 1
                } catch {
                    migrationFailures += 1
                    logger.error(
                        "[PERSISTENCE] Failed to encode migrated ServerDefinition for MCP source "
                        + "'\(item.serverName)' (id \(item.id)): \(error). CONSEQUENCE: this source's "
                        + "mcpConfigData is left at its legacy shape and still works; it is retried "
                        + "on the next launch because the migration flag is not set below."
                    )
                }
            }

            if migratedCount > 0 {
                try context.save()
                logger.info("Migrated \(migratedCount) MCP source(s) to Keychain-backed secrets.")
            }
            // ⚠️ Only claim the migration is done if nothing was left behind. Setting the flag with
            // failures outstanding would strand those sources at their legacy shape forever, with
            // their secrets already moved to the Keychain and nothing left to retry the move.
            if migrationFailures == 0 {
                defaults.set(true, forKey: migrationKey)
            } else {
                logger.error(
                    "[PERSISTENCE] Legacy-secrets migration INCOMPLETE — \(migratedCount) source(s) "
                    + "migrated, \(migrationFailures) failed to encode. CONSEQUENCE: the migration "
                    + "flag is NOT set, so the whole pass retries on the next launch; already-migrated "
                    + "sources are idempotent and will simply be skipped."
                )
            }
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
            parametersData: (try? JSONEncoder().encode(tool.parameters))
                .map { BlobVersioning.stamped($0, version: MCPToolDefinitionModel.parametersBlobVersion) },
            title: tool.title,
            iconsData: tool.icons.flatMap { try? JSONEncoder().encode($0) },
            annotationsData: tool.annotations.flatMap { try? JSONEncoder().encode($0) }
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
            try context.save()
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
