// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPOAuthDiscovery.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "MCPOAuthDiscovery")

/// Errors raised while discovering and validating OAuth authorization-server metadata (RFC 8414).
enum MCPOAuthDiscoveryError: LocalizedError {
    case invalidIssuerURL(String)
    case insecureScheme(String)
    case http(status: Int, body: String?)
    case malformedResponse(String)
    case unsupportedServer(String)
    case transport(Error)
    /// The `issuer` in the metadata document must equal the issuer that was requested (RFC 8414).
    case issuerMismatch(requested: String, returned: String)
    /// An endpoint inside the metadata document is not HTTPS.
    case insecureEndpoint(name: String, url: String)

    var errorDescription: String? {
        switch self {
        case .invalidIssuerURL(let s):    return "Invalid issuer URL: \(s)"
        case .insecureScheme(let s):      return "Refusing OAuth discovery over '\(s)://'. Use https:// (or localhost for dev)."
        case .http(let status, let body): return "Discovery returned HTTP \(status)\(body.map { ": \($0)" } ?? "")"
        case .malformedResponse(let s):   return "Discovery response was not valid metadata: \(s)"
        case .unsupportedServer(let s):   return "Authorization server doesn't support the desktop PKCE flow: \(s)"
        case .transport(let err):         return "Discovery transport failed: \(err.localizedDescription)"
        case .issuerMismatch(let requested, let returned):
            return "Authorization server identity mismatch: asked '\(requested)', document claims '\(returned)'. Refusing to continue."
        case .insecureEndpoint(let name, let url):
            return "Authorization server advertised a non-HTTPS \(name) (\(url)). Refusing to send credentials over it."
        }
    }
}

struct MCPOAuthDiscovery {

