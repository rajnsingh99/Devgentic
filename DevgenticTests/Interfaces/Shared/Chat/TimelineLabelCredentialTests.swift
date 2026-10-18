// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TimelineLabelCredentialTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class TimelineLabelCredentialTests: XCTestCase {

    // MARK: - The URL branch

    /// ⚠️ The fixture is PATH-BEARING on purpose. `lastPathComponent` of a BARE-host URL is the
    /// host itself (`https://api.github.com` → `api.github.com`), so a bare-host fixture would
    /// pass with the defect fully present — a vacuous test.
    ///
    /// Mutation that must kill this: delete the `webURLLabel` call from the identifying branch, or
    /// make `webURLLabel` read `query`/`absoluteString` instead of host+path.
    func testAURLQueryStringNeverReachesTheLabel() {
        let label = ToolArgFormatter.primaryLabel(
            tool: "http_request",
            params: #"{"url":"https://api.openweathermap.org/data/2.5/weather?appid=SECRETKEY&q=London"}"#
        )
        XCTAssertEqual(label, "api.openweathermap.org/…/weather",
                       "the row must name the host it called and the endpoint, and nothing after the path")
        XCTAssertFalse(label.contains("SECRETKEY"), "the API key must not reach the chip or the export")
        XCTAssertFalse(label.contains("appid"))
    }

    /// The host is the most load-bearing fact in an `http_request` row: before CR25 an exfiltration
    /// call to `evil.example.com/steal` exported as `steal`, which reads as though it had told you
    /// something. Basic-auth userinfo rides in the same string and must not survive either.
    ///
    /// Mutation that must kill this: build the label from `components.string` / `absoluteString`,
    /// or from `user`/`password`, instead of host+port+path.
    func testTheHostSurvivesAndBasicAuthDoesNot() {
        let label = ToolArgFormatter.primaryLabel(
            tool: "http_request",
            params: #"{"url":"https://admin:hunter2@internal.example.com/deploy/trigger"}"#
        )
        XCTAssertEqual(label, "internal.example.com/…/trigger")
        XCTAssertFalse(label.contains("hunter2"), "URL basic-auth must not reach the label")
        XCTAssertFalse(label.contains("admin"))
    }

    /// Mutation that must kill this: drop the `truncate(…, 40)` from `webURLLabel`. A bare
    /// `XCTAssertLessThanOrEqual(label.count, 40)` would survive several mutants; the equality
    /// does not.
    func testALongURLLabelIsCappedLikeEveryOtherBranch() {
        let label = ToolArgFormatter.primaryLabel(
            tool: "http_request",
            params: #"{"url":"https://really-long-subdomain.example-company-internal.com/api/v2/resources/items/final?api_key=SECRET"}"#
        )
        XCTAssertEqual(label, "really-long-subdomain.example-company-i…")
        XCTAssertEqual(label.count, 40)
        XCTAssertFalse(label.contains("SECRET"))
    }

    /// ⚠️ THE NARROWNESS CONTROL, and the test that binds the standing project rule "key off the
    /// argument NAME, never the SHAPE". `webURLLabel` parses against a declared grammar — a scheme
    /// plus a non-empty authority — rather than sniffing for a `/` or an `http` prefix.
    ///
    /// Mutation that must kill this: widen the guard to `value.contains("://")`, or drop the
    /// `host` requirement (a Windows path `C:/…` parses with scheme `C` and host nil), or drop the
    /// `scheme` requirement (every POSIX path would then be mangled).
    func testPlainPathsAreStillBasenamedAndNotTreatedAsURLs() {
        XCTAssertEqual(ToolArgFormatter.primaryLabel(tool: "mcp_tool", params: #"{"path":"/tmp/x.txt"}"#),
                       "x.txt")
        XCTAssertEqual(ToolArgFormatter.primaryLabel(tool: "mcp_tool", params: #"{"path":"relative/dir/file.swift"}"#),
                       "file.swift")
        XCTAssertEqual(ToolArgFormatter.primaryLabel(tool: "mcp_tool", params: #"{"path":"C:/Users/raj/foo.txt"}"#),
                       "foo.txt", "a Windows path parses with scheme 'C' and no host — it is not a URL")
        XCTAssertEqual(ToolArgFormatter.primaryLabel(tool: "mcp_tool", params: #"{"path":"file:///Users/me/x.txt"}"#),
                       "x.txt", "a file URL has an EMPTY host, so it keeps the plain-path treatment")
        XCTAssertEqual(ToolArgFormatter.primaryLabel(tool: "mcp_tool", params: #"{"path":"//example.com/x"}"#),
                       "x", "a protocol-relative reference has no scheme — the grammar requires an ABSOLUTE URL")
    }

    /// A URL is a URL wherever it is found. `http_request` declares `url` but its decoder also
    /// accepts `endpoint`/`uri`/`address`, and a third-party tool may call it anything — here
    /// `webhook`, which is in neither key list and so exercises the sorted sweep alone.
    ///
    /// Mutation that must kill this: apply `webURLLabel` only on the identifying branch and leave
    /// the sweep's `truncate(s, 40)` bare.
    func testTheSortedSweepShortensAURLTooRatherThanTruncatingIt() {
        let label = ToolArgFormatter.primaryLabel(
            tool: "some_mcp_tool",
            params: #"{"webhook":"https://hooks.example.com/services/T000/B000?token=SECRETKEY"}"#
        )
        XCTAssertEqual(label, "hooks.example.com/…/B000")
        XCTAssertFalse(label.contains("SECRETKEY"))
    }

    /// Mutation that must kill this: reorder `identifyingParamKeys` so `url` precedes `file_path`,
    /// or move the `webURLLabel` call above the `firstString(dict, keys:)` lookup.
    func testIdentityPrecedenceIsUnchangedByTheURLBranch() {
        XCTAssertEqual(
            ToolArgFormatter.primaryLabel(tool: "manage_safari_tabs",
                                          params: #"{"action":"open","url":"https://example.com/tabs/new?token=SECRET"}"#),
            "example.com/…/new", "`url` must still outrank `action`")
        XCTAssertEqual(
            ToolArgFormatter.primaryLabel(tool: "mystery_tool",
                                          params: #"{"file_path":"/tmp/a.txt","url":"https://x.com/y"}"#),
            "a.txt", "`file_path` must still outrank `url`")
    }

    // MARK: - The credential-name skip

    /// ⚠️ POSITIVE BY NECESSITY. `api_key` sorts before `topic`, so the unfixed code really did
    /// return `SECRETVALUE`; an `XCTAssertFalse(contains("SECRETVALUE"))` would also pass against a
    /// mutant that returned "". Only the equality distinguishes "skipped the secret and carried on"
    /// from "broke the sweep".
    ///
    /// Mutation that must kill this: delete `&& !isSecretParamName(key)` from the sweep's `where`.
    func testTheSweepSkipsACredentialNamedKeyAndTakesTheNextOne() {
        let label = ToolArgFormatter.primaryLabel(
            tool: "third_party_weather",
            params: #"{"api_key":"SECRETVALUE","topic":"weather"}"#
        )
        XCTAssertEqual(label, "weather", "the sweep must skip `api_key` and carry on, not stop")
        XCTAssertFalse(label.contains("SECRETVALUE"))
    }

    /// The rule is NORMALIZED CONTAINS, not equality, because a third-party schema will not spell
    /// it the canonical way.
    ///
    /// Mutation that must kill this: change `isSecretParamName` to exact-match the canonical list.
    func testCredentialNamesAreMatchedThroughSeparatorsAndCasing() {
        for key in ["x-api-key", "X_API_KEY", "openaiApiKey", "githubToken", "Authorization"] {
            XCTAssertTrue(ToolArgFormatter.isSecretParamNameForTesting(key), "\(key) must be treated as a credential name")
        }
        for key in ["topic", "query", "zone", "method", "alpha", "shortcut"] {
            XCTAssertFalse(ToolArgFormatter.isSecretParamNameForTesting(key), "\(key) is ordinary and must keep its label")
        }
    }

    /// ⚠️ THE TEST THAT BINDS THE NAME-NOT-SHAPE RULE. A value-shape sweep guard — `where s.count < 20`,
    /// or a "looks like a key" entropy/regex test — would drop this legitimate long value.
    ///
    /// Mutation that must kill this: replace the name check with any predicate over the VALUE.
    func testAnOrdinaryLongValueIsStillLabelledRatherThanMistakenForASecret() {
        let label = ToolArgFormatter.primaryLabel(
            tool: "third_party_tool",
            params: #"{"topic":"a legitimate topic value that is comfortably longer than forty characters"}"#
        )
        XCTAssertEqual(label, "a legitimate topic value that is comfor…")
    }

    /// `bot_token` and `session_token` are keys nobody writing a local list from memory would think
    /// to include, so a DRIFTED hand-typed copy of the canonical list goes red here.
    ///
    /// ⚠️ HONEST SCOPE: this CANNOT kill a PRISTINE copy of `TelemetrySanitizer.standardSecretKeysForEgress`
    /// — a pristine copy is behaviourally identical and diverges only the day that list next gains
    /// a key. Killing that needs a source scan, which is declined here: the one existing example of
    /// that shape carries a directory-depth-dependent path walk that throws `XCTSkip` when wrong,
    /// i.e. a vacuous pass, which is worse than no test. Written down rather than dressed up.
    ///
    /// Mutation that must kill this: replace the `TelemetrySanitizer` reference with a locally
    /// typed subset of the obvious names.
    func testTheCredentialListIsTheCanonicalOneNotALocalCopy() {
        XCTAssertEqual(ToolArgFormatter.primaryLabel(tool: "chatops_thing",
                                                     params: #"{"bot_token":"123:ABC","zone":"eu"}"#),
                       "eu")
        XCTAssertEqual(ToolArgFormatter.primaryLabel(tool: "chatops_thing",
                                                     params: #"{"session_token":"abc","zone":"eu"}"#),
                       "eu")
    }

    /// ⚠️ THE HOLE THIS FIX DOES NOT CLOSE ON THE RENDER PATH. The identifying branch runs BEFORE
    /// the sweep and never consults `isSecretParamName`, so a credential name added to
    /// `identifyingParamKeys` would be surfaced. That disjointness is held here, by a test, and
    /// deliberately not by a runtime check that would run on every row render.
    ///
    /// Mutation that must kill this: add `"token"` to `identifyingParamKeys`.
    func testNeitherKeyListMayCarryACredentialName() {
        for key in ToolArgFormatter.identifyingParamKeysForTesting {
            XCTAssertFalse(ToolArgFormatter.isSecretParamNameForTesting(key),
                           "`\(key)` is in identifyingParamKeys, which bypasses the credential skip entirely")
        }
        for key in ToolArgFormatter.payloadParamKeysForTesting {
            XCTAssertFalse(ToolArgFormatter.isSecretParamNameForTesting(key),
                           "`\(key)` is in payloadParamKeys and would be confusing to also treat as a secret name")
        }
    }

    // MARK: - The two payload-key riders

    /// `NetworkTools` decodes `headers` as an object OR as a JSON string, because models emit both.
    /// The object form was already safe (the `as? String` cast fails on a bridged `NSDictionary`);
    /// the string form was not, and `headers` sorts first.
    ///
    /// Mutation that must kill this: remove `"headers"` from `payloadParamKeys`. The `method`
    /// fallthrough is the control that the sweep still works at all.
    func testAJSONStringHeadersBlobNeverBecomesTheLabel() {
        let label = ToolArgFormatter.primaryLabel(
            tool: "http_request",
            params: #"{"headers":"{\"Authorization\":\"Bearer sk-ant-api03-DEADBEEF\"}","method":"GET"}"#
        )
        XCTAssertEqual(label, "GET", "the sweep must skip the header blob and fall through to `method`")
        XCTAssertFalse(label.contains("Bearer"))
        XCTAssertFalse(label.contains("DEADBEEF"))
    }

    /// `run_applescript` has no case in the switch, so its `script` param reached the sweep — the
    /// language whose ordinary idiom is `do shell script "…" password "…"`.
    ///
    /// Mutation that must kill this: remove `"script"` from `payloadParamKeys`. The second leg is
    /// the control: without it the empty-label leg would also pass against a mutant that broke the
    /// sweep outright.
    func testRawScriptIsAPayloadAndNeverTheLabel() {
        let label = ToolArgFormatter.primaryLabel(
            tool: "run_applescript",
            params: #"{"script":"do shell script \"curl x\" password \"hunter2\""}"#
        )
        XCTAssertEqual(label, "", "no identity available — an empty label is correct; leaking the script is not")
        XCTAssertFalse(label.contains("hunter2"))

        XCTAssertEqual(
            ToolArgFormatter.primaryLabel(tool: "run_applescript",
                                          params: #"{"script":"do shell script \"curl x\"","shortcut":"Daily Backup"}"#),
            "Daily Backup", "control: the sweep still surfaces a real identifying value beside a payload")
    }

    // MARK: - The wiring, not just the policy

    /// ⚠️⚠️ THE ONE THAT MATTERS MOST, and the reason it exists: today NOT ONE export test would
    /// fail for any of the above. Every test in the export suite that reaches `toolRowLine` passes
    /// `params: "{}"`, which returns "" at the `guard let dict, !dict.isEmpty` line, so the argument
    /// is never appended at all. The CR25 leak sat on a path with zero coverage, and a fix that
    /// changed only `ToolArgFormatter` would have shipped green while the export still leaked.
    ///
    /// Mutation that must kill this: change `ConversationExporter.toolRowLine` to slice `data.params`
    /// directly instead of calling `primaryLabel`, or apply the CR25 fix only inside
    /// `ActionDetailView.primaryArgLabel`.
    func testTheExportedMarkdownRowCarriesTheShortenedLabelNotTheSecret() {
        let data = ToolExecutionData(
            id: UUID(), name: "http_request",
            params: #"{"url":"https://api.openweathermap.org/data/2.5/weather?appid=SECRETKEY&q=London"}"#,
            output: "ok", isSuccess: true, isExecuting: false
        )
        let line = ConversationExporter.toolRowLine(for: data)
        XCTAssertEqual(line, "- ✅ `http_request` `api.openweathermap.org/…/weather`")
        XCTAssertFalse(line.contains("SECRETKEY"),
                       "the export is the surface the user hands to a third party and has no redaction of its own")
    }
}
