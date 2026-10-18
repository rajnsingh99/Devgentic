// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPOAuthCoordinator.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "MCPOAuthCoordinator")

/// Receives the auth-code redirect from the system browser.
/// A protocol so the OAuth flow is testable without UI dependencies; production uses `ASWebAuthenticationSession`
/// with a loopback listener.
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
    /// The provider rotated the refresh token and the replacement could not be stored, so the grant is dead.
    /// The previous refresh token is already invalid at the provider and the new one existed only in memory.
    case rotatedRefreshTokenLost(sourceID: UUID, underlying: String)

    var errorDescription: String? {
        switch self {
        case .cannotPersist(let s): return "Failed to persist OAuth bundle: \(s)"
        case .bundleNotFound:        return "No OAuth bundle stored for this source."
        case .rotatedRefreshTokenLost(_, let underlying):
            return "The sign-in was refreshed but the new credentials could not be saved to the "
                + "Keychain (\(underlying)). This server must be signed in to again from its editor."
        }
    }
}

/// Latency helper for `MCPLog`. Defined here so call sites stay one-liners.
private func ms(since start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
}

@MainActor
struct MCPOAuthCoordinator {

    /// Generates the opaque `state` value the AS echoes back on redirect to defeat redirect-confusion attacks: 32
    /// random bytes, base64url, fresh per flow.
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
        pkce: MCPPKCEPair,
        resource: URL? = nil
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
        // RFC 8707 resource indicator: binds the token's audience to this MCP server so it cannot be replayed elsewhere;
        // servers without RFC 8707 ignore it.
        if let resource {
            existing.append(URLQueryItem(name: "resource", value: resource.absoluteString))
        }
        components.queryItems = existing
        return components.url!
    }

    // MARK: - End-to-end flow

    /// Runs the full first-time OAuth flow (discovery, registration, PKCE, authorization, token exchange).
    /// Does not persist; the caller calls `persist(_:sourceID:)`. `resource` is the RFC 8707 audience (nil for stdio).
    /// `serverURL` is recorded for the local binding check, never sent.
    static func performInitialAuthorization(
        issuer: URL,
        scopes: [String],
        redirectURI: URL,
        redirectHandler: MCPOAuthRedirectHandler,
        clientName: String = "Devgentic",
        resource: URL? = nil,
        serverURL: URL? = nil
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
            pkce: pkce,
            resource: resource
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
                metadata: metadata,
                resource: resource
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
            registrationClientUri: registration.registrationClientUri,
            resource: resource,
            serverURL: serverURL
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
        clientName: String = "Devgentic",
        resource: URL? = nil,
        serverURL: URL? = nil
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
            clientName: clientName,
            resource: resource,
            serverURL: serverURL
        )
    }

    // MARK: - Refresh

    // Why: `@MainActor` does not serialize `refresh` across awaits; a reused refresh token makes some providers revoke the
    // grant.
    /// Refreshes in flight, keyed on source; a second caller joins the in-flight task instead of starting another
    /// exchange.
    /// The task is unstructured so a rotation runs to completion even if the caller is cancelled.
    private static var inFlightRefreshes: [UUID: Task<MCPOAuthCredentialBundle, Error>] = [:]

    /// The collaborators `refresh` needs, so single-flight and rotation-safe persistence are testable; production never
    /// reassigns them.
    struct RefreshDependencies {
        var loadBundle: @MainActor (UUID) -> MCPOAuthCredentialBundle?
        var fetchMetadata: @MainActor (URL) async throws -> MCPOAuthMetadata
        var exchange: @MainActor (MCPOAuthCredentialBundle, MCPOAuthMetadata) async throws -> RefreshedTokens
        var persist: @MainActor (MCPOAuthCredentialBundle, UUID) throws -> Void
    }

    typealias RefreshedTokens = (
        accessToken: String, refreshToken: String?, expiresAt: Date, grantedScopes: [String]
    )

    private static let liveRefreshDependencies = RefreshDependencies(
        loadBundle: { loadBundle(sourceID: $0) },
        fetchMetadata: { try await MCPOAuthDiscovery.fetch(issuer: $0) },
        // Repeat the audience binding on refresh — see MCPOAuthCredentialBundle.resource.
        exchange: { bundle, metadata in
            try await MCPOAuthTokenExchange.refresh(
                bundle: bundle, metadata: metadata, resource: bundle.resource
            )
        },
        persist: { try persist($0, sourceID: $1) }
    )

    private static var refreshDependencies = liveRefreshDependencies

    /// Swaps the refresh collaborators. Test-only — pass nil to restore the live ones. Also drops
    /// any in-flight entry so one test's task cannot be joined by the next.
    static func setRefreshDependenciesForTesting(_ replacement: RefreshDependencies?) {
        refreshDependencies = replacement ?? liveRefreshDependencies
        inFlightRefreshes = [:]
    }

    /// Refreshes a stored bundle's access token, on a 401 or proactively near expiry; persists it before returning.
    /// Concurrent calls for one source coalesce (see `inFlightRefreshes`); a persist failure after rotation throws
    /// `rotatedRefreshTokenLost`.
    @discardableResult
    static func refresh(sourceID: UUID) async throws -> MCPOAuthCredentialBundle {
        if let inFlight = inFlightRefreshes[sourceID] {
            logger.info("""
                [MCP-OAUTH] A refresh is already in flight for source \(sourceID.uuidString); joining \
                it instead of presenting the same refresh token a second time. CONSEQUENCE: one token \
                exchange and one rotation — a replayed refresh token is what makes providers revoke \
                the whole grant.
                """)
            return try await inFlight.value
        }

        let task = Task { @MainActor in
            try await performRefresh(sourceID: sourceID)
        }
        inFlightRefreshes[sourceID] = task
        defer { inFlightRefreshes[sourceID] = nil }
        return try await task.value
    }

    private static func performRefresh(sourceID: UUID) async throws -> MCPOAuthCredentialBundle {
        let deps = refreshDependencies
        guard var bundle = deps.loadBundle(sourceID) else {
            throw MCPOAuthCoordinatorError.bundleNotFound
        }

        // Re-fetch metadata — endpoints can rotate, and the spec mandates
        // we honor the current document on every refresh.
        let metadata = try await deps.fetchMetadata(bundle.issuer)
        let tokens = try await deps.exchange(bundle, metadata)

        // Mutates only the fields the refresh changed; rebuilding the bundle would drop `resource` and widen the token
        // audience.
        bundle.accessToken = tokens.accessToken
        bundle.accessTokenExpiresAt = tokens.expiresAt
        bundle.grantedScopes = tokens.grantedScopes

        // Some servers rotate the refresh token on every refresh. When they don't, keep the
        // old one — a nil here means "unchanged", not "revoked".
        let rotated = tokens.refreshToken.map { $0 != bundle.refreshToken } ?? false
        if let newRefresh = tokens.refreshToken {
            bundle.refreshToken = newRefresh
        }

        // The write is retried once (Keychain prompts and locks are brief) and the rotation is logged only after it
        // succeeds; a final failure names the consequence.
        do {
            try persistWithOneRetry(bundle, sourceID: sourceID, persist: deps.persist)
        } catch {
            if rotated {
                logger.error("""
                    [MCP-OAUTH] Issuer \(bundle.issuer.absoluteString) rotated the refresh token \
                    for source \(sourceID.uuidString) and the new one could NOT be stored after two \
                    attempts (\(error.localizedDescription)). CONSEQUENCE: the grant is DEAD — the \
                    previous refresh token is already invalid at the provider and the replacement \
                    existed only in memory. Every later refresh for this server will fail with \
                    invalid_grant; the user must sign in to it again from its editor.
                    """)
                throw MCPOAuthCoordinatorError.rotatedRefreshTokenLost(
                    sourceID: sourceID, underlying: error.localizedDescription
                )
            }
            logger.error("""
                [MCP-OAUTH] Refreshed the access token for source \(sourceID.uuidString) but could \
                NOT store it after two attempts (\(error.localizedDescription)). CONSEQUENCE: the \
                stored bundle still holds the previous, expired access token, so the next call \
                refreshes again; the refresh token was not rotated and remains valid, so that retry \
                can succeed once the Keychain is writable.
                """)
            throw error
        }

        if rotated {
            logger.info("""
                [MCP-OAUTH] Issuer \(bundle.issuer.absoluteString) rotated the refresh token for \
                source \(sourceID.uuidString); the previous one is now dead at the provider and \
                the new one IS persisted.
                """)
        }
        logger.info("""
            [MCP-OAUTH] Refreshed OAuth tokens for source \(sourceID.uuidString) — \
            expires in \(Int(tokens.expiresAt.timeIntervalSinceNow))s, \
            scopes: \(bundle.grantedScopes.joined(separator: " ")), \
            audience binding: \(bundle.resource?.absoluteString ?? "none").
            """)
        return bundle
    }

    /// One immediate retry, not a loop: a locked Keychain stays locked, and a second failure should reach the caller
    /// quickly.
    private static func persistWithOneRetry(
        _ bundle: MCPOAuthCredentialBundle,
        sourceID: UUID,
        persist: @MainActor (MCPOAuthCredentialBundle, UUID) throws -> Void
    ) throws {
        do {
            try persist(bundle, sourceID)
        } catch {
            logger.warning("""
                [MCP-OAUTH] First attempt to store the refreshed tokens for source \
                \(sourceID.uuidString) failed (\(error.localizedDescription)); retrying once.
                """)
            try persist(bundle, sourceID)
        }
    }

    // MARK: - Bundle persistence

    /// Best-effort RFC 7009 revocation of a source's tokens, just before its secrets are purged; never throws.
    /// Revokes the refresh token first, then the access token. `bundle` is captured by the caller before purging, which
    /// would race a re-read.
    static func revokeTokens(sourceID: UUID, bundle: MCPOAuthCredentialBundle) async {
        // Deletes the dynamic client registration first (RFC 7592), best-effort and non-throwing; an AS without RFC 7592
        // answers 405.
        if let rat = bundle.registrationAccessToken, let uri = bundle.registrationClientUri {
            _ = await MCPOAuthTokenExchange.deleteRegistration(
                registrationClientUri: uri,
                registrationAccessToken: rat
            )
        }

        let metadata: MCPOAuthMetadata
        do {
            metadata = try await MCPOAuthDiscovery.fetch(issuer: bundle.issuer)
        } catch {
            logger.warning("""
                [MCP-OAUTH] Cannot revoke tokens for source \(sourceID.uuidString): metadata \
                fetch failed (\(error.localizedDescription)). Tokens may REMAIN VALID at \
                \(bundle.issuer.absoluteString) until they expire; local secrets are still purged.
                """)
            return
        }

        guard let revocationEndpoint = metadata.revocationEndpoint else {
            logger.info("""
                [MCP-OAUTH] Issuer \(bundle.issuer.absoluteString) advertises no revocation_endpoint \
                (RFC 7009) — tokens for source \(sourceID.uuidString) will remain valid there until \
                they expire. Nothing else to do; local secrets are purged.
                """)
            return
        }

        if let refreshToken = bundle.refreshToken {
            await MCPOAuthTokenExchange.revoke(
                token: refreshToken, tokenTypeHint: "refresh_token",
                clientId: bundle.clientId, revocationEndpoint: revocationEndpoint
            )
        }
        await MCPOAuthTokenExchange.revoke(
            token: bundle.accessToken, tokenTypeHint: "access_token",
            clientId: bundle.clientId, revocationEndpoint: revocationEndpoint
        )
    }

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
