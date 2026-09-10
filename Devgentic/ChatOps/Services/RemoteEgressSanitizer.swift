// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  RemoteEgressSanitizer.swift
//  Devgentic
//
//  What may leave this machine for a third-party chat service.
//
//  WHY THIS IS NOT JUST `TelemetrySanitizer.sanitize`. That defaults to `.standard`, which folds
//  home paths, IP addresses and email addresses as well as credentials. For a diagnostic bundle
//  that trade is right and the sanitizer's own header says so: over-redact rather than under.
//  For the agent's REPLY it is wrong, and destructively so — the user asked the agent about their
//  own files, and answering `[USER_PATH]/main.swift` turns a correct answer into a broken-looking
//  one. Redaction that damages the thing the user asked for teaches them to route around it.
//
//  ⚠️ SO THE LINE IS DRAWN AT INTENT, NOT AT SENSITIVITY. A home path is something the user knows
//  and asked about. An API key echoed out of a `.env` the agent happened to read is something they
//  never intended to transmit, and it reaches a third party that keeps it. The first stays; the
//  second never leaves.
//
//  ⚠️ THIS IS A FLOOR, NOT THE WHOLE POLICY. Content the user did NOT ask to transmit — error
//  details, diagnostics — is separately run through `TelemetrySanitizer.sanitize` at its producer,
//  because for that content the harsher trade is the right one. This floor exists so that nothing
//  can reach a chat service without at least the credential pass, whoever adds the next send path.
//

import Foundation

enum RemoteEgressSanitizer {

    /// Strips credentials and nothing else.
    ///
    /// ⚠️ Exactly the passes `TelemetrySanitizer.Level.standard` adds on top of `.minimal`, composed
    /// deliberately rather than by asking for a level — the level would drag the path/IP/email
    /// folding in with them. If `TelemetrySanitizer` grows a new credential pass, it belongs here
    /// too; that is a judgement a level cannot make for us.
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
