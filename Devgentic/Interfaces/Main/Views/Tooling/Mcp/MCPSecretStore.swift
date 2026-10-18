// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPSecretStore.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    /// JSON bundle of the full OAuth credential set (access_token, refresh_token, expires_at, scopes, client metadata).
    /// Declared so the namespace is stable; not yet written by anything.
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

/// What a guarded clear actually did. `refusedUnreadable` is deliberately not an error: refusing to delete a credential
/// that could not be read is the correct outcome, and the caller should carry on.
enum MCPSecretClearOutcome: Equatable {

    /// The item is gone — we deleted it, or it was already absent.
    case cleared

    /// The current value could not be READ, so we did not delete it. The secret is intact.
    case refusedUnreadable(OSStatus)

    /// The delete itself failed. The secret may still be present.
    case failed(OSStatus)

    /// Whether this outcome is a genuine failure; `refusedUnreadable` is not one.
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Per-source secret storage backed by the system Keychain.
@MainActor
final class MCPSecretStore {

    static let shared = MCPSecretStore()

    /// Single Keychain service entry for all MCP secrets. Per-source
    /// disambiguation lives in the account name.
    private static let service = "com.devgentic.mcp.secrets"

    /// Test seam for the Keychain backing, so the `.failed` read branch of `clear` can be exercised.
    /// Mirrors `ProviderKeyStore.setStorageForTesting`; production never reassigns it.
    private var backing: KeychainAccessing = SecureKeyStorage()

    /// Swaps the Keychain backend. Test-only — pass nil to restore the real one.
    static func setBackingForTesting(_ replacement: KeychainAccessing?) {
        shared.backing = replacement ?? SecureKeyStorage()
    }

    /// Test seam: when set, receives exactly the failure line `delete` logs, so the sink and the logger share one message.
    nonisolated(unsafe) static var deleteFailureLogSinkForTesting: (@Sendable (String) -> Void)?

    private init() {}

    // MARK: - Public API

    /// Stores a secret value under `(sourceID, scope)`, overwriting any existing value.
    /// An empty string clears via `clear`, not `delete`, so it cannot destroy a credential that merely could not be read.
    @discardableResult
    func store(_ value: String, for scope: MCPSecretScope, sourceID: UUID) -> Bool {
        let account = Self.account(sourceID: sourceID, scope: scope)
        if value.isEmpty {
            return !clear(scope: scope, sourceID: sourceID).isFailure
        }
        let status = backing.save(value: value, service: Self.service, account: account)
        if status != errSecSuccess {
            logger.error("[MCP-SECRETS] Could not store \(scope.rawScope) for source "
                + "\(sourceID.uuidString) (\(SecureKeyStorage.osStatusName(status))). CONSEQUENCE: "
                + "the secret is stored NOWHERE — the caller must treat this as a failure, and the "
                + "server will start without the credential.")
            return false
        }
        return true
    }

    // Why: a locked Keychain collapsed to "" would let Save delete a live bearer token the user never touched
    /// Reads a secret, distinguishing "nothing stored" from "the read failed".
    /// Anything that writes or deletes based on the answer must use this, never `retrieve`.
    func read(_ scope: MCPSecretScope, sourceID: UUID) -> KeychainReadOutcome {
        let account = Self.account(sourceID: sourceID, scope: scope)
        let outcome = backing.read(service: Self.service, account: account)
        if case .failed(let status) = outcome {
            logger.error(
                "[MCP-SECRETS] Could not read \(scope.rawScope) for source \(sourceID.uuidString) "
                + "(OSStatus \(status)) — this is NOT the same as the secret being absent. "
                + "CONSEQUENCE: callers must not overwrite or delete it; the server will behave as "
                + "unauthenticated until the Keychain is readable again (typically: unlock it, or "
                + "re-grant access after an update changed the app's code signature)."
            )
        }
        return outcome
    }

    /// Reads a secret; nil if absent or on a Keychain error (deliberately indistinguishable).
    /// Only for callers that need a value to send; if the answer drives a write, use `read`.
    func retrieve(_ scope: MCPSecretScope, sourceID: UUID) -> String? {
        guard case .found(let value) = read(scope, sourceID: sourceID) else { return nil }
        return value
    }

    // Why: a read can fail while a secret exists (locked keychain, denied ACL); deleting then loses the only copy
    /// Removes a secret only if it could be read first; an unreadable secret is kept and reported as `refusedUnreadable`.
    /// A genuine `.notFound` counts as `cleared`, since the desired end state is "gone".
    @discardableResult
    func clear(scope: MCPSecretScope, sourceID: UUID) -> MCPSecretClearOutcome {
        switch read(scope, sourceID: sourceID) {
        case .failed(let status):
            // `read` has already logged the OSStatus and its consequence.
            logger.error(
                "[MCP-SECRETS] REFUSING to clear \(scope.rawScope) for source \(sourceID.uuidString): "
                + "its current value could not be read (OSStatus \(status)), so deleting it now could "
                + "destroy a credential that is perfectly intact. CONSEQUENCE: the secret is LEFT IN "
                + "PLACE and this save did not change it. If you meant to remove it, do so again once "
                + "the Keychain is readable."
            )
            return .refusedUnreadable(status)

        case .notFound:
            return .cleared

        case .found:
            let status = backing.delete(service: Self.service, account: Self.account(sourceID: sourceID, scope: scope))
            guard status == errSecSuccess || status == errSecItemNotFound else {
                logger.error(
                    "[MCP-SECRETS] Failed to delete \(scope.rawScope) for source "
                    + "\(sourceID.uuidString) (OSStatus \(status)). CONSEQUENCE: the credential is "
                    + "still on this machine even though the configuration no longer references it."
                )
                return .failed(status)
            }
            return .cleared
        }
    }

    /// Deletes one secret unconditionally; returns `true` if removed or already absent.
    /// Prefer `clear`: this skips the readability check, so use it only when a whole source is going away.
    @discardableResult
    func delete(scope: MCPSecretScope, sourceID: UUID) -> Bool {
        let account = Self.account(sourceID: sourceID, scope: scope)
        let status = backing.delete(service: Self.service, account: account)
        // `errSecItemNotFound` is success for a wipe; anything else means the secret remains and must be visible,
        // since most callers discard the returned Bool.
        if status != errSecSuccess && status != errSecItemNotFound {
            let message = "[MCP-SECRETS] Could not delete \(scope.rawScope) for source "
                + "\(sourceID.uuidString) (\(SecureKeyStorage.osStatusName(status))). CONSEQUENCE: "
                + "the secret REMAINS in the Keychain with no owning record — if this was a "
                + "server removal, the credential survives it."
            if let sink = Self.deleteFailureLogSinkForTesting {
                sink(message)
            } else {
                logger.error(message)
            }
        }
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Best-effort wipe of every secret tied to a source, called when the server is deleted from the Tool Library.
    /// Iterates the known scopes plus `knownEnvKeys`; the Keychain cannot be enumerated by prefix, so callers pass them.
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

        // Logs the failures of every `delete` rather than unconditional success, since this log is the record that a
        // credential was destroyed.
        guard failed.isEmpty else {
            logger.error("""
                [MCP-SECRETS] ⚠️ Purge INCOMPLETE for source \(sourceID.uuidString): \
                \(failed.count) item(s) could not be deleted from Keychain \
                (\(failed.sorted().joined(separator: ", "))). Those credentials REMAIN on this \
                machine for a server the user has removed, and nothing will retry — they must \
                be deleted manually: search Keychain Access for "\(sourceID.uuidString)" (every \
                item this app writes is labelled "Devgentic — <service> — <account>").
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
