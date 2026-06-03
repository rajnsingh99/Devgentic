//
//  MCPOAuthCoordinator.swift
//  Devgentic
//
//  Top-level OAuth orchestrator — ties discovery, registration, PKCE, the
//  authorize-URL build, and token exchange together. The actual browser
//  redirect flow (ASWebAuthenticationSession + loopback listener) lands in
//  Phase 3; this coordinator exposes everything *except* "open the browser
//  and wait for a code" so the UI layer can plug in its own callback.
//
//  Bundle persistence to/from Keychain is centralized here so callers don't
//  reach into MCPSecretStore directly for OAuth — only this type knows the
//  JSON shape of the bundle.
//

import Foundation
import os

private let logger = DGLogger(category: "MCPOAuthCoordinator")

/// Receives the auth-code redirect from the system browser. Phase 3 will
/// implement this on top of ASWebAuthenticationSession + a loopback
/// HTTP listener; defining it as a protocol here keeps Phase 2 testable
/// without UI dependencies.
protocol MCPOAuthRedirectHandler: Sendable {

    /// Open the authorize URL in the system browser, watch for the redirect
    /// to `redirectURI`, and return the parsed `(code, state)` pair.
    /// Throws on user-cancel, redirect timeout, or `state` mismatch.
    func awaitAuthorizationCode(
        authorizeURL: URL,
        redirectURI: URL,
        expectedState: String
    ) async throws -> String  // the `code`
}

enum MCPOAuthCoordinatorError: LocalizedError {
    case cannotPersist(String)
    case bundleNotFound

    var errorDescription: String? {
        switch self {
        case .cannotPersist(let s): return "Failed to persist OAuth bundle: \(s)"
        case .bundleNotFound:        return "No OAuth bundle stored for this source."
        }
    }
}

/// Latency helper for `MCPLog`. Defined here so call sites stay one-liners.
private func ms(since start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
}

@MainActor
struct MCPOAuthCoordinator {

