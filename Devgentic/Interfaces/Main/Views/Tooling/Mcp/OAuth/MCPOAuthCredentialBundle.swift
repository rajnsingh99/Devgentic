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
