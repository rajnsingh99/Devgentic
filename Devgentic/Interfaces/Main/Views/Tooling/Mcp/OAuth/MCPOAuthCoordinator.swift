// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    /// Register KC-4. The provider rotated the refresh token and the replacement could not be
    /// stored, so the grant is dead: the previous refresh token is already invalid at the provider
    /// and the new one existed only in memory.
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
        // RFC 8707 resource indicator — binds the issued token's audience to THIS MCP
        // server. Without it the AS mints a general-purpose token, so a malicious or
        // compromised MCP server could replay a token obtained for it against any other
        // resource that trusts the same issuer (the token-passthrough problem the MCP
        // auth spec calls out). Servers that do not implement RFC 8707 ignore the
        // parameter, so sending it is safe with older ASes.
        if let resource {
            existing.append(URLQueryItem(name: "resource", value: resource.absoluteString))
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
    /// - Parameter resource: the MCP server URL these tokens are for (RFC 8707). Binds the
    ///   issued token's audience to that one server, so it cannot be replayed against
    ///   another resource trusting the same issuer. Nil only when the caller genuinely has
    ///   no resource URL (a stdio server), in which case no binding is requested.
    static func performInitialAuthorization(
        issuer: URL,
        scopes: [String],
        redirectURI: URL,
        redirectHandler: MCPOAuthRedirectHandler,
        clientName: String = "Devgentic",
        resource: URL? = nil
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
            resource: resource
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
        resource: URL? = nil
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
            resource: resource
        )
    }

    // MARK: - Refresh

    /// Refreshes in flight, keyed on source. Register KC-3.
    ///
    /// ⚠️⚠️ `@MainActor` DOES NOT SERIALIZE `refresh`. It suspends at two awaits — the metadata
    /// fetch and the token POST — and the actor is free in between. Two tool calls in one turn both
    /// reached `loadBundle` before either persisted, both read the same refresh token, and both
    /// POSTed it. The first exchange rotated it; the second presented a token the provider had just
    /// retired, and any AS implementing RFC 6819 §5.2.2.3 reuse detection (Auth0, Okta, Entra —
    /// OAuth 2.1 recommends rotation by default) treats a replayed refresh token as theft and
    /// REVOKES THE WHOLE GRANT FAMILY. A permanent lockout from an ordinary two-tool-call turn.
    ///
    /// Same shape as `MCPClientService.connectionTasks`: a second caller joins the in-flight task
    /// instead of starting a second exchange. The task is unstructured on purpose — a rotation must
    /// run to completion even when the caller that started it is cancelled, because abandoning it
    /// after the POST leaves the new token unpersisted (KC-4's failure by another route).
    private static var inFlightRefreshes: [UUID: Task<MCPOAuthCredentialBundle, Error>] = [:]

    /// The collaborators `refresh` needs, so the single-flight and the rotation-safe persist are
    /// testable without a network or a Keychain. ⚠️ TEST SEAM — production never reassigns these.
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

    /// Refresh a stored bundle's access token. Used reactively (on 401) and
    /// proactively (on launch when within 5 min of expiry). Returns the
    /// updated bundle; persists it before returning so callers don't have
    /// to remember to write back.
    ///
    /// Concurrent calls for one source coalesce onto a single exchange — see
    /// `inFlightRefreshes`. A persist failure after the provider rotated the
    /// refresh token throws `rotatedRefreshTokenLost`, which says what actually
    /// happened rather than "refresh failed".
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

        // MUTATE the fields the refresh actually changed. This branch used to REBUILD the
        // bundle from scratch whenever the server rotated the refresh token — and a rebuild
        // is a full re-listing of every field, so `resource` (the RFC 8707 audience binding)
        // was silently dropped. Rotation is not an edge case: OAuth 2.1 recommends it and
        // most modern providers do it, so the binding disappeared on the FIRST refresh and
        // every token minted afterwards widened back to a general-purpose audience — exactly
        // the token-passthrough problem the resource indicator was threaded end-to-end to
        // prevent, and invisible because the tokens keep working.
        bundle.accessToken = tokens.accessToken
        bundle.accessTokenExpiresAt = tokens.expiresAt
        bundle.grantedScopes = tokens.grantedScopes

        // Some servers rotate the refresh token on every refresh. When they don't, keep the
        // old one — a nil here means "unchanged", not "revoked".
        let rotated = tokens.refreshToken.map { $0 != bundle.refreshToken } ?? false
        if let newRefresh = tokens.refreshToken {
            bundle.refreshToken = newRefresh
        }

        // ⚠️ Register KC-4. The rotation used to be logged as persisted ONE LINE BEFORE the write
        // that can fail, and when it failed the new refresh token unwound with this frame while the
        // previous one was already dead at the provider: every later refresh returned
        // `invalid_grant`, forever, and the log said the opposite. The write is retried once (the
        // ordinary causes — a Keychain prompt mid-answer, a transient lock — are brief), the
        // rotation line now FOLLOWS the successful write, and a final failure names the real
        // consequence instead of "refresh failed".
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

    /// One immediate retry. ⚠️ Not a loop: a locked Keychain stays locked, and a second failure
    /// should reach the caller quickly with the real consequence rather than stall a tool call
    /// behind more attempts.
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

    /// Read the stored bundle for a source. Returns nil when absent or when
    /// the stored blob can't be decoded (e.g. shape changed across versions).
    /// Best-effort RFC 7009 revocation of a source's tokens, for use just before its
    /// secrets are purged.
    ///
    /// Deleting a server used to only make Devgentic FORGET the tokens — they stayed
    /// valid at the provider until natural expiry, so a user removing a server they no
    /// longer trusted had not actually withdrawn its access. Revoke the refresh token
    /// first (revoking it invalidates the whole grant at most providers), then the access
    /// token. Never throws: removing a server must succeed even when the provider is
    /// unreachable or does not implement revocation.
    /// - Parameter bundle: captured by the CALLER before purging Keychain. Re-reading it
    ///   here would race `MCPSecretStore.purgeAll`, which runs synchronously on the delete
    ///   path and would leave this with nothing to revoke.
    static func revokeTokens(sourceID: UUID, bundle: MCPOAuthCredentialBundle) async {
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
