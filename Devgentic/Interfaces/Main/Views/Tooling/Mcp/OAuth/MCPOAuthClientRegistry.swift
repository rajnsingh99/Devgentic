// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPOAuthClientRegistry.swift
//  Devgentic
//
//  RFC 7591 — Dynamic Client Registration. Instead of asking the user to
//  paste a `client_id` (which most users don't have), we register the app
//  with the authorization server at first connect and stash the resulting
//  `client_id` in the credential bundle. Each MCP server gets its own
//  registration — a `client_id` is scoped to the issuer that minted it.
//

import Foundation
import os

private let logger = DGLogger(category: "MCPOAuthClientRegistry")

/// Subset of an RFC 7591 registration request body. We only send the fields
/// every implementation honors — extra fields tend to cause picky servers
/// (Hydra is one) to reject the whole request.
struct MCPOAuthRegistrationRequest: Codable {
    let clientName: String
    let redirectUris: [String]
    /// We're a desktop app — no client secret. Maps to "public client" in
    /// OAuth 2.1 terminology.
    let tokenEndpointAuthMethod: String  // "none"
    /// Always include `authorization_code` + `refresh_token` so the AS knows
    /// we'll later try to refresh.
    let grantTypes: [String]
    let responseTypes: [String]          // ["code"]
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case clientName              = "client_name"
        case redirectUris            = "redirect_uris"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
        case grantTypes              = "grant_types"
        case responseTypes           = "response_types"
        case scope
    }
}

/// Subset of an RFC 7591 registration *response*. We tolerate extra fields.
struct MCPOAuthRegistrationResponse: Codable, Hashable, Sendable {
    let clientId: String
    /// Public clients have no secret — present in the response only for
    /// confidential clients. Decoded so we can detect that case and bail.
    let clientSecret: String?
    /// Optional. Some servers issue a registration management token and a
    /// configuration URL (RFC 7592) — we keep them so we could later
    /// re-fetch / update / revoke this registration.
    let registrationAccessToken: String?
    let registrationClientUri: URL?

    enum CodingKeys: String, CodingKey {
        case clientId                 = "client_id"
        case clientSecret             = "client_secret"
        case registrationAccessToken  = "registration_access_token"
        case registrationClientUri    = "registration_client_uri"
    }
}

enum MCPOAuthRegistrationError: LocalizedError {
    case notSupported
    case http(status: Int, body: String?)
    case malformedResponse(String)
    case transport(Error)
    case confidentialClientReturned

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "Authorization server doesn't expose a dynamic-client-registration endpoint."
        case .http(let status, let body):
            return "Registration returned HTTP \(status)\(body.map { ": \($0)" } ?? "")"
        case .malformedResponse(let s):
            return "Registration response was not parseable: \(s)"
        case .transport(let err):
            return "Registration transport failed: \(err.localizedDescription)"
        case .confidentialClientReturned:
            return "Authorization server returned a confidential client. Devgentic only supports public-client (PKCE) registrations."
        }
    }
}

struct MCPOAuthClientRegistry {

    /// Registers Devgentic with the given AS and returns the issued credentials.
    /// Throws `notSupported` when the metadata doesn't include a registration
    /// endpoint — caller can decide to fall back (e.g. ask the user for a
    /// preregistered client_id) or surface the error.
    static func register(
        with metadata: MCPOAuthMetadata,
        clientName: String,
        redirectURI: URL,
        scope: String? = nil,
        session: URLSession = .shared
    ) async throws -> MCPOAuthRegistrationResponse {
        guard let registrationEndpoint = metadata.registrationEndpoint else {
            throw MCPOAuthRegistrationError.notSupported
        }

        let body = MCPOAuthRegistrationRequest(
            clientName: clientName,
            redirectUris: [redirectURI.absoluteString],
            tokenEndpointAuthMethod: "none",
            grantTypes: ["authorization_code", "refresh_token"],
            responseTypes: ["code"],
            scope: scope
        )

        var req = URLRequest(url: registrationEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        req.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw MCPOAuthRegistrationError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MCPOAuthRegistrationError.malformedResponse("Non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw MCPOAuthRegistrationError.http(status: http.statusCode, body: body)
        }

        do {
            let registration = try JSONDecoder().decode(MCPOAuthRegistrationResponse.self, from: data)
            // We only support public clients — if the AS issued a secret,
            // it's a confidential-client registration which doesn't fit our
            // threat model (no safe way to embed a secret in a desktop app).
            if registration.clientSecret != nil {
                throw MCPOAuthRegistrationError.confidentialClientReturned
            }
            logger.info("Registered with AS \(metadata.issuer.absoluteString) — clientId=\(registration.clientId)")
            return registration
        } catch let e as MCPOAuthRegistrationError {
            throw e
        } catch {
            throw MCPOAuthRegistrationError.malformedResponse(error.localizedDescription)
        }
    }
}
