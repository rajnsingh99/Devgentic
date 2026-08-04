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

    private let backing = SecureKeyStorage()

    /// Cached so the download path doesn't hit the Keychain on every request. Invalidated by
    /// `store`/`clear`; nil means "not yet read", `.some(nil)` means "read, and absent".
    ///
    /// ⚠️ `@ObservationIgnored` on purpose, for two reasons. The token VALUE must never enter a
    /// view's dependency graph, and `token`'s getter WRITES this cache on a miss — an observed
    /// mutation during a view body evaluation is the "Modifying state during view update"
    /// class of bug. `hasToken` below is the observable surface instead.
    @ObservationIgnored private var cached: String??

    /// Whether a token is configured. Safe to call from UI — no value is exposed, and this is
    /// the property views observe, so `store`/`clear` re-render them.
    private(set) var hasToken: Bool = false

    private init() {
        // One Keychain read at construction so `hasToken` is right before any view reads it.
        // Cheap, and `.shared` is only reached from surfaces that were going to need the token
        // anyway. Tests never construct this — they exercise the static shape helpers only.
        hasToken = token != nil
    }

    // MARK: - Public API

    /// The stored token, or nil.
    var token: String? {
        if let cached { return cached }
        let value = backing.retrieve(service: Self.service, account: Self.account)
        cached = .some(value)
        return value
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
        cached = .some(nil)
        hasToken = false
        // `errSecItemNotFound` means there was nothing to remove — the caller's intent is
        // satisfied either way.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("[MLXSTORE] Failed to remove the HuggingFace token from the Keychain (status \(status)). CONSEQUENCE: the token may still be present and in use.")
            return false
        }
        logger.notice("[MLXSTORE] HuggingFace token removed.")
        return true
    }

    /// Drops the in-memory copy, forcing the next read to hit the Keychain. For tests and for
    /// recovering if the item is changed by another process.
    func invalidateCache() {
        cached = nil
        hasToken = token != nil
    }

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
