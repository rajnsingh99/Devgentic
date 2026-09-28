// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPOAuthCredentialBundle.swift
//  Devgentic
//
//  The single Codable artifact persisted to Keychain at
//  `MCPSecretScope.oauthBundle` for any OAuth-configured MCP source.
//
//  Carries everything we need to:
//   - attach `Authorization: Bearer <access_token>` on outgoing MCP calls
//   - know when the access token is about to expire and trigger a refresh
//   - perform the refresh against the right token endpoint
//   - re-run a full auth dance if the registration is revoked
//
//  Stored as a JSON-encoded blob inside a single Keychain item so we never
//  fragment OAuth state across multiple Keychain entries (atomic update).
//

import Foundation

struct MCPOAuthCredentialBundle: Codable, Hashable, Sendable {

    /// Issuer URL the tokens belong to. Pinned so we can detect later
    /// "issuer rotated" errors and force a re-auth instead of silently
    /// accepting tokens from an unexpected AS.
    let issuer: URL

    /// `client_id` returned by RFC 7591 dynamic client registration. Used
    /// on every refresh request.
    let clientId: String

    /// Set of scopes that were granted (may be a subset of what we asked for).
    ///
    /// `var` because a refresh can return a different set. It used to be `let`, which forced
    /// `MCPOAuthCoordinator.refresh` to REBUILD the whole bundle whenever the scopes moved —
    /// and a rebuild is a full re-listing of every field, so the one that was forgotten
    /// (`resource`, the RFC 8707 audience binding) silently vanished. Mutating the fields
    /// that actually change removes that failure mode rather than patching it.
    var grantedScopes: [String]

    /// Loopback (or custom-scheme) redirect URI used for this client. Stored
    /// because it has to match exactly on every authorize and refresh call.
    let redirectURI: URL

    /// REQUIRED. Bearer token attached to MCP requests.
    var accessToken: String

    /// OPTIONAL. Some servers don't issue refresh tokens (or only on first
    /// auth). When nil, expiry triggers a full re-auth instead of refresh.
    var refreshToken: String?

    /// REQUIRED. Wall-clock time when the access token expires. The token
    /// endpoint returns `expires_in` (seconds-from-now); we compute and
    /// store an absolute Date so we don't have to remember when the response
    /// came in.
    var accessTokenExpiresAt: Date

    /// OPTIONAL. RFC 7592 registration-management credentials. Stashed so a
    /// later "remove server" can revoke the registration if the server
    /// supports it.
    let registrationAccessToken: String?
    let registrationClientUri: URL?

    /// OPTIONAL (RFC 8707). The MCP server URL these tokens were bound to.
    ///
    /// Stored so REFRESH can repeat the same `resource` value — omitting it there would
    /// let a refreshed token silently widen back to a general-purpose audience, undoing
    /// the binding established at authorization time. Optional so bundles persisted
    /// before 2026-08-01 keep decoding (they simply carry no audience binding).
    var resource: URL? = nil

    /// OPTIONAL. The MCP server URL the sign-in was performed FOR — the local binding check.
    /// Register KC-14.
    ///
    /// ⚠️ Distinct from `resource`, and deliberately so. `resource` is the protocol-level
    /// audience we ASKED the authorization server to bind the token to; whether the AS honours
    /// RFC 8707 is its business. `serverURL` is OUR record of which server entry the sign-in
    /// targeted, and `MCPOAuthBinding` enforces it locally: a bundle is attached only to the
    /// URL it was issued for, so editing a server's URL can never replay another host's token.
    /// Optional so bundles persisted before 2026-09-27 keep decoding (they carry no local
    /// binding; `MCPOAuthBinding` then fails closed at the EDIT gate and fails open at
    /// ATTACH — the asymmetry is documented there).
    var serverURL: URL? = nil

    /// True when the access token is past expiry (or within a 30-second
    /// safety margin to absorb clock skew + network round-trip).
    func isAccessTokenExpired(now: Date = Date(), safetyMargin: TimeInterval = 30) -> Bool {
        return accessTokenExpiresAt <= now.addingTimeInterval(safetyMargin)
    }

    /// True when the access token is *near* expiry — used by the proactive
    /// refresh-on-launch path. Default 5 minutes matches the design spec.
    func isAccessTokenNearExpiry(now: Date = Date(), within: TimeInterval = 300) -> Bool {
        return accessTokenExpiresAt <= now.addingTimeInterval(within)
    }
}

/// The local enforcement of the KC-14 binding invariant: **an OAuth credential bundle is
/// attached only to the MCP server URL it was issued for.** All three enforcement points call
/// THESE functions, never their own URL comparison, so the rule cannot drift apart:
///
/// - `shouldAttach` — the runtime attach point (`MCPRuntimeSecrets.materialize`): a misbound or
///   unparseable target refuses to attach the token. Fails OPEN for legacy bundles (no
///   `serverURL`), which is compatibility with every bundle persisted before this register;
///   the EDIT gate below is what retires them.
/// - `isProvablyMisbound` — the persistence reconcile (`MCPToolStore.persistSecrets`): clears a
///   stored bundle ONLY on proof of misbinding. Everything that cannot be proven (a legacy
///   bundle, an undecodable blob, an unparseable URL) is KEPT — this is the same
///   never-destroy-what-you-cannot-read rule as `MCPSecretStore.clear`.
/// - `editDecision` — the form gate (`AddMCPServerView.saveAndDismiss`, add and edit alike):
///   a save whose effective bundle is not bound to the URL being saved is refused with a
///   re-auth request. This is the fail-closed point, and the only one a user can act on.
enum MCPOAuthBinding {

