// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MCPSecretStore.swift
//  Devgentic
//
//  Typed Keychain facade for MCP server secrets — bearer tokens, env-var values,
//  and (in Phase 2) OAuth credential bundles. Layers on top of `SecureKeyStorage`
//  with a per-source key namespace so we can wipe every secret tied to a server
//  with one call when the user removes it.
//
//  Service: "com.devgentic.mcp.secrets"
//  Account format: "<sourceID>::<scope>"
//      e.g. "B33A...::auth.bearer"
//      e.g. "B33A...::env.GITHUB_PERSONAL_ACCESS_TOKEN"
//      e.g. "B33A...::oauth.bundle"   (Phase 2)
//
//  Nothing in this file logs secret content. Use `MCPRedaction` if you need to
//  log around it.
//

import Foundation
import os

private let logger = DGLogger(category: "MCPSecretStore")

/// Stable scopes for keys we store under a given source. Avoids stringly-typed
/// keys at call sites and gives a single place to enumerate everything we own
/// in Keychain for an MCP source.
enum MCPSecretScope: Hashable {

    /// Bearer token for the simple `Authorization: Bearer <token>` scheme.
    case bearerToken

    /// API key for the `<headerName>: <value>` scheme.
    case apiKeyHeaderValue

    /// One env-var value, scoped by the env key name.
    case envValue(key: String)

    /// JSON bundle containing the full OAuth credential set
    /// (access_token, refresh_token, expires_at, scopes, registered client
    /// metadata). Reserved for Phase 2; declared here so the namespace is
    /// stable from the start.
    case oauthBundle

    /// Stable wire format used as the Keychain account suffix.
    var rawScope: String {
        switch self {
        case .bearerToken:           return "auth.bearer"
        case .apiKeyHeaderValue:     return "auth.headerValue"
        case .envValue(let key):     return "env.\(key)"
        case .oauthBundle:           return "oauth.bundle"
        }
    }
}

/// Per-source secret storage backed by the system Keychain.
@MainActor
final class MCPSecretStore {

    static let shared = MCPSecretStore()

    /// Single Keychain service entry for all MCP secrets. Per-source
    /// disambiguation lives in the account name.
    private static let service = "com.devgentic.mcp.secrets"

    private let backing = SecureKeyStorage()

    private init() {}

    // MARK: - Public API

    /// Stores a secret value under `(sourceID, scope)`. Overwrites any existing
    /// value at the same key. Empty strings delete instead of writing — callers
    /// often hand us "" for un-set fields and we don't want to leave stale
    /// Keychain entries behind.
    @discardableResult
    func store(_ value: String, for scope: MCPSecretScope, sourceID: UUID) -> Bool {
        let account = Self.account(sourceID: sourceID, scope: scope)
        if value.isEmpty {
            return delete(scope: scope, sourceID: sourceID)
        }
        let status = backing.save(value: value, service: Self.service, account: account)
        if status != errSecSuccess {
            logger.error("Failed to store \(scope.rawScope) for \(sourceID.uuidString): status=\(status)")
            return false
        }
        return true
    }

    /// Reads a secret. Returns nil if absent or on Keychain error — the call
    /// site is expected to treat absent as "no secret configured."
    func retrieve(_ scope: MCPSecretScope, sourceID: UUID) -> String? {
        let account = Self.account(sourceID: sourceID, scope: scope)
        return backing.retrieve(service: Self.service, account: account)
    }

    /// Deletes one secret. Returns `true` if removed or already absent.
    @discardableResult
    func delete(scope: MCPSecretScope, sourceID: UUID) -> Bool {
        let account = Self.account(sourceID: sourceID, scope: scope)
        let status = backing.delete(service: Self.service, account: account)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Best-effort wipe of every secret tied to a source. Called when the user
    /// deletes the server from the Tool Library. Iterates the scopes we know
    /// about (bearer, api-key, oauth) and any env keys the caller hands us.
    /// We can't enumerate Keychain by prefix without an additional attribute,
    /// so callers must pass the env-key set they remember.
    @discardableResult
    func purgeAll(sourceID: UUID, knownEnvKeys: Set<String> = []) -> Bool {
        var failed: [String] = []

        func purge(_ scope: MCPSecretScope) {
            if !delete(scope: scope, sourceID: sourceID) {
                failed.append(scope.rawScope)
            }
        }

        purge(.bearerToken)
        purge(.apiKeyHeaderValue)
        purge(.oauthBundle)
        for envKey in knownEnvKeys {
            purge(.envValue(key: envKey))
        }

        // Every `delete` result used to be discarded and this logged unconditional
        // success. A Keychain failure therefore left the secret on disk for a server the
        // user had deleted, while the log said it was purged — the one place that must
        // not lie, since it is the record that a credential was destroyed.
        guard failed.isEmpty else {
            logger.error("""
                [MCP-SECRETS] ⚠️ Purge INCOMPLETE for source \(sourceID.uuidString): \
                \(failed.count) item(s) could not be deleted from Keychain \
                (\(failed.sorted().joined(separator: ", "))). Those credentials REMAIN on this \
                machine for a server the user has removed, and nothing will retry — they must \
                be deleted manually from Keychain Access.
                """)
            return false
        }

        logger.info("[MCP-SECRETS] Purged all secrets for source \(sourceID.uuidString) (\(knownEnvKeys.count) env key(s)).")
        return true
    }

    // MARK: - Private

    private static func account(sourceID: UUID, scope: MCPSecretScope) -> String {
        "\(sourceID.uuidString)::\(scope.rawScope)"
    }
}
