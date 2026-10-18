// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TelemetrySanitizer.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// A privacy firewall that strips sensitive data from strings before telemetry egress.
/// Use `sanitize(_:)` for basic sanitization (paths/IPs/emails — original behavior).
/// Use `sanitizeFull(_:level:)` when handling strings that may contain secrets.
struct TelemetrySanitizer {

    // MARK: - Levels

    /// Redaction intensity for `sanitizeFull(_:level:)`.
    enum Level {
        /// Home paths, IPs, emails only. Original `sanitize(_:)` behavior.
        case minimal
        /// `minimal` + API keys, bearer tokens, URL creds, JSON key redaction, env vars.
        case standard
        /// `standard` + hostname redaction + aggressive JSON value redaction for any
        /// key containing "key", "token", "secret", "password", "credential".
        case strict
    }

    // MARK: - Public API

    // Why: this short name is used wherever trace content is recorded, so a weaker default would leak secrets
    // into `span_events.detailJSON`, which ships in the diagnostic bundle.
    /// Default sanitization: full `.standard` redaction, including API-key, bearer and JSON-secret scrubbing.
    /// Callers wanting less must say `sanitizeFull(_, level: .minimal)` explicitly.
    static func sanitize(_ text: String) -> String {
        sanitizeFull(text, level: .standard)
    }

    /// Full sanitization at the requested level. Safe to call on any string.
    /// Empty input returns empty; nil-like inputs pass through unchanged.
    static func sanitizeFull(_ text: String, level: Level = .standard) -> String {
        var s = text

        s = sanitizeHomePath(s)
        s = sanitizeIP(s)
        s = sanitizeEmail(s)

        if level == .standard || level == .strict {
            s = sanitizeAPIKey(s)
            s = sanitizeBearerToken(s)
            s = sanitizeURLCredentials(s)
            s = sanitizeJSONKeys(s, keysToRedact: Self.standardSecretKeys)
            s = sanitizeEnvVars(s)
        }

        if level == .strict {
            s = sanitizeJSONKeys(s, keysToRedact: Self.strictSecretKeys)
        }

        return s
    }

    // MARK: - Individual patterns (each safe to call standalone)

    // Why: the username class excludes prose delimiters (whitespace, quotes, backtick, brackets, comma, semicolon)
    // instead of `[^/]+`, which swallows prose, or an allowlist, which under-redacts names like `josé`.
    /// Replaces macOS/Linux home-dir prefixes with a placeholder, preserving the tail.
    /// `/Users/alice/Documents/foo.swift` → `/[USER_PATH]/Documents/foo.swift`
    static func sanitizeHomePath(_ text: String) -> String {
        replace(text, pattern: "(\\/)(?:Users|home)\\/[^\\/\\s\"'`(),;]+", with: "$1[USER_PATH]")
    }

    /// Replaces IP addresses (v4 and v6) with `[IP_ADDR]`.
    /// IPv6 matches the full 8-group form and any `::`-compressed form, so timestamps like "12:30:45" survive.
    static func sanitizeIP(_ text: String) -> String {
        var s = text
        s = replace(s, pattern: "\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b", with: "[IP_ADDR]")
        // Full 8-group IPv6.
        s = replace(s, pattern: "\\b(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}\\b", with: "[IP_ADDR]")
        // ::-compressed IPv6 (fe80::1, 2001:db8::, a:b::c). Requires the double colon.
        s = replace(s, pattern: "\\b(?:[0-9A-Fa-f]{1,4}:){1,6}:(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,5})?\\b", with: "[IP_ADDR]")
        return s
    }

    /// Replaces email addresses with `[EMAIL]`.
    static func sanitizeEmail(_ text: String) -> String {
        replace(text, pattern: "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}", with: "[EMAIL]")
    }

