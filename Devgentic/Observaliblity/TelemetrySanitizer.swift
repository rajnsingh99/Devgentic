// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

    /// Default sanitization — full `.standard` redaction.
    ///
    /// ⚠️ This was `.minimal` (home paths, IPs, emails ONLY) until 2026-08-23, framed as a
    /// compat shim "callers should migrate away from". Nobody migrated; instead 18 call sites
    /// accumulated on the SHORT name — every content-bearing TraceRecorder emitter (tool
    /// arguments/output previews, LLM response previews, raw parse output, thoughts, errors,
    /// HITL titles) plus EvaluationLogger's bridged content. All of that lands in
    /// `span_events.detailJSON`, which is written UNGATED for every user on every run and
    /// ships in the diagnostic bundle — so a tool that read a `.env` file stored the key
    /// UNREDACTED, because API-key/bearer/JSON-secret scrubbing only starts at `.standard`.
    /// The shim was the leak. Making the short name safe is the drift-proof fix: a future
    /// call site that reaches for `sanitize(...)` now gets secret scrubbing by default, and
    /// anything that genuinely wants less must say `sanitizeFull(_, level: .minimal)` out loud.
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

    /// Replaces macOS/Linux home-dir prefixes with a placeholder, preserving the tail.
    /// `/Users/alice/Documents/foo.swift` → `/[USER_PATH]/Documents/foo.swift`
    ///
    /// ⚠️⚠️ THE USERNAME CLASS IS BOUNDED, AND IT USED TO EAT PROSE. It was `[^\/]+` — "anything
    /// that is not a slash" — which is only the username when a slash actually follows. In a
    /// sentence it does not: an agent reply reading ``The home directory (`/Users/dev`) contains
    /// both files and many folders. … including `Applications/` `` has NO forward slash for 221
    /// characters after the username, so one match swallowed the whole paragraph — newlines
    /// included — and the log line read ``The home directory (`/[USER_PATH]/`, `Desktop/` ``.
    /// Observed in a real launch log 2026-09-11; the unsanitised twin of the same string, printed
    /// two lines later, showed the text intact.
    ///
    /// ⚠️ WHY AN EXCLUSION CLASS RATHER THAN AN ALLOWLIST. `[A-Za-z0-9._-]+` describes a POSIX
    /// username exactly and fixes the corruption — but it UNDER-redacts the cases it does not
    /// describe: `/Users/CORP\jsmith` leaks `\jsmith` and `/Users/josé` leaks `é`. This file's
    /// header commits to over-redacting rather than under-redacting, so the class instead excludes
    /// the delimiters a path component cannot be followed by in prose (whitespace, quotes,
    /// backtick, brackets, comma, semicolon) and keeps everything else. A username containing a
    /// literal `)` or `;` would be clipped; no real one does.
    ///
    /// ⚠️ Sibling patterns were audited at the same time and none share this shape — every other
    /// class in this file is bounded by `\b`, by an explicit character set, or by a closing quote.
    static func sanitizeHomePath(_ text: String) -> String {
        replace(text, pattern: "(\\/)(?:Users|home)\\/[^\\/\\s\"'`(),;]+", with: "$1[USER_PATH]")
    }

    /// Replaces IP addresses (v4 and v6) with `[IP_ADDR]`.
    ///
    /// IPv6 was missing entirely — real addresses (e.g. the `2606:4700:…` Cloudflare edges in
    /// this app's own network logs) passed every level. Two deliberate shapes, chosen so
    /// timestamps survive: the FULL 8-group form, and any `::`-compressed form. "12:30:45"
    /// has three groups and no `::`, so neither matches; an uncompressed IPv6 is always
    /// 8 groups, so nothing real slips between the two patterns.
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

    /// Redacts provider API keys, vendor-prefixed so diagnostics can still say WHICH
    /// provider leaked.
    ///
    /// ⚠️ Executed-test lesson (2026-08-23): 8 of 11 secret classes SURVIVED the previous
    /// list — verified by RUNNING the regexes, not reading them. `sk-proj-` (OpenAI's current
    /// default format) escaped because `sk-[A-Za-z0-9]{20,}` cannot cross the hyphen after
    /// "proj"; `hf_` was absent although this app downloads MLX models from the HuggingFace
    /// Hub with exactly those tokens; `github_pat_`/`gho_`-family/`glpat-`/`AKIA` postdated
    /// the list; and the app's own ChatOps transports hold Slack app, Telegram bot and
    /// Discord bot tokens that had no pattern at all. Every pattern is now `\b`-anchored —
    /// the old un-anchored `sk-` rule could bite the tail of hyphenated prose ("risk-…").
    static func sanitizeAPIKey(_ text: String) -> String {
        var s = text
        // Anthropic first (most specific), then the generalized sk- form, which now admits
        // hyphens/underscores so sk-proj-/sk-live-/sk-or- all match. It cannot re-match the
        // replaced "sk-ant-[API_KEY]" because "[" terminates the character class.
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
        // AWS access key IDs (AKIA long-lived, ASIA temporary) — self-identifying 20 chars.
        // The paired 40-char base64 SECRET is deliberately NOT pattern-matched bare: a naked
        // [A-Za-z0-9/+=]{40} rule would eat ordinary base64 content (this codebase's
        // recidivist defect class); it is covered contextually by sanitizeEnvVars
        // (AWS_SECRET_ACCESS_KEY=…) and sanitizeJSONKeys ("secret": …).
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
        // Long hex strings: common format for OpenAI org IDs, some API keys.
        // Conservative — 40+ chars to avoid redacting legitimate IDs. (This also catches full
        // git SHAs; the file's stated contract is over-redact rather than under-redact.)
        s = replace(s, pattern: "\\b[a-fA-F0-9]{40,}\\b",           with: "[API_KEY_HEX]")
        // ⚠️ BARE JWTs. `sanitizeBearerToken` requires a literal `Bearer ` prefix, and the
        // Discord-token pattern above is anchored `[MNO]` — so a session token echoed out of a 401
        // body, a decoded cookie, or a config file matched NOTHING. `eyJ` is the base64url of `{"`,
        // which is what every JWT header begins with; three dot-joined segments is the format.
        s = replace(s, pattern: "\\beyJ[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,}", with: "[JWT]")
        // ⚠️ PEM PRIVATE KEYS, matched as a BLOCK. Nothing else here spans lines, and a key is only
        // dangerous whole — `cat ~/.ssh/id_ed25519` in a tool result is the ordinary way one arrives.
        // ⚠️ Non-greedy, so two keys in one string redact as two blocks rather than one span that
        // also swallows everything between them (the greedy-match failure invariant 41 records).
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
                // ⚠️⚠️ ANY URI SCHEME, NOT A FIXED LIST. The alternation used to be
                // `(https?|ftp|ssh|wss?)`, which meant every database URI walked straight through:
                // `postgres://admin:hunter2@db:5432/app`, `mongodb://`, `redis://`, `mysql://`,
                // `amqp://` — precisely the strings an agent quotes back when the user asks why the
                // app cannot reach the database, and precisely the ones a `.env` is full of. The
                // pattern already requires a literal `user:pass@`, which prose does not contain, so
                // widening the scheme costs no false positives.
                // ⚠️ The scheme stays CAPTURED — the replacement is "$1://[CREDS]@", so dropping the
                // group would silently rewrite `postgres://u:p@h` as `://[CREDS]@h` and lose the
                // scheme along with the password.
                // ⚠️ THE USERNAME IS OPTIONAL (`*`, not `+`). `redis://:mypassword@host` is the
                // ordinary Redis form and has no user at all; requiring one let it through with the
                // password intact. The PASSWORD stays `+` — without one there is no credential here.
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
            // ⚠️ The ESCAPED form too: \"key\":\"value\". Not an edge case here — it is the
            // exact shape of a JSON object serialized INSIDE a JSON string, which is what
            // every LLM tool-call argument looks like in a logged payload
            // ({"arguments": "{\"apiKey\":\"…\"}"}). The plain-form pattern above cannot see
            // it because every quote is preceded by a backslash, so secrets inside tool
            // arguments passed through unredacted (executed-test finding, 2026-08-23).
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

    /// Keys whose values are ALWAYS secret. Redacted in `.standard` and `.strict` levels.
    /// ⚠️ ALSO READ BY `RemoteEgressSanitizer`, which composes the credential passes without the
    /// path/IP/email folding a `Level` would drag in. Adding a key here strengthens both.
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
