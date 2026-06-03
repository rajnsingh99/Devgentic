//
//  MCPOAuthDiscovery.swift
//  Devgentic
//
//  Fetches OAuth Authorization Server Metadata (RFC 8414) for an MCP server's
//  issuer URL. Used in two places:
//
//   1. Auto-detect: when the user pastes a remote URL into the Add MCP form,
//      we probe `/.well-known/oauth-authorization-server` and offer OAuth
//      automatically if we get a valid metadata document back.
//
//   2. Connect-time: when materializing an OAuth-configured server, we re-
//      fetch metadata to pick up endpoint rotations (token endpoint moved,
//      registration revoked, etc.).
//
//  Only HTTPS issuers are accepted — except for `localhost` / `127.0.0.1`,
//  per RFC 8252 §7.3 (loopback exemption for dev).
//

import Foundation
import os

private let logger = DGLogger(category: "MCPOAuthDiscovery")

enum MCPOAuthDiscoveryError: LocalizedError {
    case invalidIssuerURL(String)
    case insecureScheme(String)
    case http(status: Int, body: String?)
    case malformedResponse(String)
    case unsupportedServer(String)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .invalidIssuerURL(let s):    return "Invalid issuer URL: \(s)"
        case .insecureScheme(let s):      return "Refusing OAuth discovery over '\(s)://'. Use https:// (or localhost for dev)."
        case .http(let status, let body): return "Discovery returned HTTP \(status)\(body.map { ": \($0)" } ?? "")"
        case .malformedResponse(let s):   return "Discovery response was not valid metadata: \(s)"
        case .unsupportedServer(let s):   return "Authorization server doesn't support the desktop PKCE flow: \(s)"
        case .transport(let err):         return "Discovery transport failed: \(err.localizedDescription)"
        }
    }
}

struct MCPOAuthDiscovery {

    /// Best-effort discovery: try the OAuth metadata path first, then the
    /// OIDC path as a fallback (many providers serve the same document at
    /// both URLs). Returns nil for "no metadata found, but the server
    /// is otherwise reachable" — i.e. server doesn't advertise OAuth, so the
    /// caller should not auto-select OAuth as the auth scheme. Throws for
    /// transport-level failures (network down, TLS error, etc.).
    static func probe(issuer: URL, session: URLSession = .shared) async throws -> MCPOAuthMetadata? {
        try validate(issuer: issuer)

        let oauthPath  = issuer.appendingPathComponent(".well-known/oauth-authorization-server")
        let oidcPath   = issuer.appendingPathComponent(".well-known/openid-configuration")

        // Try OAuth first, fall through to OIDC. We only swallow 404 — any
        // other transport failure escapes so the caller knows something's
        // structurally wrong with the URL.
        for url in [oauthPath, oidcPath] {
            do {
                if let metadata = try await fetch(from: url, session: session) {
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
        let url = issuer.appendingPathComponent(".well-known/oauth-authorization-server")
        if let m = try await fetch(from: url, session: session) {
            return m
        }
        // Fallback to OIDC.
        let oidc = issuer.appendingPathComponent(".well-known/openid-configuration")
        if let m = try await fetch(from: oidc, session: session) {
            return m
        }
        throw MCPOAuthDiscoveryError.malformedResponse("No metadata found at \(url.absoluteString) or OIDC fallback.")
    }

    // MARK: - Private

    /// Single-URL fetch + decode. Returns nil only on 404 (metadata not at
    /// this path). Other HTTP failures throw.
    private static func fetch(from url: URL, session: URLSession) async throws -> MCPOAuthMetadata? {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // 8 seconds is enough for any reasonable AS — too long becomes a
        // bad UX (user staring at the form). Caller can wrap in a longer
        // timeout if it's a known-slow link.
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

    /// Refuse non-HTTPS issuers in production. `localhost` / `127.0.0.1` are
    /// exempted per RFC 8252 §7.3 (loopback) so the local test rig works.
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
