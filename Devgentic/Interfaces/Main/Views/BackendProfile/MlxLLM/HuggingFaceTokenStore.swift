// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  HuggingFaceTokenStore.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import Security
import os

private let logger = DGLogger(category: "HuggingFaceToken")

// Why: never log, export or send the token value to telemetry, only its presence and masked form; `TelemetrySanitizer`
// redacts `Bearer` headers, but the value must not reach a log line.
/// The user's HuggingFace access token, stored in the system Keychain. `@Observable` so the settings card re-renders
/// when the token changes.
@MainActor
@Observable
final class HuggingFaceTokenStore {

    @ObservationIgnored static let shared = HuggingFaceTokenStore()

    /// Single Keychain service entry, matching the MCP store's shape.
    private static let service = "com.devgentic.huggingface"
    private static let account = "access-token"

    /// Keychain backend, swappable for tests through `setBackingForTesting`; production never reassigns it. Mirrors
    /// `MCPSecretStore.setBackingForTesting`.
    private var backing: KeychainAccessing = SecureKeyStorage()

    /// Swaps the Keychain backend. Test-only; pass nil to restore the real one. Callers must also
    /// `refreshFromKeychain()`, or the cache from the previous backend survives.
    static func setBackingForTesting(_ replacement: KeychainAccessing?) {
        shared.backing = replacement ?? SecureKeyStorage()
        shared.refreshFromKeychain()
    }

    // Why: a failed read is never cached (it stays nil so the next access retries); `@ObservationIgnored` keeps the token
    // value out of view dependencies.
    /// Cached so the download path does not hit the Keychain on every request; nil means not yet read, `.some(nil)` means
    /// read and absent. Invalidated by `store`/`clear`.
    @ObservationIgnored private var cached: String??

    /// Whether the last attempt to read the token failed, as opposed to finding nothing, so the UI can tell "no token
    /// configured" from "could not look". Set only from `refreshFromKeychain`, never from the `token` getter, so no view
    /// body can mutate observable state.
    private(set) var readFailed: Bool = false

    /// Whether a token is configured. Safe to call from UI — no value is exposed, and this is
    /// the property views observe, so `store`/`clear` re-render them.
    private(set) var hasToken: Bool = false

    private init() {
        // One Keychain read at construction so `hasToken` is right before any view reads it. Tests never construct this.
        refreshFromKeychain()
    }

    // MARK: - Public API

    /// The stored token, or nil when absent or unreadable. Callers that only need a value to send may use this; anything
    /// deciding whether a token is configured should read `hasToken` alongside `readFailed`.
    var token: String? {
        if let cached { return cached }
        switch backing.read(service: Self.service, account: Self.account) {
        case .found(let value):
            cached = .some(value)
            return value
        case .notFound:
            cached = .some(nil)
            return nil
        case .failed(let status):
            // Do not cache the failure: leaving the cache nil means the next access retries (see `cached`), so a transient lock
            // costs one request, not the session.
            logger.error(
                "[MLXSTORE] Could not read the HuggingFace token from the Keychain (status \(status)) "
                + "— this is NOT the same as no token being configured. CONSEQUENCE: this request "
                + "runs anonymously, so gated repos 401 and rate limits drop to the anonymous tier; "
                + "the token is NOT lost and the next attempt re-reads it."
            )
            return nil
        }
    }

    /// A display form that reveals enough to recognise the token without exposing it.
    /// HuggingFace tokens are `hf_` followed by ~34 characters.
    var maskedToken: String? {
        guard let token, token.count > 8 else { return token.map { _ in "••••" } }
        return "\(token.prefix(6))…\(token.suffix(4))"
    }

    /// Saves the user's token. An empty string clears it rather than storing a blank, so the
    /// field's "clear it out and save" gesture does what it looks like.
    @discardableResult
    func store(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return clear() }

        let status = backing.save(value: trimmed, service: Self.service, account: Self.account)
        guard status == errSecSuccess else {
            logger.error("[MLXSTORE] Failed to save the HuggingFace token to the Keychain (status \(status)). CONSEQUENCE: gated and private repos stay unreachable and rate limits stay at the anonymous tier.")
            return false
        }
        cached = .some(trimmed)
        hasToken = true
        logger.notice("[MLXSTORE] HuggingFace token saved. Gated repos are now reachable and requests use the authenticated rate limit.")
        return true
    }

    @discardableResult
    func clear() -> Bool {
        let status = backing.delete(service: Self.service, account: Self.account)

        // State is updated from the delete result, not before it: a failed delete must not paint the card as "no token"
        // while the token is still sent. `errSecItemNotFound` means there was nothing to remove, which satisfies the intent.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error(
                "[MLXSTORE] Failed to remove the HuggingFace token from the Keychain (status \(status)). "
                + "CONSEQUENCE: the token is STILL PRESENT and still sent on every HuggingFace "
                + "request — it has not been revoked. The card continues to show a token so the "
                + "user is not told it is gone when it is not."
            )
            // Re-derive rather than assume: the delete failed, so whatever is in the Keychain now
            // is the truth, and this session's cache must not claim otherwise.
            refreshFromKeychain()
            return false
        }

        cached = .some(nil)
        hasToken = false
        readFailed = false
        logger.notice("[MLXSTORE] HuggingFace token removed.")
        return true
    }

    /// Drops the in-memory copy so the next read hits the Keychain, and re-derives the observable state from what is
    /// there. The only place `hasToken` and `readFailed` are derived from a read; called from `init`, a failed `clear`,
    /// and the settings card when it appears.
    func refreshFromKeychain() {
        cached = nil
        switch backing.read(service: Self.service, account: Self.account) {
        case .found(let value):
            cached = .some(value)
            hasToken = true
            readFailed = false
        case .notFound:
            cached = .some(nil)
            hasToken = false
            readFailed = false
        case .failed:
            // Leave `cached` nil so the next `token` access retries. `token`'s getter logs the
            // OSStatus and its consequence.
            hasToken = false
            readFailed = true
        }
    }

    // MARK: - Validation

    /// Whether a string looks like a HuggingFace access token. A shape check, not a verdict: token formats vary, so the
    /// UI warns but does not block.
    nonisolated static func looksLikeToken(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("hf_") && trimmed.count >= 20
    }
}