    /// Opaque value the AS echoes back on redirect — used to defeat redirect-
    /// confusion attacks. 32 random bytes base64url'd, fresh per flow.
    static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes).base64URLEncodedString()
    }

    /// Build the authorize URL the user's browser should open. PKCE
    /// challenge + state + redirect_uri all come from the caller — every
    /// piece is regenerated per flow, never reused.
    static func buildAuthorizeURL(
        metadata: MCPOAuthMetadata,
        clientId: String,
        redirectURI: URL,
        scopes: [String],
        state: String,
        pkce: MCPPKCEPair
    ) -> URL {
        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var existing = components.queryItems ?? []
        existing.append(contentsOf: [
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "client_id",             value: clientId),
            URLQueryItem(name: "redirect_uri",          value: redirectURI.absoluteString),
            URLQueryItem(name: "code_challenge",        value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.challengeMethod),
            URLQueryItem(name: "state",                 value: state),
        ])
        if !scopes.isEmpty {
            existing.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
        }
        components.queryItems = existing
        return components.url!
    }

    // MARK: - End-to-end flow

    /// Run the full first-time OAuth flow and return the resulting bundle.
    /// **Does not persist** — caller is responsible for `persist(_:sourceID:)`
    /// when ready (the Add MCP form, for example, defers persistence until
    /// the user clicks Add to Library).
    ///
    /// Steps:
    ///   1. Discover metadata at `issuer/.well-known/oauth-authorization-server`
    ///   2. Dynamically register the client (RFC 7591)
    ///   3. Generate PKCE + state
    ///   4. Hand the authorize URL to the redirect handler, await `code`
    ///   5. Exchange the code for tokens
    static func performInitialAuthorization(
        issuer: URL,
        scopes: [String],
        redirectURI: URL,
        redirectHandler: MCPOAuthRedirectHandler,
        clientName: String = "Devgentic"
    ) async throws -> MCPOAuthCredentialBundle {

        // 1. Discovery
        let discoverStart = Date()
        let metadata: MCPOAuthMetadata
        do {
            metadata = try await MCPOAuthDiscovery.fetch(issuer: issuer)
            MCPLog.info(.oauthDiscover, "metadata fetched", latencyMS: ms(since: discoverStart),
                        fields: ["issuer": metadata.issuer.absoluteString])
        } catch {
            MCPLog.error(.oauthDiscover, "metadata fetch failed: \(error.localizedDescription)",
                         latencyMS: ms(since: discoverStart),
                         fields: ["issuer": issuer.absoluteString])
            throw error
        }

        // 2. Dynamic client registration. We always re-register on first auth
        // for a given source — registrations are cheap and per-server.
        let registerStart = Date()
        let registration: MCPOAuthRegistrationResponse
        do {
            registration = try await MCPOAuthClientRegistry.register(
                with: metadata,
                clientName: clientName,
                redirectURI: redirectURI,
                scope: scopes.joined(separator: " ")
            )
            MCPLog.info(.oauthRegister, "registered (clientId=\(registration.clientId))",
                        latencyMS: ms(since: registerStart),
                        fields: ["issuer": metadata.issuer.absoluteString])
        } catch {
            MCPLog.error(.oauthRegister, "registration failed: \(error.localizedDescription)",
                         latencyMS: ms(since: registerStart),
                         fields: ["issuer": metadata.issuer.absoluteString])
            throw error
        }

        // 3. PKCE + state, fresh per flow
        let pkce = MCPPKCE.generate()
        let state = generateState()

        // 4. Build URL, hand to redirect handler
        let authorizeURL = buildAuthorizeURL(
            metadata: metadata,
            clientId: registration.clientId,
            redirectURI: redirectURI,
            scopes: scopes,
            state: state,
            pkce: pkce
        )
        let authorizeStart = Date()
        let code: String
        do {
            code = try await redirectHandler.awaitAuthorizationCode(
                authorizeURL: authorizeURL,
                redirectURI: redirectURI,
                expectedState: state
            )
            MCPLog.info(.oauthAuthorize, "authorization code captured",
                        latencyMS: ms(since: authorizeStart))
        } catch {
            MCPLog.error(.oauthAuthorize, "authorization failed: \(error.localizedDescription)",
                         latencyMS: ms(since: authorizeStart))
            throw error
        }

        // 5. Token exchange
        let exchangeStart = Date()
        let tokens: (accessToken: String, refreshToken: String?, expiresAt: Date, grantedScopes: [String])
        do {
            tokens = try await MCPOAuthTokenExchange.exchangeAuthorizationCode(
                code: code,
                codeVerifier: pkce.verifier,
                clientId: registration.clientId,
                redirectURI: redirectURI,
                metadata: metadata
            )
            MCPLog.info(.oauthExchange, "token exchange ok",
                        latencyMS: ms(since: exchangeStart),
                        fields: [
                            "scopes": tokens.grantedScopes.joined(separator: " "),
                            "hasRefresh": tokens.refreshToken != nil ? "yes" : "no",
                            "expiresInSec": "\(Int(tokens.expiresAt.timeIntervalSinceNow))"
                        ])
        } catch {
            MCPLog.error(.oauthExchange, "token exchange failed: \(error.localizedDescription)",
                         latencyMS: ms(since: exchangeStart))
            throw error
        }

        let bundle = MCPOAuthCredentialBundle(
            issuer: metadata.issuer,
            clientId: registration.clientId,
            grantedScopes: tokens.grantedScopes,
            redirectURI: redirectURI,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            accessTokenExpiresAt: tokens.expiresAt,
            registrationAccessToken: registration.registrationAccessToken,
            registrationClientUri: registration.registrationClientUri
        )
        logger.info("Initial OAuth completed for issuer \(metadata.issuer.absoluteString)")
        return bundle
    }

    /// Convenience wrapper that constructs the loopback listener, registers
    /// it, runs the flow, and tears the listener down. Use this from UI code
    /// — handles the listener lifecycle so callers don't have to.
    static func performInitialAuthorizationWithLoopback(
        issuer: URL,
        scopes: [String],
        clientName: String = "Devgentic"
    ) async throws -> MCPOAuthCredentialBundle {
        let listener = try MCPOAuthLoopbackListener()
        LoopbackRegistry.shared.register(listener)
        defer { LoopbackRegistry.shared.unregister(redirectURL: listener.redirectURL) }

        let handler = MCPOAuthBrowserRedirectHandler()
        return try await performInitialAuthorization(
            issuer: issuer,
            scopes: scopes,
            redirectURI: listener.redirectURL,
            redirectHandler: handler,
            clientName: clientName
        )
    }

    /// Refresh a stored bundle's access token. Used reactively (on 401) and
    /// proactively (on launch when within 5 min of expiry). Returns the
    /// updated bundle; persists it before returning so callers don't have
    /// to remember to write back.
    @discardableResult
    static func refresh(sourceID: UUID) async throws -> MCPOAuthCredentialBundle {
        guard var bundle = loadBundle(sourceID: sourceID) else {
            throw MCPOAuthCoordinatorError.bundleNotFound
        }

        // Re-fetch metadata — endpoints can rotate, and the spec mandates
        // we honor the current document on every refresh.
        let metadata = try await MCPOAuthDiscovery.fetch(issuer: bundle.issuer)
        let tokens = try await MCPOAuthTokenExchange.refresh(bundle: bundle, metadata: metadata)

        bundle.accessToken = tokens.accessToken
        // Some servers rotate the refresh token on every refresh (recommended
        // by OAuth 2.1). When they don't, keep the old one.
        if let newRefresh = tokens.refreshToken {
            bundle = MCPOAuthCredentialBundle(
                issuer: bundle.issuer,
                clientId: bundle.clientId,
                grantedScopes: tokens.grantedScopes,
                redirectURI: bundle.redirectURI,
                accessToken: tokens.accessToken,
                refreshToken: newRefresh,
                accessTokenExpiresAt: tokens.expiresAt,
                registrationAccessToken: bundle.registrationAccessToken,
                registrationClientUri: bundle.registrationClientUri
            )
        } else {
            bundle.accessTokenExpiresAt = tokens.expiresAt
        }

        try persist(bundle, sourceID: sourceID)
        logger.info("Refreshed OAuth tokens for source \(sourceID.uuidString)")
        return bundle
    }

    // MARK: - Bundle persistence

    /// Read the stored bundle for a source. Returns nil when absent or when
    /// the stored blob can't be decoded (e.g. shape changed across versions).
    static func loadBundle(sourceID: UUID) -> MCPOAuthCredentialBundle? {
        guard let json = MCPSecretStore.shared.retrieve(.oauthBundle, sourceID: sourceID),
              let data = json.data(using: .utf8) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(MCPOAuthCredentialBundle.self, from: data)
        } catch {
            logger.warning("OAuth bundle for \(sourceID.uuidString) failed to decode: \(error.localizedDescription)")
            return nil
        }
    }

    /// Encode and save. Throws on JSON-encode failure (shouldn't happen for
    /// our own type) or Keychain write failure.
    static func persist(_ bundle: MCPOAuthCredentialBundle, sourceID: UUID) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(bundle)
        } catch {
            throw MCPOAuthCoordinatorError.cannotPersist(error.localizedDescription)
        }
        guard let json = String(data: data, encoding: .utf8) else {
            throw MCPOAuthCoordinatorError.cannotPersist("UTF-8 encoding failed.")
        }
        let ok = MCPSecretStore.shared.store(json, for: .oauthBundle, sourceID: sourceID)
        if !ok {
            throw MCPOAuthCoordinatorError.cannotPersist("Keychain write returned false.")
        }
    }
}
