// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TelemetrySanitizerTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class TelemetrySanitizerSecretClassTests: XCTestCase {

    /// Every current-generation key format must die at `.standard`. The BODY of the secret is
    /// what must vanish — the vendor prefix deliberately survives so diagnostics can name the
    /// provider that leaked.
    func testCurrentGenerationKeyFormatsAreRedactedAtStandard() {
        let secrets: [(name: String, text: String, mustNotSurvive: String)] = [
            ("OpenAI current",   "key sk-proj-Abc123Def456Ghi789Jkl012Mno345 set",  "Abc123Def456Ghi789"),
            ("OpenAI legacy",    "key sk-Abc123Def456Ghi789Jkl012 set",             "Abc123Def456Ghi789"),
            ("Anthropic",        "key sk-ant-api03-Abc123Def456Ghi789Jkl0 set",     "api03-Abc123Def456"),
            ("HuggingFace",      "token hf_AbCdEfGhIjKlMnOpQrStUvWxYz012345 used",  "AbCdEfGhIjKlMnOp"),
            ("GitHub classic",   "ghp_Abc123Def456Ghi789Jkl012Mno pushed",          "Abc123Def456Ghi789"),
            ("GitHub OAuth",     "gho_Abc123Def456Ghi789Jkl012Mno pushed",          "Abc123Def456Ghi789"),
            ("GitHub server",    "ghs_Abc123Def456Ghi789Jkl012Mno pushed",          "Abc123Def456Ghi789"),
            ("GitHub refresh",   "ghr_Abc123Def456Ghi789Jkl012Mno pushed",          "Abc123Def456Ghi789"),
            ("GitHub fine-grained", "github_pat_11ABCDEFG_abc123def456ghi789jkl cloned", "11ABCDEFG_abc123"),
            ("GitLab",           "glpat-Abc123Def456Ghi789Jk read",                 "Abc123Def456Ghi789"),
            ("AWS access key",   "aws AKIAIOSFODNN7EXAMPLE used",                   "IOSFODNN7EXAMPLE"),
            ("AWS temp key",     "aws ASIAIOSFODNN7EXAMPLE used",                   "IOSFODNN7EXAMPLE"),
            ("Slack bot",        "xoxb-1234567890-abcdefghij connected",            "1234567890-abcdefghij"),
            ("Slack app-level",  "xapp-1-A012345-abcdefghij connected",             "A012345-abcdefghij"),
            ("Telegram bot",     "bot 123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw up", "AAHdqTcvCH1vGWJx"),
            ("Google",           "AIzaSyAbc123Def456Ghi789Jkl0 maps",               "SyAbc123Def456Ghi"),
        ]
        for c in secrets {
            let out = TelemetrySanitizer.sanitizeFull(c.text, level: .standard)
            XCTAssertFalse(out.contains(c.mustNotSurvive),
                           "\(c.name): secret body survived .standard — got: \(out)")
        }
    }

    /// Discord bot tokens: three dot-joined base64url segments.
    func testDiscordBotTokenIsRedacted() {
        let text = "connect MTA1234567890123456789012.GabcDe.abcdefghijklmnopqrstuvwxy12345 gateway"
        let out = TelemetrySanitizer.sanitizeFull(text, level: .standard)
        XCTAssertFalse(out.contains("MTA1234567890123456789012"), "got: \(out)")
        XCTAssertTrue(out.contains("[DISCORD_TOKEN]"), "got: \(out)")
    }

    /// ⚠️ THE ESCAPED-JSON FINDING. An LLM tool-call argument is a JSON object serialized
    /// INSIDE a JSON string — every quote is \" — and the plain-form key pattern cannot see
    /// it, so `{"arguments": "{\"apiKey\":\"sk-live-…\"}"}` passed through unredacted.
    func testEscapedJSONToolArgumentSecretsAreRedacted() {
        let payload = #"{"arguments": "{\"apiKey\":\"super-secret-value-123\",\"query\":\"weather\"}"}"#
        let out = TelemetrySanitizer.sanitizeFull(payload, level: .standard)
        XCTAssertFalse(out.contains("super-secret-value-123"),
                       "escaped-form secret survived: \(out)")
        XCTAssertTrue(out.contains("weather"),
                      "non-secret sibling keys must be left intact: \(out)")
        // The plain form still works too.
        let plain = #"{"apiKey": "super-secret-value-123"}"#
        XCTAssertFalse(TelemetrySanitizer.sanitizeFull(plain, level: .standard)
            .contains("super-secret-value-123"))
    }

    /// IPv6 joins the `.minimal` tier alongside IPv4 — real addresses (the 2606:4700:…
    /// Cloudflare edges in this app's own network logs) previously passed every level.
    func testIPv6IsRedactedAtMinimalLevel() {
        let cases = [
            "peer 2606:4700:90da:1cef:c7ca:408:64fa:89ba reset",   // full 8-group, from real logs
            "route fe80::1 dead",                                   // compressed
            "srv 2001:db8:0:1::42 up",                              // mixed compressed
        ]
        for text in cases {
            let out = TelemetrySanitizer.sanitizeFull(text, level: .minimal)
            XCTAssertTrue(out.contains("[IP_ADDR]"), "IPv6 not redacted in: \(out)")
            XCTAssertFalse(out.contains("2606:4700") || out.contains("fe80::1") || out.contains("2001:db8"),
                           "address survived: \(out)")
        }
    }

    // MARK: - Anti-overreach: a sanitizer is a shape-matcher, and shape-matchers eat content

    /// Timestamps share the colon-group shape with IPv6 — they must survive. The IPv6
    /// patterns require either the full 8-group form or a `::`, which no timestamp has.
    func testTimestampsSurviveTheIPv6Patterns() {
        for text in [
            "finished at 12:30:45",
            "2026-08-23 12:30:45.123 event landed",
            "elapsed 00:01:23",
        ] {
            XCTAssertEqual(TelemetrySanitizer.sanitizeFull(text, level: .minimal), text,
                           "a timestamp was mangled")
        }
    }

    /// The old `sk-` pattern was un-anchored; the widened class (hyphens allowed) would have
    /// eaten the tail of ordinary hyphenated prose without the `\b`.
    func testOrdinaryHyphenatedProseSurvives() {
        for text in [
            "the risk-management-policy-review-cycle-2026 doc",
            "run task-with-a-very-long-hyphenated-name-here now",
            "call tokenize(text) then parse",
        ] {
            XCTAssertEqual(TelemetrySanitizer.sanitizeFull(text, level: .standard), text,
                           "ordinary prose was mangled")
        }
    }

    /// ⚠️ THE SHIM. `sanitize(_:)` was `.minimal` — and 18 call sites (every content-bearing
    /// TraceRecorder emitter) accumulated on the short name, so tool output containing a key
    /// was stored UNREDACTED in span_events. The shim now runs `.standard`; this pins it.
    func testSanitizeShimRunsStandardLevel() {
        let bearer = "Authorization: Bearer abcdef0123456789abcdef"
        XCTAssertFalse(TelemetrySanitizer.sanitize(bearer).contains("abcdef0123456789"),
                       "sanitize() must scrub secrets — bearer redaction only exists at .standard")
        XCTAssertFalse(TelemetrySanitizer.sanitize("token hf_AbCdEfGhIjKlMnOpQrStUvWx").contains("AbCdEfGhIjKl"))
    }
}