    // Why: appending to the whole issuer 404s for issuers with a path (Keycloak realms, Auth0 tenants, Okta).
    /// The RFC 8414 authorization-server metadata URL for an issuer.
    /// Inserts `/.well-known/oauth-authorization-server` between host and path (`https://as.example.com/realms/acme` ->
    /// `https://as.example.com/.well-known/oauth-authorization-server/realms/acme`); the OIDC fallback appends instead.
    static func wellKnownURL(for issuer: URL) -> URL? {
        var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false)
        let issuerPath = components?.path ?? ""
        let trimmed = issuerPath.count > 1 && issuerPath.hasSuffix("/")
            ? String(issuerPath.dropLast())
            : issuerPath
        components?.path = "/.well-known/oauth-authorization-server"
            + (trimmed.isEmpty || trimmed == "/" ? "" : trimmed)
        return components?.url
    }

    /// Best-effort discovery: tries the OAuth metadata path, then the OIDC path as a fallback. Returns nil when no metadata
    /// is found but the server is reachable (it does not advertise OAuth); throws for transport failures (network, TLS).
    static func probe(issuer: URL, session: URLSession = .shared) async throws -> MCPOAuthMetadata? {
        try validate(issuer: issuer)

        // RFC 8414 insertion for the OAuth document; the OIDC fallback appends, per its own spec (see `wellKnownURL`).
        guard let oauthPath = Self.wellKnownURL(for: issuer) else {
            throw MCPOAuthDiscoveryError.invalidIssuerURL(issuer.absoluteString)
        }
        let oidcPath   = issuer.appendingPathComponent(".well-known/openid-configuration")

        // Try OAuth first, fall through to OIDC. Only 404 is swallowed; any other transport failure escapes so the caller
        // knows something is structurally wrong with the URL.
        for url in [oauthPath, oidcPath] {
            do {
                if let metadata = try await fetch(from: url, expectedIssuer: issuer, session: session) {
                    return metadata
                }
            } catch MCPOAuthDiscoveryError.http(status: 404, body: _) {
                continue
            }
        }
        return nil
    }

    /// Strict fetch: throws on missing/malformed metadata rather than
    /// returning nil. Used at connect time when we already know the server
    /// is OAuth-configured (the issuer was committed to `MCPAuthenticationScheme.oauth`).
    static func fetch(issuer: URL, session: URLSession = .shared) async throws -> MCPOAuthMetadata {
        try validate(issuer: issuer)
        // RFC 8414 insertion; see `wellKnownURL`.
        guard let url = Self.wellKnownURL(for: issuer) else {
            throw MCPOAuthDiscoveryError.invalidIssuerURL(issuer.absoluteString)
        }
        if let m = try await fetch(from: url, expectedIssuer: issuer, session: session) {
            return m
        }
        // Fallback to OIDC.
        let oidc = issuer.appendingPathComponent(".well-known/openid-configuration")
        if let m = try await fetch(from: oidc, expectedIssuer: issuer, session: session) {
            return m
        }
        throw MCPOAuthDiscoveryError.malformedResponse("No metadata found at \(url.absoluteString) or OIDC fallback.")
    }

    // MARK: - Private

    /// Single-URL fetch + decode. Returns nil only on 404 (metadata not at
    /// this path). Other HTTP failures throw.
    private static func fetch(
        from url: URL,
        expectedIssuer: URL,
        session: URLSession
    ) async throws -> MCPOAuthMetadata? {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // 8 seconds is enough for any reasonable AS and avoids the user staring at the form;
        // callers can wrap a longer timeout for slow links.
        req.timeoutInterval = 8

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw MCPOAuthDiscoveryError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MCPOAuthDiscoveryError.malformedResponse("Non-HTTP response.")
        }
        if http.statusCode == 404 {
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw MCPOAuthDiscoveryError.http(status: http.statusCode, body: body)
        }

        do {
            let metadata = try JSONDecoder().decode(MCPOAuthMetadata.self, from: data)

            // Validate the contents of the document, not just the URL it came from: every advertised endpoint is otherwise trusted.
            // A hostile `http://` token endpoint would receive the authorization code and PKCE verifier in clear text.
            try validateDocument(metadata, requestedIssuer: expectedIssuer)

            // Reject up-front rather than letting the caller try authorize
            // and fail with a confusing error.
            guard metadata.supportsDesktopPKCEFlow else {
                throw MCPOAuthDiscoveryError.unsupportedServer(
                    "Server doesn't advertise authorization_code + PKCE S256 + public-client auth."
                )
            }
            logger.info("Discovered OAuth metadata for \(metadata.issuer.absoluteString)")
            return metadata
        } catch let e as MCPOAuthDiscoveryError {
            throw e
        } catch {
            throw MCPOAuthDiscoveryError.malformedResponse(error.localizedDescription)
        }
    }

    /// RFC 8414 identity check plus a transport check on every advertised endpoint.
    /// Endpoints need not share the issuer's host (Google issues from `accounts.google.com`, serves tokens elsewhere).
    /// The issuer match pins who the document speaks for; HTTPS pins the channel.
    private static func validateDocument(_ metadata: MCPOAuthMetadata, requestedIssuer: URL) throws {
        // Compare on a normalized form: a trailing slash is not an identity difference,
        // and comparing raw strings would reject correct servers.
        func normalized(_ url: URL) -> String {
            var s = url.absoluteString.lowercased()
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }

        guard normalized(metadata.issuer) == normalized(requestedIssuer) else {
            throw MCPOAuthDiscoveryError.issuerMismatch(
                requested: requestedIssuer.absoluteString,
                returned: metadata.issuer.absoluteString
            )
        }

        let endpoints: [(String, URL?)] = [
            ("authorization_endpoint", metadata.authorizationEndpoint),
            ("token_endpoint", metadata.tokenEndpoint),
            ("registration_endpoint", metadata.registrationEndpoint),
            ("revocation_endpoint", metadata.revocationEndpoint),
        ]
        for (name, endpoint) in endpoints {
            guard let endpoint else { continue }
            guard isSecureEndpoint(endpoint) else {
                throw MCPOAuthDiscoveryError.insecureEndpoint(name: name, url: endpoint.absoluteString)
            }
        }
    }

    /// HTTPS, or plain HTTP on loopback for local development (RFC 8252).
    private static func isSecureEndpoint(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        if scheme == "https" { return true }
        let host = url.host?.lowercased() ?? ""
        return scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host == "::1")
    }

    /// Refuses non-HTTPS issuers; `localhost` and `127.0.0.1` are exempt (RFC 8252 loopback) so a local test rig works.
    private static func validate(issuer: URL) throws {
        guard let scheme = issuer.scheme?.lowercased() else {
            throw MCPOAuthDiscoveryError.invalidIssuerURL(issuer.absoluteString)
        }
        if scheme == "https" {
            return
        }
        let host = issuer.host?.lowercased() ?? ""
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        if scheme == "http" && isLoopback {
            return
        }
        throw MCPOAuthDiscoveryError.insecureScheme(scheme)
    }
}
