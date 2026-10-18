// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPOAuthMetadata.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The subset of RFC 8414 (OAuth 2.0 Authorization Server Metadata) fields needed for the desktop OAuth flow.
/// Fetched from `<issuer>/.well-known/oauth-authorization-server` (or `/.well-known/openid-configuration` for OIDC
/// servers); unrecognized fields are ignored.
struct MCPOAuthMetadata: Codable, Hashable, Sendable {

    /// REQUIRED. The authorization-server issuer identifier; must match the URL this document was fetched from
    /// (path-prefix check). Kept so the credential bundle records which issuer minted a given access token.
    let issuer: URL

    /// REQUIRED for the authorization-code flow. The user-facing endpoint
    /// where we open the system browser to begin auth.
    let authorizationEndpoint: URL

    /// REQUIRED for code exchange. POST target for `authorization_code` and
    /// `refresh_token` grants.
    let tokenEndpoint: URL

    /// OPTIONAL (RFC 7591). When present, a client can be registered dynamically without a pre-shared `client_id`.
    /// When absent, discovery fails with a clear "needs preregistered client" error.
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

    /// OPTIONAL. Auth methods supported at the token endpoint. The app uses `"none"` (public client + PKCE); a server that
    /// allows only `"client_secret_basic"` cannot be used, since a desktop app is not a confidential client.
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

    // Why: omission is not uniform: grant types and token-endpoint auth are lenient when omitted, but an omitted
    // `code_challenge_methods_supported` means the server does NOT support PKCE, so S256 must be explicit.
    /// True when the server advertises everything the desktop flow needs: the authorization-code grant, the PKCE S256
    /// method, and public-client token-endpoint auth (`"none"`) or omits that field.
    var supportsDesktopPKCEFlow: Bool {
        let grantsOK = grantTypesSupported?.contains("authorization_code") ?? true
        let pkceOK = codeChallengeMethodsSupported?.contains("S256") ?? false
        let authOK = tokenEndpointAuthMethodsSupported?.contains("none") ?? true
        return grantsOK && pkceOK && authOK
    }
}
