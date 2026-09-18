// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPPKCE.swift
//  Devgentic
//
//  RFC 7636 / RFC 8252 PKCE helpers for the OAuth authorization-code flow.
//  PKCE replaces the client-secret in public clients (desktop, mobile) by
//  binding the auth-code exchange to a randomly-generated proof.
//
//  Flow:
//    1. Client generates `codeVerifier` (random URL-safe string, 43-128 chars)
//    2. Client computes `codeChallenge = base64url(SHA256(codeVerifier))`
//    3. Client sends `codeChallenge` + `codeChallengeMethod=S256` on /authorize
//    4. After redirect, client sends `codeVerifier` on /token
//    5. Server hashes verifier and matches against the original challenge
//

import Foundation
import CryptoKit

/// One PKCE pair, generated together. The `verifier` is the secret stays on
/// the client until the token-exchange POST; the `challenge` is what gets
/// embedded in the authorize URL and is safe to hand to the OS browser.
struct MCPPKCEPair: Sendable {

    /// Random URL-safe string, 43-128 characters per RFC 7636 §4.1.
    let verifier: String

    /// `base64url(SHA256(verifier))` — what we send to the authorization
    /// endpoint as `code_challenge`.
    let challenge: String

    /// Always `"S256"` for our use. `"plain"` exists in the spec but is
    /// deprecated and not supported by any modern provider.
    let challengeMethod: String = "S256"
}

enum MCPPKCE {

    /// Generates a fresh PKCE pair using a 64-byte cryptographically random
    /// verifier (= 86 base64url chars, well within the 43-128 RFC bound).
    /// Each call returns a new pair — never reuse a verifier across flows.
    static func generate() -> MCPPKCEPair {
        let verifier = randomURLSafeString(byteCount: 64)
        let challenge = challengeValue(for: verifier)
        return MCPPKCEPair(verifier: verifier, challenge: challenge)
    }

    /// Hashes a verifier into its S256 challenge form. Exposed so tests can
    /// pin a known verifier and assert against the expected challenge.
    static func challengeValue(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    // MARK: - Private

    /// Generates `byteCount` random bytes and base64url-encodes them. Uses
    /// `SecRandomCopyBytes` so the entropy comes from the system CSPRNG.
    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes).base64URLEncodedString()
    }
}

// MARK: - base64url helper

extension Data {
    /// RFC 4648 §5 base64url encoding: standard base64 with `+`→`-`, `/`→`_`,
    /// and trailing padding stripped. Required by RFC 7636 for PKCE.
    func base64URLEncodedString() -> String {
        var s = base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "=", with: "")
        return s
    }
}
