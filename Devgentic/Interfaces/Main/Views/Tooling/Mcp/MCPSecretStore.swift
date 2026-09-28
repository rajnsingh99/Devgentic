// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

/// What a guarded clear actually did. Register KC-1.
///
/// ⚠️ `refusedUnreadable` is the case that exists to prevent data loss, and it is deliberately NOT
/// an error: refusing to delete a credential we could not read is the CORRECT outcome, and the
/// caller should carry on. Treating it as a failure would push callers back into the behaviour the
/// case exists to stop.
enum MCPSecretClearOutcome: Equatable {

    /// The item is gone — we deleted it, or it was already absent.
    case cleared

    /// The current value could not be READ, so we did not delete it. The secret is intact.
    case refusedUnreadable(OSStatus)

    /// The delete itself failed. The secret may still be present.
    case failed(OSStatus)

    /// Whether this outcome represents a genuine failure. ⚠️ `refusedUnreadable` is NOT one.
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

    /// ⚠️ TEST SEAM (register KC-1). This was `private let backing = SecureKeyStorage()`, which meant
    /// the `.failed` branch — the ONLY branch that matters here, since `clear`'s whole job is to
    /// refuse on an unreadable read — could not be exercised at all. The guarantee was asserted by
    /// comment alone, which is how it went unnoticed that `MCPSecretStore` had no `read` to begin
    /// with. Mirrors `ProviderKeyStore.setStorageForTesting`; production never reassigns it.
    private var backing: KeychainAccessing = SecureKeyStorage()

    /// Swaps the Keychain backend. Test-only — pass nil to restore the real one.
    static func setBackingForTesting(_ replacement: KeychainAccessing?) {
        shared.backing = replacement ?? SecureKeyStorage()
    }

    /// ⚠️ TEST SEAM (register KC-52). When set, receives exactly the failure line `delete` logs —
    /// `delete` used to log NOTHING on failure and five of its six call sites discarded the Bool,
    /// so a refused wipe (a locked Keychain during server removal) was invisible everywhere. One
    /// message for the sink and the logger alike; the seam cannot drift from the log.
    nonisolated(unsafe) static var deleteFailureLogSinkForTesting: (@Sendable (String) -> Void)?

    private init() {}

    // MARK: - Public API

    /// Stores a secret value under `(sourceID, scope)`. Overwrites any existing
    /// value at the same key.
    ///
    /// ⚠️ An empty string CLEARS rather than writes — callers often hand us "" for an un-set
    /// field. That routes through `clear`, **not** `delete`, so an empty string can never destroy a
    /// credential that merely could not be READ. See `clear`; that distinction is the whole of
    /// register KC-1.
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

    /// Reads a secret, distinguishing "nothing stored" from "the read failed".
    ///
    /// ⚠️⚠️ **Anything that WRITES or DELETES based on the answer MUST use this, never `retrieve`.**
    /// This is `SecureKeyStorage`'s register-B2 rule, which this store did not honour and which cost
    /// us KC-1: `MCPSecretStore` exposed only the collapsing `retrieve`, so a locked Keychain or a
    /// denied ACL prompt rendered as `""` in the edit form, and pressing Save deleted a live bearer
    /// token the user had never touched. `ProviderKeyStore.read` is the same seam for provider keys.
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

    /// Reads a secret. Returns nil if absent **or on a Keychain error** — the two are deliberately
    /// indistinguishable here.
    ///
    /// ⚠️ Only for callers that merely need a value to SEND. If the answer drives a write, use
    /// `read` instead — see its comment.
    func retrieve(_ scope: MCPSecretScope, sourceID: UUID) -> String? {
        guard case .found(let value) = read(scope, sourceID: sourceID) else { return nil }
        return value
    }

    /// Removes a secret — but **only if we could read what we are removing**.
    ///
    /// ⚠️⚠️ THIS IS THE KC-1 FIX, AND THE ASYMMETRY IS DELIBERATE. A Keychain read can fail for
    /// reasons that have nothing to do with whether a secret exists: the login keychain is locked,
    /// or the per-item ACL prompt was denied after an update changed the app's code signature. The
    /// old path could not tell that apart from "no secret configured", so the edit form hydrated an
    /// empty field and Save deleted a live bearer token the user never touched — unrecoverably,
    /// since the Keychain was the only copy.
    ///
    /// So: losing a credential is permanent, failing to clear one is not. When the read fails we
    /// keep the secret and say so. The user can clear it again once the Keychain is readable.
    /// `BackendProfileSD.details` makes exactly this trade for provider keys (`suppressKeychainClear`).
    ///
    /// ⚠️ A genuine `.notFound` still counts as `cleared` — the desired end state is "gone", not
    /// "we did the deleting".
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

    /// Deletes one secret unconditionally. Returns `true` if removed or already absent.
    ///
    /// ⚠️ Prefer `clear`. This does NOT check whether the value was readable first, so it will
    /// happily destroy a credential during a Keychain outage. It is correct only where the intent
    /// is "this whole source is going away" — `purgeAll` on server deletion — and wrong anywhere a
    /// configuration is merely being re-saved.
    @discardableResult
    func delete(scope: MCPSecretScope, sourceID: UUID) -> Bool {
        let account = Self.account(sourceID: sourceID, scope: scope)
        let status = backing.delete(service: Self.service, account: account)
        // Register KC-52: `errSecItemNotFound` is success for a wipe (the goal is "nothing
        // stored"); anything else means the secret REMAINS, and that must be visible — five of
        // this function's callers discard the returned Bool.
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