    /// Redacts provider API keys, vendor-prefixed so diagnostics can still say which provider leaked.
    /// Covers OpenAI, HuggingFace, GitHub, GitLab, AWS, Slack, Telegram and Discord token formats.
    /// Every pattern is `\b`-anchored so hyphenated prose such as "risk-…" is not bitten.
    static func sanitizeAPIKey(_ text: String) -> String {
        var s = text
        // Anthropic first (most specific), then the general `sk-` form, which admits hyphens and underscores.
        // It cannot re-match the replaced `sk-ant-[API_KEY]` because `[` ends the character class.
        s = replace(s, pattern: "\\bsk-ant-[A-Za-z0-9\\-_]{20,}",   with: "sk-ant-[API_KEY]")
        s = replace(s, pattern: "\\bsk-[A-Za-z0-9\\-_]{20,}",       with: "sk-[API_KEY]")
        // HuggingFace user access tokens (the Hub this app downloads models from).
        s = replace(s, pattern: "\\bhf_[A-Za-z0-9]{20,}",           with: "hf_[API_KEY]")
        // GitHub: fine-grained github_pat_ (allows underscores) before the short family —
        // classic PAT ghp_, OAuth gho_, server/user-to-server ghs_/ghu_, refresh ghr_.
        s = replace(s, pattern: "\\bgithub_pat_[A-Za-z0-9_]{20,}",  with: "github_pat_[API_KEY]")
        s = replace(s, pattern: "\\bgh[posur]_[A-Za-z0-9]{20,}",    with: "gh_[API_KEY]")
        // GitLab personal access tokens.
        s = replace(s, pattern: "\\bglpat-[A-Za-z0-9\\-_]{20,}",    with: "glpat-[API_KEY]")
        // AWS access key IDs (AKIA long-lived, ASIA temporary). The 40-char secret is not matched bare (it would eat base64)
        // and is covered contextually by `sanitizeEnvVars` and `sanitizeJSONKeys`.
        s = replace(s, pattern: "\\b(?:AKIA|ASIA)[0-9A-Z]{16}\\b",  with: "AKIA[API_KEY]")
        // Slack: the whole xox?- family (bot/user/app-config), plus app-level xapp- tokens —
        // this app's SlackTransport / SlackSocketClient hold both kinds.
        s = replace(s, pattern: "\\bxox[a-z]-[A-Za-z0-9\\-]{10,}",  with: "xox-[API_KEY]")
        s = replace(s, pattern: "\\bxapp-[A-Za-z0-9\\-]{10,}",      with: "xapp-[API_KEY]")
        // Telegram bot tokens (TelegramTransport): "123456789:AA…", 30+ chars after the colon.
        s = replace(s, pattern: "\\b[0-9]{8,10}:AA[A-Za-z0-9_\\-]{30,}", with: "[TELEGRAM_TOKEN]")
        // Discord bot tokens (DiscordTransport): three dot-joined base64url segments.
        s = replace(s, pattern: "\\b[MNO][A-Za-z0-9_\\-]{22,}\\.[A-Za-z0-9_\\-]{6}\\.[A-Za-z0-9_\\-]{25,}", with: "[DISCORD_TOKEN]")
        // Google API keys.
        s = replace(s, pattern: "\\bAIza[A-Za-z0-9\\-_]{20,}",      with: "AIza[API_KEY]")
        // Long hex strings (OpenAI org IDs, some API keys); 40+ chars to spare legitimate IDs.
        // This also catches full git SHAs, which is accepted: the contract is to over-redact.
        s = replace(s, pattern: "\\b[a-fA-F0-9]{40,}\\b",           with: "[API_KEY_HEX]")
        // Bare JWTs: `sanitizeBearerToken` needs a `Bearer ` prefix, so a token in a 401 body or cookie would be missed.
        // `eyJ` is the base64url of `{"`, which every JWT header starts with; the format is three dot-joined segments.
        s = replace(s, pattern: "\\beyJ[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,}", with: "[JWT]")
        // PEM private keys are matched as a block, non-greedy so two keys redact as two blocks
        // rather than one span swallowing everything between them.
        s = replace(s,
                    pattern: "-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----",
                    with: "[PRIVATE_KEY]")
        return s
    }

    /// Redacts `Authorization: Bearer <token>` headers.
    static func sanitizeBearerToken(_ text: String) -> String {
        replace(text,
                pattern: "(?i)(Bearer\\s+)[A-Za-z0-9\\._\\-]{16,}",
                with: "$1[TOKEN]")
    }

