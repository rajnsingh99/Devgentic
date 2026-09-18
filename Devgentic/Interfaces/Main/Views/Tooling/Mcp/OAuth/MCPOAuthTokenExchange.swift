// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPOAuthTokenExchange.swift
//  Devgentic
//
//  Two POSTs to the AS token endpoint:
//
//   - Authorization-code exchange: trade the redirect-handed `code` (plus
//     PKCE verifier) for an access_token + (optionally) refresh_token.
//   - Refresh exchange: trade a refresh_token for a fresh access_token.
//
//  Both use the public-client form (no client secret) — `client_id` goes in
//  the body, `token_endpoint_auth_method=none`. Per RFC 6749 §4.1.3 / §6.
//

import Foundation
import os

private let logger = DGLogger(category: "MCPOAuthTokenExchange")

enum MCPOAuthTokenExchangeError: LocalizedError {
    case http(status: Int, body: String?)
    case malformedResponse(String)
    case oauthError(error: String, description: String?)
    case transport(Error)
    case missingRefreshToken

    var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            return "Token exchange returned HTTP \(status)\(body.map { ": \($0)" } ?? "")"
        case .malformedResponse(let s):
            return "Token response was not parseable: \(s)"
        case .oauthError(let err, let desc):
            return desc.map { "\(err): \($0)" } ?? err
        case .transport(let err):
            return "Token transport failed: \(err.localizedDescription)"
        case .missingRefreshToken:
            return "No refresh token available — full re-auth required."
        }
    }
}

/// RFC 6749 §5.1 token response. We model the success-shape; on non-2xx the
/// AS returns a different shape (`{ error, error_description, error_uri }`)
/// which we decode into `OAuthErrorResponse` and surface as a typed error.
private struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let tokenType: String                // expected "Bearer"
    let expiresIn: TimeInterval?         // seconds; some servers omit (treat as long-lived)
    let refreshToken: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case tokenType    = "token_type"
        case expiresIn    = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

private struct OAuthErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

struct MCPOAuthTokenExchange {

    /// Exchange a fresh authorization code (handed back via the loopback
    /// redirect) for tokens. PKCE verifier is required — it's what proves
    /// to the AS that we're the same client that initiated the flow.
    static func exchangeAuthorizationCode(
        code: String,
        codeVerifier: String,
        clientId: String,
        redirectURI: URL,
        metadata: MCPOAuthMetadata,
        resource: URL? = nil,
        session: URLSession = .shared
    ) async throws -> (accessToken: String, refreshToken: String?, expiresAt: Date, grantedScopes: [String]) {
        var params: [(String, String)] = [
            ("grant_type",    "authorization_code"),
            ("code",          code),
            ("code_verifier", codeVerifier),
            ("client_id",     clientId),
            ("redirect_uri",  redirectURI.absoluteString),
        ]
        // RFC 8707 — must be repeated here, not only on the authorize request, for the
        // AS to bind the audience of the token it actually issues.
        if let resource {
            params.append(("resource", resource.absoluteString))
        }
        let response = try await postForm(to: metadata.tokenEndpoint, params: params, session: session)
        return resolve(response: response)
    }

    /// Refresh an access token using a previously-issued refresh token.
    /// Throws `missingRefreshToken` if the bundle has no refresh token —
    /// caller should fall back to a full re-auth.
    static func refresh(
        bundle: MCPOAuthCredentialBundle,
        metadata: MCPOAuthMetadata,
        resource: URL? = nil,
        session: URLSession = .shared
    ) async throws -> (accessToken: String, refreshToken: String?, expiresAt: Date, grantedScopes: [String]) {
        guard let refreshToken = bundle.refreshToken else {
            throw MCPOAuthTokenExchangeError.missingRefreshToken
        }
        var params: [(String, String)] = [
            ("grant_type",    "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id",     bundle.clientId),
        ]
        // Keep the audience binding across refreshes — otherwise the refreshed token
        // silently widens back to a general-purpose one.
        if let resource {
            params.append(("resource", resource.absoluteString))
        }
        let response = try await postForm(to: metadata.tokenEndpoint, params: params, session: session)
        return resolve(response: response, fallbackScopes: bundle.grantedScopes)
    }

