// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteEgressSanitizer.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// What may leave this machine for a third-party chat service: credentials are stripped, the user's own paths are kept.
/// A floor, not the whole policy: content the user did not ask to transmit (errors, diagnostics) is sanitized harder
/// at its producer via `TelemetrySanitizer.sanitize`.
enum RemoteEgressSanitizer {

    /// Strips credentials and nothing else.
    /// Composes exactly the passes `TelemetrySanitizer.Level.standard` adds over `.minimal`, minus path/IP/email folding.
    /// A credential pass added to `TelemetrySanitizer` as a new function must be added here by hand.
    static func credentialsOnly(_ text: String) -> String {
        var out = text
        out = TelemetrySanitizer.sanitizeAPIKey(out)
        out = TelemetrySanitizer.sanitizeBearerToken(out)
        out = TelemetrySanitizer.sanitizeURLCredentials(out)
        out = TelemetrySanitizer.sanitizeJSONKeys(out, keysToRedact: TelemetrySanitizer.standardSecretKeysForEgress)
        out = TelemetrySanitizer.sanitizeEnvVars(out)
        return out
    }

    /// Optional-preserving convenience, so a walk over a value type stays readable.
    static func credentialsOnly(_ text: String?) -> String? {
        text.map(credentialsOnly)
    }
}
