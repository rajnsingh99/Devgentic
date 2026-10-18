// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPOAuthCredentialBundle.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The single Codable artifact persisted to Keychain at `MCPSecretScope.oauthBundle` for an OAuth MCP source.
/// Carries what is needed to attach the bearer token, detect expiry and refresh; one item keeps updates atomic.
struct MCPOAuthCredentialBundle: Codable, Hashable, Sendable {

    /// Issuer URL the tokens belong to. Pinned so we can detect later
    /// "issuer rotated" errors and force a re-auth instead of silently
    /// accepting tokens from an unexpected AS.
    let issuer: URL

    /// `client_id` returned by RFC 7591 dynamic client registration. Used
    /// on every refresh request.
    let clientId: String

    /// Set of scopes that were granted, possibly a subset of those requested.
    /// A `var` because a refresh can return a different set; refresh mutates changed fields rather than rebuilding the
    /// bundle.
    var grantedScopes: [String]

    /// Loopback (or custom-scheme) redirect URI used for this client. Stored
    /// because it has to match exactly on every authorize and refresh call.
    let redirectURI: URL

    /// REQUIRED. Bearer token attached to MCP requests.
    var accessToken: String

    /// OPTIONAL. Some servers don't issue refresh tokens (or only on first
    /// auth). When nil, expiry triggers a full re-auth instead of refresh.
    var refreshToken: String?

    /// Required. Wall-clock time when the access token expires.
    /// Stored as an absolute `Date`, computed from the token endpoint's `expires_in`.
    var accessTokenExpiresAt: Date

    /// OPTIONAL. RFC 7592 registration-management credentials. Stashed so a
    /// later "remove server" can revoke the registration if the server
    /// supports it.
    let registrationAccessToken: String?
    let registrationClientUri: URL?

    /// Optional (RFC 8707). The MCP server URL these tokens were bound to.
    /// Stored so refresh repeats the same `resource`; optional so older bundles without an audience binding keep
    /// decoding.
    var resource: URL? = nil

    /// Optional. The MCP server URL the sign-in was performed for, used by the local binding check.
    /// Distinct from `resource` (the requested audience); `MCPOAuthBinding` enforces it. Legacy bundles carry none.
    var serverURL: URL? = nil

    /// True when the access token is past expiry (or within a 30-second
    /// safety margin to absorb clock skew + network round-trip).
    func isAccessTokenExpired(now: Date = Date(), safetyMargin: TimeInterval = 30) -> Bool {
        return accessTokenExpiresAt <= now.addingTimeInterval(safetyMargin)
    }

    /// True when the access token is *near* expiry — used by the proactive
    /// refresh-on-launch path. Default 5 minutes matches the design spec.
    func isAccessTokenNearExpiry(now: Date = Date(), within: TimeInterval = 300) -> Bool {
        return accessTokenExpiresAt <= now.addingTimeInterval(within)
    }
}

/// Local enforcement of the invariant that an OAuth bundle is attached only to the MCP server URL it was issued for.
/// `shouldAttach`, `isProvablyMisbound` and `editDecision` (the fail-closed form gate) all call these so the rule
/// cannot drift.
enum MCPOAuthBinding {

    /// Normalizes a URL to the key this invariant compares on: scheme and host case-insensitive, one trailing slash
    /// folded, explicit port kept.
    /// Path case is preserved; a nil port and an explicit default port normalize differently, which fails closed.
    static func normalizedServerKey(_ url: URL) -> String {
        var path = url.path
        if path == "/" {
            path = ""
        } else if path.hasSuffix("/") {
            path.removeLast()
        }
        return (url.scheme.map { $0.lowercased() + "://" } ?? "")
            + (url.host.map { $0.lowercased() } ?? "")
            + (url.port.map { ":\($0)" } ?? "")
            + path
    }

    /// Whether `bundle`'s token may be attached to requests for `serverURLString`.
    /// A nil or unparseable target with a bound bundle is a refusal; a legacy bundle (`serverURL == nil`) attaches.
    static func shouldAttach(_ bundle: MCPOAuthCredentialBundle, to serverURLString: String?) -> Bool {
        guard let bound = bundle.serverURL else { return true }
        guard let target = serverURLString.flatMap(URL.init(string:)) else { return false }
        return normalizedServerKey(bound) == normalizedServerKey(target)
    }

    /// Whether a stored bundle is PROVABLY bound to a different server than `serverURLString`.
    /// True only when the bundle decodes, carries a binding, the target parses, and the two
    /// normalized keys differ — every other outcome is `false` (keep the credential).
    static func isProvablyMisbound(storedJSON: String, serverURLString: String?) -> Bool {
        guard let data = storedJSON.data(using: .utf8),
              let stored = try? JSONDecoder().decode(MCPOAuthCredentialBundle.self, from: data),
              let bound = stored.serverURL,
              let target = serverURLString.flatMap(URL.init(string:)) else { return false }
        return normalizedServerKey(bound) != normalizedServerKey(target)
    }

    /// What a save should do about the OAuth binding. See `editDecision`.
    enum EditDecision: Equatable {
        case proceed
        case requiresReAuth(MCPUserError)
    }

    /// The form gate for add and edit: the bundle in effect after the save must be bound to `newURL`.
    /// A fresh sign-in wins and must itself be bound to `newURL`; otherwise `storedRead` decides, failing closed on
    /// read failure, undecodable JSON and a legacy bundle whose URL changed.
    static func editDecision(
        isOAuth: Bool,
        newURL: String?,
        previousURL: String?,
        freshBundle: MCPOAuthCredentialBundle?,
        storedRead: KeychainReadOutcome
    ) -> EditDecision {
        guard isOAuth else { return .proceed }

        func refusal() -> EditDecision {
            .requiresReAuth(MCPUserError(
                title: "Sign in again for this URL",
                message: "The stored OAuth sign-in was made for a different server URL. Saving would send that server's token to the URL in this form.",
                suggestion: "Press Sign In again while this form holds the new URL — a fresh sign-in binds its tokens to what is in the field at the moment you sign in.",
                rawLog: nil
            ))
        }

        // nil = binding unknown (refuse on change); .some(nil) = legacy unbound;
        // .some(.some(url)) = bound.
        let effectiveBinding: URL??
        if let fresh = freshBundle {
            effectiveBinding = .some(fresh.serverURL)
        } else {
            switch storedRead {
            case .notFound:
                return .proceed
            case .failed:
                return refusal()
            case .found(let json):
                guard let data = json.data(using: .utf8),
                      let stored = try? JSONDecoder().decode(MCPOAuthCredentialBundle.self, from: data) else {
                    return refusal()
                }
                effectiveBinding = .some(stored.serverURL)
            }
        }

        guard let bound = effectiveBinding else { return refusal() }

        // A legacy (unbound) bundle may stay only while the URL is untouched — and "untouched"
        // must be provable. An unknown previous URL (undecodable blob) cannot prove it.
        guard let bound else {
            guard let previous = previousURL,
                  let new = newURL,
                  let previousURLValue = URL(string: previous),
                  let newURLValue = URL(string: new),
                  normalizedServerKey(previousURLValue) == normalizedServerKey(newURLValue) else {
                return refusal()
            }
            return .proceed
        }

        guard let new = newURL.flatMap(URL.init(string:)) else { return refusal() }
        return normalizedServerKey(bound) == normalizedServerKey(new) ? .proceed : refusal()
    }
}
