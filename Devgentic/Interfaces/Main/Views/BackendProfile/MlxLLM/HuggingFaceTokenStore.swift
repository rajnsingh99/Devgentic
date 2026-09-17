// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  HuggingFaceTokenStore.swift
//  Devgentic
//
//  Created 2026-08-03 for G4.
//
//  `HubApi` was constructed without an `hfToken:`, so it fell back to `hfTokenFromEnv()` —
//  which reads `HF_TOKEN` / `HUGGING_FACE_HUB_TOKEN` from `ProcessInfo.environment`.
//
//  ⚠️ A macOS .app launched from Finder, Spotlight or Sparkle does NOT inherit the user's shell
//  environment, so that lookup is always nil in the shipped product no matter what the user has
//  in their `.zshrc`. Gated repos therefore failed with "Please provide a valid Hugging Face
//  token" — an instruction the app gave no way to follow.
//
//  Mirrors `MCPSecretStore`: one Keychain service, `SecureKeyStorage` underneath.
//

import Foundation
import Security
import os

private let logger = DGLogger(category: "HuggingFaceToken")

/// The user's HuggingFace access token, stored in the system Keychain.
///
/// ⚠️ Never log, export or telemetry the token value itself — only whether one is present and
/// its masked form. `TelemetrySanitizer` redacts `Bearer` headers, but the value must not reach
/// a log line in the first place.
/// ⚠️ `@Observable` so the settings card re-renders when the token changes. Without it,
/// "Remove" updated the Keychain but nothing on screen: `hasToken` is derived from a plain
/// stored property, and the two `@State` writes beside the call are no-ops on the
/// post-relaunch path (the draft is already empty and `tokenSaved` already false), so the card
/// went on showing "Token saved" and the masked value for a token that no longer existed.
@MainActor
@Observable
final class HuggingFaceTokenStore {

    @ObservationIgnored static let shared = HuggingFaceTokenStore()

    /// Single Keychain service entry, matching the MCP store's shape.
    private static let service = "com.devgentic.huggingface"
    private static let account = "access-token"

    /// ⚠️ TEST SEAM (register KC-8). This was `private let backing = SecureKeyStorage()`, so the
    /// `.failed` branch — the only branch this store's cache policy is about — could not be reached
    /// from a test at all. A first attempt at covering KC-8 exercised a `KeychainAccessing` stub
    /// directly instead, and MUTATION-CHECKING PROVED IT VACUOUS: re-introducing the cache
    /// poisoning left it green, because it never touched this type. Mirrors
    /// `MCPSecretStore.setBackingForTesting`; production never reassigns it.
    private var backing: KeychainAccessing = SecureKeyStorage()

    /// Swaps the Keychain backend. Test-only — pass nil to restore the real one.
    /// ⚠️ Callers must also `refreshFromKeychain()`, or the cache from the previous backend survives.
    static func setBackingForTesting(_ replacement: KeychainAccessing?) {
        shared.backing = replacement ?? SecureKeyStorage()
        shared.refreshFromKeychain()
    }

    /// Cached so the download path doesn't hit the Keychain on every request. Invalidated by
    /// `store`/`clear`; nil means "not yet read", `.some(nil)` means "read, and genuinely ABSENT".
    ///
    /// ⚠️⚠️ A FAILED READ IS NEVER CACHED — register KC-8. There are three states, not two, and
    /// this property can only represent two of them. The getter used to write `.some(nil)` for a
    /// read that FAILED, which made "the Keychain was locked for a moment at launch" indistinguish‐
    /// able from "the user has no token" **for the entire process lifetime**: `if let cached`
    /// short-circuits every later read, `invalidateCache()` had zero production callers, and the
    /// only recovery was to quit the app. Gated repos 401'd against a token sitting intact in the
    /// Keychain. So on `.failed` we leave this nil and let the next access retry.
    ///
    /// ⚠️ `@ObservationIgnored` on purpose, for two reasons. The token VALUE must never enter a
    /// view's dependency graph, and `token`'s getter WRITES this cache on a miss — an observed
    /// mutation during a view body evaluation is the "Modifying state during view update"
    /// class of bug. `hasToken` below is the observable surface instead.
    @ObservationIgnored private var cached: String??

    /// Whether the last attempt to read the token FAILED, as opposed to finding nothing.
    ///
    /// ⚠️ Drives the UI's ability to tell "no token configured" from "I could not look". Without
    /// it the settings card shows an identical empty state for both, and the user re-pastes a token
    /// they never lost. Set only from `refreshFromKeychain`, never from the `token` getter, so no
    /// view-body evaluation can mutate observable state.
    private(set) var readFailed: Bool = false

    /// Whether a token is configured. Safe to call from UI — no value is exposed, and this is
    /// the property views observe, so `store`/`clear` re-render them.
    private(set) var hasToken: Bool = false

    private init() {
        // One Keychain read at construction so `hasToken` is right before any view reads it.
        // Cheap, and `.shared` is only reached from surfaces that were going to need the token
        // anyway. Tests never construct this — they exercise the static shape helpers only.
        refreshFromKeychain()
    }

    // MARK: - Public API

    /// The stored token, or nil when absent **or unreadable**.
    ///
    /// ⚠️ Callers that merely need a value to SEND may use this. Anything deciding whether the user
    /// has configured a token should read `hasToken` alongside `readFailed` — nil here means both
    /// "none" and "could not look", and those must not render the same.
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
            // ⚠️ DO NOT CACHE. Register KC-8 — see `cached`. Leaving it nil means the very next
            // access retries, so a transient lock or a dismissed ACL prompt costs one request
            // rather than the whole session.
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

        // ⚠️ STATE IS UPDATED FROM THE RESULT, NOT BEFORE IT — register KC-20. This used to set
        // `cached = .some(nil)` and `hasToken = false` on the line BEFORE the status check, so a
        // delete that failed still painted the card as "no token": the user pressed Remove to
        // revoke a token, was told it was gone, and it was still in the Keychain and still being
        // sent on every request. The `guard` below returned `false` to say so and both callers
        // discarded it.
        //
        // `errSecItemNotFound` means there was nothing to remove — the caller's intent is
        // satisfied either way.
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

    /// Drops the in-memory copy, forcing the next read to hit the Keychain, and re-derives the
    /// observable state from what is actually there.
    ///
    /// ⚠️ This is the ONLY place `hasToken` and `readFailed` are derived from a read, deliberately:
    /// the `token` getter must not mutate observable state (it can be reached from a view body).
    /// It had **zero production callers** before register KC-8 — which is precisely why a failed
    /// read at launch was unrecoverable for the life of the process. It is now called from `init`,
    /// from a failed `clear`, and from the settings card when it appears.
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

    /// Legacy spelling of `refreshFromKeychain`, kept so existing call sites keep compiling.
    func invalidateCache() { refreshFromKeychain() }

    // MARK: - Validation

    /// Whether a string looks like a HuggingFace access token.
    ///
    /// Deliberately a *shape* check, not a verdict: HuggingFace has shipped more than one token
    /// format, and refusing to store something valid because it doesn't match a guess would be
    /// worse than letting the request fail with a clear 401. The UI warns, it does not block.
    nonisolated static func looksLikeToken(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("hf_") && trimmed.count >= 20
    }
}
