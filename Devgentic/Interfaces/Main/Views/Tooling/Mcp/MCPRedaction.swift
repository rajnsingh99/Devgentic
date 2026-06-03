//
//  MCPRedaction.swift
//  Devgentic
//
//  Best-effort redaction of secrets in strings that are about to hit the log
//  pipeline (Console.app, log files, crash reports). Heuristic-only — designed
//  to catch the obvious cases (CLI flags, KEY=VALUE pairs, HTTP-style auth
//  headers, URL userinfo and query params) without trying to be exhaustive.
//
//  Use at log boundaries only. Never use the redacted form for actual execution.
//

import Foundation

enum MCPRedaction {

    /// Sentinel substituted for any value identified as a secret.
    static let redactedPlaceholder = "<REDACTED>"

    /// Lowercased substrings that, when present in a flag, key, or header name,
    /// mark the associated value as sensitive. Conservative on purpose — we'd
    /// rather miss an exotic flag than redact something innocuous and confuse
    /// debugging.
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

    /// Returns a copy of `args` suitable for logging, with secret-looking values
    /// replaced. Three patterns are recognized:
    ///
    /// 1. The argument following a secret-named long flag, e.g. `--api-key X`.
    /// 2. `KEY=VALUE` (or `--flag=VALUE`) where the key name matches a secret token.
    /// 3. An HTTP-style header in a single arg, e.g. `Authorization: Bearer X`.
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

    /// Returns a copy of `url` suitable for logging. Strips userinfo
    /// (`user:pass@`) and replaces query-parameter values whose names look
    /// sensitive. Falls back to the original string if the URL can't be
    /// parsed — better to log a malformed URL than to fail silently and lose
    /// the diagnostic.
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

        return components.string ?? url
    }

    // MARK: - Heuristics

    /// True if `name` (case-insensitive) contains any of the secret name tokens.
    private static func isSecretName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return secretNameTokens.contains(where: lower.contains)
    }

    /// True for long flags (`--something`) whose name matches a secret token.
    /// Short flags (`-k`) are deliberately excluded — too ambiguous to redact
    /// without false positives, and most MCP servers use long flags anyway.
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
