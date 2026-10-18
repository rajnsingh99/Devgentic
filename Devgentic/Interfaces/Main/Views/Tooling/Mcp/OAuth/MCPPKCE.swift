// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPPKCE.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import CryptoKit

/// One PKCE pair, generated together. The `verifier` is the secret stays on
/// the client until the token-exchange POST; the `challenge` is what gets
/// embedded in the authorize URL and is safe to hand to the OS browser.
struct MCPPKCEPair: Sendable {

    /// A random URL-safe string of 43-128 characters, per RFC 7636 section 4.1.
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
    /// RFC 4648 section 5 base64url encoding: standard base64 with `+` to `-`, `/` to `_` and padding
    /// stripped, as PKCE requires.
    func base64URLEncodedString() -> String {
        var s = base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "=", with: "")
        return s
    }
}
