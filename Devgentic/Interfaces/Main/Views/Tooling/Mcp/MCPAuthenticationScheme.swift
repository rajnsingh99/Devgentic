// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPAuthenticationScheme.swift
//  Devgentic
//
//  Typed model for how a remote MCP server authenticates the client.
//  Today: none / bearer / api-key header. Phase 2 fills in OAuth.
//
//  This is the *configuration* — what kind of auth — not the secret material.
//  Tokens and keys live in `MCPSecretStore` (Keychain), keyed by `sourceID`
//  + scope. That separation is why this enum is plain Codable: nothing in here
//  is sensitive, so it's safe to persist inside `ServerDefinition`.
//

import Foundation

/// How a remote MCP server authenticates this client. Only the *shape* of
/// authentication is captured here — secret values (tokens, API keys, OAuth
/// access/refresh tokens) live in Keychain and are looked up at use time.
enum MCPAuthenticationScheme: Codable, Hashable {

    /// No authentication. Suitable for trusted-LAN servers or public demos.
    case none

    /// `Authorization: Bearer <token>` where the token is in Keychain at
    /// `MCPSecretScope.bearerToken` for this source.
    case bearer

    /// Custom header (e.g. `X-API-Key: <value>`) where the header value is in
    /// Keychain at `MCPSecretScope.apiKeyHeaderValue` for this source.
    /// `headerName` is part of config (not secret) so we keep it inline.
    case apiKeyHeader(headerName: String)

    /// OAuth 2.1 (PKCE + dynamic client registration). The full credential
    /// bundle — access token, refresh token, expiry, scopes, registered client
    /// metadata — lives in Keychain at `MCPSecretScope.oauthBundle` for this
    /// source. The `issuer` URL is config (not secret).
    ///
    /// Reserved for Phase 2; declared here so the type is stable from the
    /// start and we don't have to migrate every call site later.
    case oauth(issuer: URL)

    // MARK: - Codable

    /// Custom Codable so the JSON shape stays small and self-describing
    /// (instead of Swift's default associated-value-tag noise) and so we can
    /// migrate from older representations cleanly.
    private enum CodingKeys: String, CodingKey {
        case kind, headerName, issuer
    }

    private enum Kind: String, Codable {
        case none, bearer, apiKeyHeader, oauth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .none:
            self = .none
        case .bearer:
            self = .bearer
        case .apiKeyHeader:
            let headerName = try container.decode(String.self, forKey: .headerName)
            self = .apiKeyHeader(headerName: headerName)
        case .oauth:
            let issuer = try container.decode(URL.self, forKey: .issuer)
            self = .oauth(issuer: issuer)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case .bearer:
            try container.encode(Kind.bearer, forKey: .kind)
        case .apiKeyHeader(let headerName):
            try container.encode(Kind.apiKeyHeader, forKey: .kind)
            try container.encode(headerName, forKey: .headerName)
        case .oauth(let issuer):
            try container.encode(Kind.oauth, forKey: .kind)
            try container.encode(issuer, forKey: .issuer)
        }
    }
}

// MARK: - Display helpers

extension MCPAuthenticationScheme {

    /// Stable identifier used by the picker UI; never user-visible.
    var pickerID: String {
        switch self {
        case .none:           return "none"
        case .bearer:         return "bearer"
        case .apiKeyHeader:   return "apiKeyHeader"
        case .oauth:          return "oauth"
        }
    }

    /// Short human-readable label used in the picker UI and diagnostics.
    var displayLabel: String {
        switch self {
        case .none:                       return "None"
        case .bearer:                     return "Bearer Token"
        case .apiKeyHeader(let header):   return "API Key (\(header))"
        case .oauth(let issuer):          return "OAuth (\(issuer.host ?? issuer.absoluteString))"
        }
    }
}
