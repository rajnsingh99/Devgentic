// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPRedaction.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Best-effort, heuristic redaction of secrets in strings about to reach the log pipeline (CLI flags, KEY=VALUE
/// pairs, auth headers, URL userinfo and query params). Use at log boundaries only; never use the redacted form for
/// execution.
enum MCPRedaction {

    /// Sentinel substituted for any value identified as a secret.
    static let redactedPlaceholder = "<REDACTED>"

    /// Lowercased substrings that mark a flag, key or header name as sensitive. Conservative on purpose: missing an
    /// exotic flag is better than redacting something innocuous.
    private static let secretNameTokens: Set<String> = [
        "key", "token", "secret", "password", "passwd",
        "auth", "credential", "creds", "bearer", "apikey"
    ]

    /// HTTP header names whose value is always sensitive, regardless of the
    /// generic token rules above.
    private static let secretHeaderNames: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key"
    ]

    // MARK: - Public API

    /// Returns a copy of `args` suitable for logging, with secret-looking values replaced. Recognizes the argument after
    /// a secret-named long flag, `KEY=VALUE` (or `--flag=VALUE`) pairs, and single-arg HTTP-style headers.
    static func redact(arguments args: [String]) -> [String] {
        var result: [String] = []
        result.reserveCapacity(args.count)

        var i = 0
        while i < args.count {
            let curr = args[i]
            let prev = i > 0 ? args[i - 1] : nil

            // Pattern 1: previous arg is a secret-named long flag → redact this value.
            if let prev = prev, isSecretLongFlag(prev) {
                result.append(redactedPlaceholder)
                i += 1
                continue
            }

            // Pattern 2: `KEY=VALUE` or `--flag=VALUE`.
            if let eqIdx = curr.firstIndex(of: "="),
               eqIdx != curr.startIndex {
                let keyPart = String(curr[..<eqIdx])
                let stripped = keyPart.drop(while: { $0 == "-" })
                if isSecretName(String(stripped)) {
                    result.append("\(keyPart)=\(redactedPlaceholder)")
                    i += 1
                    continue
                }
            }

            // Pattern 3: `Header-Name: value`.
            if let colonIdx = curr.firstIndex(of: ":"),
               colonIdx != curr.startIndex {
                let headerName = curr[..<colonIdx].trimmingCharacters(in: .whitespaces)
                if isSecretHeader(headerName) {
                    result.append("\(headerName): \(redactedPlaceholder)")
                    i += 1
                    continue
                }
            }

            result.append(curr)
            i += 1
        }

        return result
    }

    /// Returns a copy of `url` suitable for logging, stripping userinfo and replacing query-parameter values whose names
    /// look sensitive. Falls back to the original string if the URL cannot be parsed.
    static func redact(url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }

        if components.user != nil || components.password != nil {
            components.user = nil
            components.password = nil
        }

        if let items = components.queryItems {
            components.queryItems = items.map { item in
                isSecretName(item.name)
                    ? URLQueryItem(name: item.name, value: redactedPlaceholder)
                    : item
            }
        }

        components.path = redactSecretPathSegments(components.path)

        return components.string ?? url
    }

    /// Replaces path segments that look like credentials, such as the key in
    /// `https://mcp.example.com/v1/sk-live-abc123.../sse`. Structural: a segment is suspicious when it has a known token
    /// prefix or is long and high-entropy; ordinary segments stay readable.
    private static func redactSecretPathSegments(_ path: String) -> String {
        guard !path.isEmpty else { return path }

        let knownTokenPrefixes = ["sk-", "pk-", "tok-", "key-", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-"]

        return path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment -> String in
                let value = String(segment)
                guard !value.isEmpty else { return value }

                let lower = value.lowercased()
                if knownTokenPrefixes.contains(where: lower.hasPrefix) {
                    return redactedPlaceholder
                }
                return looksLikeHighEntropySecret(value) ? redactedPlaceholder : value
            }
            .joined(separator: "/")
    }

    /// A long, mixed-character, non-word-like blob — UUIDs, base64url keys, hex digests.
    /// The 24-char floor keeps normal path words (and short IDs a user may need to see)
    /// out of scope; a real API key clears it comfortably.
    private static func looksLikeHighEntropySecret(_ value: String) -> Bool {
        guard value.count >= 24 else { return false }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return false }

        let hasDigit = value.contains(where: \.isNumber)
        let hasLetter = value.contains(where: \.isLetter)
        // A long run of only letters is far more likely a slug than a secret.
        return hasDigit && hasLetter
    }

    /// Redacts secrets in free text such as child-process stderr and error messages, where `redact(url:)` cannot parse
    /// the input. Handles, in order: well-known token prefixes, `Header: value` auth lines, `KEY=VALUE` assignments and
    /// `"key": "value"` JSON.
    static func redact(text: String) -> String {
        var result = text

        // 1. Well-known token literals, wherever they appear.
        let tokenLiteral = "(sk-|pk-|tok-|ghp_|gho_|ghu_|ghs_|github_pat_|xoxb-|xoxp-|xapp-|AKIA)[A-Za-z0-9_\\-]{8,}"
        result = replacing(pattern: tokenLiteral, in: result, with: redactedPlaceholder)

        // `Authorization: Bearer xyz`, `X-API-Key: xyz` and similar keep the header name. Consumes to the end of the line,
        // since `\S+` would stop after `Bearer` and leave the token.
        let headerAssignment = "(?i)\\b(authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key)\\s*:\\s*.+"
        result = replacing(pattern: headerAssignment, in: result, with: "$1: \(redactedPlaceholder)")

        // 3. `SOMETHING_TOKEN=value` / `--api-key=value`. Keep the name.
        let envAssignment = "(?i)([A-Za-z0-9_\\-\\.]*(key|token|secret|password|passwd|credential|creds|bearer)[A-Za-z0-9_\\-\\.]*)\\s*=\\s*\\S+"
        result = replacing(pattern: envAssignment, in: result, with: "$1=\(redactedPlaceholder)")

        // 4. `"apiKey": "value"` in embedded JSON. Keep the key.
        let jsonAssignment = "(?i)(\"[A-Za-z0-9_\\-\\.]*(?:key|token|secret|password|credential|bearer)[A-Za-z0-9_\\-\\.]*\"\\s*:\\s*)\"[^\"]*\""
        result = replacing(pattern: jsonAssignment, in: result, with: "$1\"\(redactedPlaceholder)\"")

        return result
    }

    private static func replacing(pattern: String, in input: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: template)
    }

    // MARK: - Heuristics

    /// True if `name` (case-insensitive) contains any of the secret name tokens.
    private static func isSecretName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return secretNameTokens.contains(where: lower.contains)
    }

    /// True for long flags (`--something`) whose name matches a secret token; short flags are excluded as too ambiguous.
    private static func isSecretLongFlag(_ arg: String) -> Bool {
        guard arg.hasPrefix("--") else { return false }
        let name = arg.dropFirst(2).split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
        return isSecretName(name)
    }

    /// True if the header name (case-insensitive) is in the always-secret set
    /// or matches the generic secret-name heuristic.
    private static func isSecretHeader(_ name: String) -> Bool {
        let lower = name.lowercased()
        if secretHeaderNames.contains(lower) { return true }
        return isSecretName(lower)
    }
}