    /// Best-effort RFC 7009 revocation, used when the user deletes an MCP server.
    ///
    /// Purging the Keychain only makes Devgentic forget the token; the token itself stays
    /// valid at the provider until it expires. Revoking tells the AS to invalidate it now.
    /// Deliberately non-throwing: deleting a server must succeed even when the provider is
    /// unreachable or does not implement revocation.
    static func revoke(
        token: String,
        tokenTypeHint: String,
        clientId: String,
        revocationEndpoint: URL,
        session: URLSession = .shared
    ) async {
        let params: [(String, String)] = [
            ("token", token),
            ("token_type_hint", tokenTypeHint),
            ("client_id", clientId),
        ]
        do {
            var components = URLComponents()
            components.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
            var req = URLRequest(url: revocationEndpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 8
            req.httpBody = (components.percentEncodedQuery ?? "").data(using: .utf8)

            let (_, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            // RFC 7009 §2.2: the AS returns 200 even for an unknown token.
            if (200..<300).contains(status) {
                logger.info("[MCP-OAUTH] Revoked \(tokenTypeHint) at \(MCPRedaction.redact(url: revocationEndpoint.absoluteString)).")
            } else {
                logger.warning("""
                    [MCP-OAUTH] Revocation of \(tokenTypeHint) returned HTTP \(status) — the token \
                    may REMAIN VALID at the provider until it expires. Local secrets are still purged.
                    """)
            }
        } catch {
            logger.warning("""
                [MCP-OAUTH] Revocation of \(tokenTypeHint) failed: \(error.localizedDescription). \
                The token may REMAIN VALID at the provider until it expires; revoke it manually \
                there if it mattered. Local secrets are still purged.
                """)
        }
    }

    // MARK: - Private

    /// `application/x-www-form-urlencoded` POST per RFC 6749 §3.2.
    ///
    /// The token endpoint must be HTTPS for any non-loopback issuer. That IS now
    /// enforced — `MCPOAuthDiscovery.validateDocument` scheme-checks every endpoint in
    /// the metadata document before it is ever handed here. Until 2026-08-01 this comment
    /// claimed the same thing but it was not true: discovery only validated the issuer URL
    /// the caller passed in, never the endpoints the server returned, so an
    /// attacker-supplied `"token_endpoint": "http://…"` would have been posted to in the
    /// clear, carrying the authorization code and PKCE verifier.
    private static func postForm(
        to endpoint: URL,
        params: [(String, String)],
        session: URLSession
    ) async throws -> OAuthTokenResponse {
        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        let body = components.percentEncodedQuery ?? ""

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        req.httpBody = body.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw MCPOAuthTokenExchangeError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MCPOAuthTokenExchangeError.malformedResponse("Non-HTTP response.")
        }

        // OAuth errors come back with status 4xx and a structured JSON body.
        // Decode that shape preferentially before falling back to a raw HTTP
        // error so we can surface `invalid_grant` / `invalid_client` cleanly.
        if !(200..<300).contains(http.statusCode) {
            if let oauthErr = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data) {
                throw MCPOAuthTokenExchangeError.oauthError(error: oauthErr.error, description: oauthErr.errorDescription)
            }
            let body = String(data: data, encoding: .utf8)
            throw MCPOAuthTokenExchangeError.http(status: http.statusCode, body: body)
        }

        do {
            return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        } catch {
            throw MCPOAuthTokenExchangeError.malformedResponse(error.localizedDescription)
        }
    }

    /// Compute absolute expiry + parse scope string. `fallbackScopes` is used
    /// for refresh, where the AS often omits `scope` to mean "same as before."
    private static func resolve(
        response: OAuthTokenResponse,
        fallbackScopes: [String] = []
    ) -> (accessToken: String, refreshToken: String?, expiresAt: Date, grantedScopes: [String]) {
        // Default to one hour when `expires_in` is omitted — the OAuth 2.1
        // recommendation. We'd rather refresh slightly sooner than nothing.
        let expiresIn = response.expiresIn ?? 3600
        let expiresAt = Date().addingTimeInterval(expiresIn)
        let scopes: [String] = {
            if let s = response.scope, !s.isEmpty {
                return s.split(separator: " ").map(String.init)
            }
            return fallbackScopes
        }()
        // Token shape (issuer/aud/exp) is *deliberately* not logged — only
        // the fact of success and the expiry. Token text never hits the log.
        logger.info("Token exchange OK — expiresIn=\(Int(expiresIn))s scopes=\(scopes.joined(separator: ","))")
        return (response.accessToken, response.refreshToken, expiresAt, scopes)
    }
}