    /// Redacts URL basic-auth credentials: `https://user:pass@host` → `https://[CREDS]@host`
    static func sanitizeURLCredentials(_ text: String) -> String {
        replace(text,
                // Matches any URI scheme (postgres, mongodb, redis...), kept as `$1`; requires `user:pass@`, so prose is safe.
                // The username is optional (`redis://:pass@host` has none); the password is required, else there is no credential.
                pattern: "([A-Za-z][A-Za-z0-9+.\\-]*)://[^/\\s:@]*:[^/\\s@]+@",
                with: "$1://[CREDS]@")
    }

    /// For any JSON-encoded string, replaces the VALUE associated with known sensitive
    /// keys with `[REDACTED]`. Only matches when the key appears in quoted-key form
    /// (e.g., `"apiKey": "sk-abc..."` — not bare identifiers).
    static func sanitizeJSONKeys(_ text: String, keysToRedact: [String]) -> String {
        var s = text
        for key in keysToRedact {
            // Match: "key": "value"   OR   "key":"value"   (any whitespace/newlines)
            // Preserves the key + structure, replaces just the value.
            let escaped = NSRegularExpression.escapedPattern(for: key)
            s = replace(s,
                        pattern: "(\"\(escaped)\"\\s*:\\s*)\"[^\"]*\"",
                        with: "$1\"[REDACTED]\"",
                        caseInsensitive: true)
            // Also matches the escaped form, i.e. JSON serialized inside a JSON string (every logged tool-call argument),
            // which the plain-form pattern above cannot see because every quote is preceded by a backslash.
            s = replace(s,
                        pattern: "(\\\\\"\(escaped)\\\\\"\\s*:\\s*\\\\\")[^\"\\\\]*(\\\\\")",
                        with: "$1[REDACTED]$2",
                        caseInsensitive: true)
        }
        return s
    }

    /// Redacts shell `export KEY=value` assignments and `KEY=value` patterns that look
    /// like they carry secrets. Conservative — only matches when the key name contains
    /// a sensitive word.
    static func sanitizeEnvVars(_ text: String) -> String {
        // Match `(export )KEY=value` where KEY contains one of the sensitive substrings.
        // Value runs to whitespace/end. Preserve key + `=` prefix.
        replace(text,
                pattern: "(?i)((?:export\\s+)?(?:[A-Z_][A-Z0-9_]*(?:TOKEN|KEY|SECRET|PASSWORD|PASS|CREDENTIAL|API)[A-Z0-9_]*)\\s*=\\s*)[^\\s\"']+",
                with: "$1[REDACTED]")
    }

    // MARK: - Sensitive key dictionaries

    /// Keys whose values are always secret; redacted in `.standard` and `.strict` levels.
    /// Also read by `RemoteEgressSanitizer` (credential passes without a `Level`), so adding a key here strengthens both.
    static let standardSecretKeysForEgress: [String] = standardSecretKeys

    private static let standardSecretKeys: [String] = [
        "apiKey", "api_key", "API_KEY",
        "password", "passwd", "pwd",
        "token", "accessToken", "access_token", "refreshToken", "refresh_token",
        "secret", "clientSecret", "client_secret",
        "authorization", "auth",
        "credentials",
        "botToken", "bot_token",
        "appToken", "app_token",
        "sessionToken", "session_token",
        "privateKey", "private_key"
    ]

    /// Additional keys that might carry sensitive data. Redacted only at `.strict` level.
    private static let strictSecretKeys: [String] = [
        "email", "username", "userId", "user_id",
        "chatID", "chat_id", "channelID", "channel_id", "guildID", "guild_id",
        "webhookURL", "webhook_url"
    ]

    // MARK: - Regex helper

    /// Compiled-regex cache: each (pattern, options) pair compiles once instead of on every `replace` call.
    /// `NSRegularExpression` matching and `NSCache` are both thread-safe, so concurrent sanitize calls are fine.
    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    private static func cachedRegex(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression? {
        let key = ((caseInsensitive ? "i|" : "s|") + pattern) as NSString
        if let cached = regexCache.object(forKey: key) { return cached }
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        regexCache.setObject(regex, forKey: key)
        return regex
    }

    /// Executes a regex replace. Returns the original string on regex-compile failure
    /// so a bad pattern never corrupts sanitization output.
    private static func replace(_ text: String,
                                pattern: String,
                                with template: String,
                                caseInsensitive: Bool = false) -> String {
        guard let regex = cachedRegex(pattern, caseInsensitive: caseInsensitive) else {
            return text
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