/// The real path: a tool result carrying a secret must be scrubbed by the time it is
/// persisted in span_events — this is the ungated, exported channel the assessment flagged.
final class TelemetrySanitizerSpanPathTests: XCTestCase {

    func testToolOutputSecretNeverReachesPersistedSpanEvents() async throws {
        let store = try TraceStore(inMemory: true)
        let recorder = TraceRecorder(store: store)
        let ctx = TraceContext(subAgentName: "sanitizer-path", provider: .anthropic)
        await recorder.beginTrace(context: ctx, conversationID: UUID(), messageID: UUID(), modelName: nil)

        await recorder.emitToolResult(
            span: ctx, name: "read_file", success: true,
            output: "HF_TOKEN=hf_AbCdEfGhIjKlMnOpQrStUvWxYz012345 found in .env",
            durationMs: 5)
        await recorder.emitLLMResponse(
            span: ctx, durationMs: 10,
            preview: "the key is sk-proj-Abc123Def456Ghi789Jkl012Mno345 apparently")
        await recorder.flushNow()

        let events = try store.fetchEvents(forTraceID: ctx.traceID)
        let allDetail = events.compactMap(\.detailJSON).joined()
        XCTAssertFalse(allDetail.contains("AbCdEfGhIjKlMnOp"),
                       "an hf_ token in tool output reached span_events — the exported channel")
        XCTAssertFalse(allDetail.contains("Abc123Def456Ghi789"),
                       "an sk-proj key in a model response reached span_events")
        XCTAssertTrue(allDetail.contains("read_file"), "the structured fields must survive")
    }
}
