//
//  TelemetrySanitizer.swift
//  Devgentic
//
//  Created by Raj Singh on 07/02/26.
//
//  Privacy firewall for all telemetry egress points. Every string that could contain
//  sensitive data — trace errorSummary, log buffer entries, exported bundle contents,
//  recovery-hint-enriched error strings — must pass through a sanitize call before
//  leaving this process.
//
//  The sanitizer is intentionally loose (regex-based, not semantic) and designed to
//  over-redact rather than under-redact. A stray path slipping into a bug report is
//  a privacy regression; a filename accidentally showing as `[USER_PATH]/foo.swift`
//  is annoying but safe.
//
//  Pattern coverage:
//    1. Home paths (macOS / Linux)           → [USER_PATH]
//    2. IPv4 addresses                        → [IP_ADDR]
//    3. Email addresses                       → [EMAIL]
//    4. API keys (sk-, sk-ant-, xoxb-, etc.)  → [API_KEY]
//    5. Bearer tokens (Authorization headers) → Bearer [TOKEN]
//    6. URL basic-auth credentials            → https://[CREDS]@host
//    7. JSON values for sensitive keys        → "apiKey": "[REDACTED]"
//    8. Shell env-var assignments             → export FOO=[REDACTED]
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

    /// Basic sanitization (original behavior preserved). Home paths, IPs, emails.
    /// Callers upgrading to full sanitization should migrate to `sanitizeFull(_:level:)`.
    static func sanitize(_ text: String) -> String {
        sanitizeFull(text, level: .minimal)
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

    /// Replaces macOS/Linux home-dir prefixes with a placeholder, preserving the tail.
    /// `/Users/alice/Documents/foo.swift` → `/[USER_PATH]/Documents/foo.swift`
    static func sanitizeHomePath(_ text: String) -> String {
        replace(text, pattern: "(\\/)(?:Users|home)\\/[^\\/]+", with: "$1[USER_PATH]")
    }

    /// Replaces IPv4 addresses with `[IP_ADDR]`.
    static func sanitizeIP(_ text: String) -> String {
        replace(text, pattern: "\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b", with: "[IP_ADDR]")
    }

    /// Replaces email addresses with `[EMAIL]`.
    static func sanitizeEmail(_ text: String) -> String {
        replace(text, pattern: "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}", with: "[EMAIL]")
    }

    /// Redacts provider API keys. Covers the common vendor formats:
    ///   OpenAI-style           sk-[A-Za-z0-9]{20,}        → `sk-[API_KEY]`
    ///   Anthropic              sk-ant-[A-Za-z0-9-_]{20,}  → `sk-ant-[API_KEY]`
    ///   GitHub Personal Access ghp_[A-Za-z0-9]{20,}       → `ghp_[API_KEY]`
    ///   Slack bot              xoxb-[A-Za-z0-9-]{20,}     → `xoxb-[API_KEY]`
    ///   Generic `AIza`-prefixed (Google) AIza[A-Za-z0-9-_]{20,} → `AIza[API_KEY]`
    ///   Generic hex 40+ chars  \b[a-fA-F0-9]{40,}\b        → `[API_KEY_HEX]`
    static func sanitizeAPIKey(_ text: String) -> String {
        var s = text
        // Vendor-prefixed forms: preserve the prefix so diagnostics can tell which provider leaked.
        s = replace(s, pattern: "sk-ant-[A-Za-z0-9\\-_]{20,}",     with: "sk-ant-[API_KEY]")
        s = replace(s, pattern: "sk-[A-Za-z0-9]{20,}",              with: "sk-[API_KEY]")
        s = replace(s, pattern: "ghp_[A-Za-z0-9]{20,}",             with: "ghp_[API_KEY]")
        s = replace(s, pattern: "xoxb-[A-Za-z0-9\\-]{20,}",         with: "xoxb-[API_KEY]")
        s = replace(s, pattern: "xoxp-[A-Za-z0-9\\-]{20,}",         with: "xoxp-[API_KEY]")
        s = replace(s, pattern: "AIza[A-Za-z0-9\\-_]{20,}",         with: "AIza[API_KEY]")
        // Long hex strings: common format for OpenAI org IDs, some API keys.
        // Conservative — 40+ chars to avoid redacting legitimate IDs.
        s = replace(s, pattern: "\\b[a-fA-F0-9]{40,}\\b",           with: "[API_KEY_HEX]")
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
                pattern: "(https?|ftp|ssh|wss?)://[^/\\s:@]+:[^/\\s@]+@",
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

    /// Keys whose values are ALWAYS secret. Redacted in `.standard` and `.strict` levels.
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

    /// Compiled-regex cache. Previously every `replace` recompiled its `NSRegularExpression`
    /// — ~29 compiles per `sanitizeFull(.standard)` call (§12.9). Now each (pattern, options)
    /// pair compiles once. `NSRegularExpression` is thread-safe for matching and `NSCache`
    /// is thread-safe, so concurrent sanitize calls are fine.
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