    /// Normalizes a URL to the key this invariant compares on: scheme and host
    /// case-insensitive, one trailing slash folded away, and an EXPLICIT port kept —
    /// `host:8080` and `host:9090` are different servers, and refusing to notice would
    /// let a token cross between services on one host. Path case is preserved — hosts are
    /// case-insensitive by RFC 3986 §3.2.2, paths are not. A nil port (the scheme default)
    /// and an explicitly written default port normalize differently; that asymmetry fails
    /// closed, which is the correct direction for a binding check.
    static func normalizedServerKey(_ url: URL) -> String {
        var path = url.path
        if path == "/" {
            path = ""
        } else if path.hasSuffix("/") {
            path.removeLast()
        }
        return (url.scheme.map { $0.lowercased() + "://" } ?? "")
            + (url.host.map { $0.lowercased() } ?? "")
            + (url.port.map { ":\($0)" } ?? "")
            + path
    }

    /// Whether `bundle`'s token may be attached to requests for `serverURLString`.
    /// `nil`/unparseable target with a BOUND bundle is a refusal — we cannot confirm the one
    /// thing this check exists to confirm. A LEGACY bundle (`serverURL == nil`) attaches:
    /// refusing it would break every pre-register server on first connect, and the edit gate
    /// is what requires those to re-auth the first time their URL actually changes.
    static func shouldAttach(_ bundle: MCPOAuthCredentialBundle, to serverURLString: String?) -> Bool {
        guard let bound = bundle.serverURL else { return true }
        guard let target = serverURLString.flatMap(URL.init(string:)) else { return false }
        return normalizedServerKey(bound) == normalizedServerKey(target)
    }

    /// Whether a stored bundle is PROVABLY bound to a different server than `serverURLString`.
    /// True only when the bundle decodes, carries a binding, the target parses, and the two
    /// normalized keys differ — every other outcome is `false` (keep the credential).
    static func isProvablyMisbound(storedJSON: String, serverURLString: String?) -> Bool {
        guard let data = storedJSON.data(using: .utf8),
              let stored = try? JSONDecoder().decode(MCPOAuthCredentialBundle.self, from: data),
              let bound = stored.serverURL,
              let target = serverURLString.flatMap(URL.init(string:)) else { return false }
        return normalizedServerKey(bound) != normalizedServerKey(target)
    }

    /// What a save should do about the OAuth binding. See `editDecision`.
    enum EditDecision: Equatable {
        case proceed
        case requiresReAuth(MCPUserError)
    }

    /// The form gate for BOTH add and edit. The invariant: the bundle that will be in effect
    /// after this save must be bound to `newURL`.
    ///
    /// - `freshBundle` non-nil means the user completed a sign-in in this form session; it wins
    ///   over anything stored and must itself be bound to `newURL` (the URL field may have been
    ///   edited AFTER the sign-in — that is a refusal, not a pass-through).
    /// - With no fresh sign-in, `storedRead` decides: `.notFound` proceeds (nothing stored, so
    ///   nothing can be replayed); `.failed` and undecodable JSON refuse (fail closed — we
    ///   cannot prove what the stored bundle is bound to); a decoded legacy bundle refuses when
    ///   the URL CHANGED and passes when it did not (a rename on a pre-register server must not
    ///   be refused over a binding it does not touch — the KC-1 lesson); a bound bundle passes
    ///   only when its key matches `newURL`.
    static func editDecision(
        isOAuth: Bool,
        newURL: String?,
        previousURL: String?,
        freshBundle: MCPOAuthCredentialBundle?,
        storedRead: KeychainReadOutcome
    ) -> EditDecision {
        guard isOAuth else { return .proceed }

        func refusal() -> EditDecision {
            .requiresReAuth(MCPUserError(
                title: "Sign in again for this URL",
                message: "The stored OAuth sign-in was made for a different server URL. Saving would send that server's token to the URL in this form.",
                suggestion: "Press Sign In again while this form holds the new URL — a fresh sign-in binds its tokens to what is in the field at the moment you sign in.",
                rawLog: nil
            ))
        }

        // nil = binding unknown (refuse on change); .some(nil) = legacy unbound;
        // .some(.some(url)) = bound.
        let effectiveBinding: URL??
        if let fresh = freshBundle {
            effectiveBinding = .some(fresh.serverURL)
        } else {
            switch storedRead {
            case .notFound:
                return .proceed
            case .failed:
                return refusal()
            case .found(let json):
                guard let data = json.data(using: .utf8),
                      let stored = try? JSONDecoder().decode(MCPOAuthCredentialBundle.self, from: data) else {
                    return refusal()
                }
                effectiveBinding = .some(stored.serverURL)
            }
        }

        guard let bound = effectiveBinding else { return refusal() }

        // A legacy (unbound) bundle may stay only while the URL is untouched — and "untouched"
        // must be provable. An unknown previous URL (undecodable blob) cannot prove it.
        guard let bound else {
            guard let previous = previousURL,
                  let new = newURL,
                  let previousURLValue = URL(string: previous),
                  let newURLValue = URL(string: new),
                  normalizedServerKey(previousURLValue) == normalizedServerKey(newURLValue) else {
                return refusal()
            }
            return .proceed
        }

        guard let new = newURL.flatMap(URL.init(string:)) else { return refusal() }
        return normalizedServerKey(bound) == normalizedServerKey(new) ? .proceed : refusal()
    }
}
