// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPOAuthMetadata.swift
//  Devgentic
//
//  RFC 8414 (OAuth 2.0 Authorization Server Metadata) — the subset of fields
//  we need for the desktop OAuth flow. Fetched from
//  `<issuer>/.well-known/oauth-authorization-server` (or `/.well-known/openid-configuration`
//  for OIDC servers, which is a strict superset).
//
//  Unrecognized fields are tolerated by JSONDecoder; we only model what we use.
//

import Foundation

struct MCPOAuthMetadata: Codable, Hashable, Sendable {

    /// REQUIRED. The authorization-server issuer identifier — must match the
    /// URL used to fetch this document (path-prefix check). We keep it for
    /// later inclusion in the credential bundle so audits can trace which
    /// issuer minted a given access token.
    let issuer: URL

    /// REQUIRED for the authorization-code flow. The user-facing endpoint
    /// where we open the system browser to begin auth.
    let authorizationEndpoint: URL

    /// REQUIRED for code exchange. POST target for `authorization_code` and
    /// `refresh_token` grants.
    let tokenEndpoint: URL

    /// OPTIONAL (RFC 7591). When present, we can dynamically register a
    /// client without a pre-shared `client_id`. When absent, the server
    /// expects a manually-provisioned client and we have to fail discovery
    /// with a clear "needs preregistered client" error.
    let registrationEndpoint: URL?

    /// OPTIONAL. List of OAuth scopes the server supports. Used to compose
    /// the `scope` param on the authorize request.
    let scopesSupported: [String]?

    /// OPTIONAL. Code-challenge methods supported by the AS. We require
    /// `"S256"`; servers that only advertise `"plain"` (or don't advertise
    /// PKCE at all) are rejected — we don't ship `plain`.
    let codeChallengeMethodsSupported: [String]?

    /// OPTIONAL. Grant types supported. We need `authorization_code` and
    /// (strongly recommended) `refresh_token`.
    let grantTypesSupported: [String]?

    /// OPTIONAL. Auth methods supported at the token endpoint. We use
    /// `"none"` (public-client + PKCE). If the server only allows
    /// `"client_secret_basic"` we can't auth — we'd need a confidential
    /// client which doesn't fit a desktop app.
    let tokenEndpointAuthMethodsSupported: [String]?

    /// OPTIONAL (RFC 7009). Where to POST a token to revoke it. Used on server
    /// removal so a deleted server's tokens stop being valid rather than merely
    /// being forgotten locally.
    let revocationEndpoint: URL?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint        = "authorization_endpoint"
        case tokenEndpoint                = "token_endpoint"
        case registrationEndpoint         = "registration_endpoint"
        case scopesSupported              = "scopes_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case grantTypesSupported          = "grant_types_supported"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
        case revocationEndpoint           = "revocation_endpoint"
    }
}

extension MCPOAuthMetadata {

    /// True when the server advertises everything we need:
    /// - authorization-code grant
    /// - PKCE S256 method (must be advertised EXPLICITLY — see below)
    /// - public-client token-endpoint auth (`"none"`) or omits the field entirely
    ///
    /// The omission rules are NOT uniform across these fields, which is what the
    /// previous `?? true` on all three got wrong:
    ///
    /// - `grant_types_supported` — RFC 8414: omitted means `["authorization_code",
    ///   "implicit"]`, so treating omission as support is correct.
    /// - `token_endpoint_auth_methods_supported` — omitted means `client_secret_basic`.
    ///   Strictly that excludes us, but ASes that accept public clients commonly omit
    ///   the field, and guessing wrong here costs only a clear failure at the token
    ///   endpoint — no credential is exposed. Left permissive on purpose.
    /// - `code_challenge_methods_supported` — RFC 8414 is explicit that **omitted means
    ///   the server does NOT support PKCE**. `?? true` inverted that, so an AS with no
    ///   PKCE at all was accepted as PKCE-capable: we would send a `code_challenge` the
    ///   server ignores and then exchange the code with no proof of possession, which is
    ///   exactly the interception attack PKCE exists to prevent. This one is now strict.
    var supportsDesktopPKCEFlow: Bool {
        let grantsOK = grantTypesSupported?.contains("authorization_code") ?? true
        let pkceOK = codeChallengeMethodsSupported?.contains("S256") ?? false
        let authOK = tokenEndpointAuthMethodsSupported?.contains("none") ?? true
        return grantsOK && pkceOK && authOK
    }
}
