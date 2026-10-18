// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AnthropicRequestShapeTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class AnthropicModelGenerationTests: XCTestCase {

    // MARK: - Adaptive tier (sampling + budget_tokens removed)

    func testCurrentFlagshipsClassifyAsAdaptive() {
        let adaptive = [
            "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-sonnet-5",
            // ⚠️ Haiku 5.5 is a 5.5 that STILL takes `disabled` (at effort high or below). The 5.5
            // split is by family, not version — see `classify`.
            "claude-haiku-5-5",
        ]
        for model in adaptive {
            XCTAssertEqual(AnthropicModelGeneration.classify(modelName: model), .adaptive,
                           "\(model) must use the adaptive contract")
            XCTAssertFalse(AnthropicModelGeneration.classify(modelName: model).acceptsSamplingParams,
                           "\(model) rejects temperature/top_p/top_k with a 400")
            XCTAssertTrue(AnthropicModelGeneration.classify(modelName: model).acceptsDisabledThinking,
                          "\(model) accepts an explicit thinking:{type:disabled}")
        }
    }

    /// ⚠️ Fable and Mythos share the adaptive contract in every respect BUT one, and that one is a
    /// 400: thinking is always on, so `{"type": "disabled"}` is rejected at any effort. They were
    /// originally folded into `.adaptive`, and because every body test used `claude-opus-5` — the
    /// tier member for which `disabled` IS legal — nothing caught it. Hence a separate case, and
    /// hence the body tests below run against a Fable id specifically.
    func testAlwaysOnFlagshipsRejectDisabledThinking() {
        for model in ["claude-fable-5", "claude-mythos-5", "claude-mythos-preview",
                      // ⚠️ CR-1: Opus 5.5 400s on `disabled` at every effort level. It was in
                      // `.adaptive`, so every new Opus 5.5 profile failed every request.
                      "claude-opus-5-5", "anthropic.claude-opus-5-5", "claude-opus-6"] {
            let gen = AnthropicModelGeneration.classify(modelName: model)
            XCTAssertEqual(gen, .adaptiveAlwaysOn, "\(model)")
            XCTAssertEqual(gen.thinkingOffShape, .notOffered, "\(model)")
            XCTAssertFalse(gen.canTurnThinkingOff, "\(model) — the panel must hide the toggle")
            XCTAssertFalse(gen.acceptsDisabledThinking,
                           "\(model) returns 400 for thinking:{type:disabled} — the key must be omitted")
            // Everything else must still match the adaptive contract, or the split has drifted.
            XCTAssertTrue(gen.usesAdaptiveThinking, "\(model)")
            XCTAssertFalse(gen.acceptsSamplingParams, "\(model)")
            XCTAssertTrue(gen.acceptsEffort, "\(model)")
            XCTAssertEqual(gen.supportedEffortLevels,
                           AnthropicModelGeneration.adaptive.supportedEffortLevels,
                           "\(model) has the same effort ladder as the rest of the 5 tier")
        }
    }

    /// ⚠️ CR-1: Sonnet 5.5 rejects `disabled` with a 400; thinking-off is `{type: "between_tools"}`.
    /// The toggle stays — the user CAN turn thinking off — but the shape differs.
    func testSonnet55TurnsThinkingOffWithBetweenTools() {
        for model in ["claude-sonnet-5-5", "anthropic.claude-sonnet-5-5", "claude-sonnet-6"] {
            let gen = AnthropicModelGeneration.classify(modelName: model)
            XCTAssertEqual(gen, .adaptiveBetweenTools, "\(model)")
            XCTAssertEqual(gen.thinkingOffShape, .betweenTools, "\(model)")
            XCTAssertFalse(gen.acceptsDisabledThinking, "\(model) returns 400 for thinking:{type:disabled}")
            XCTAssertTrue(gen.canTurnThinkingOff, "\(model) — the toggle must stay")
            XCTAssertTrue(gen.usesAdaptiveThinking, "\(model)")
            XCTAssertFalse(gen.acceptsSamplingParams, "\(model)")
            XCTAssertEqual(gen.supportedEffortLevels, AnthropicModelGeneration.adaptive.supportedEffortLevels)
        }
    }

    /// Opus 5.5 and Haiku 5.5 default to `medium`; every other current model to `high`. The panel's
    /// "Default (…)" label and the dropped-effort log both read this.
    func testDefaultEffortIsMediumOnlyWhereTheAPISaysSo() {
        for model in ["claude-opus-5-5", "claude-haiku-5-5", "anthropic.claude-opus-5-5"] {
            XCTAssertEqual(AnthropicModelGeneration.defaultEffort(for: model), "medium", model)
        }
        for model in ["claude-opus-5", "claude-sonnet-5-5", "claude-fable-5", "claude-opus-4-8", ""] {
            XCTAssertEqual(AnthropicModelGeneration.defaultEffort(for: model), "high", model)
        }
    }

    // MARK: - 4.6 tier (adaptive thinking, sampling still accepted)

    func test46FamilyKeepsSamplingButUsesAdaptiveThinking() {
        for model in ["claude-opus-4-6", "claude-sonnet-4-6"] {
            let gen = AnthropicModelGeneration.classify(modelName: model)
            XCTAssertEqual(gen, .adaptiveWithSampling, "\(model)")
            XCTAssertTrue(gen.acceptsSamplingParams)
            XCTAssertTrue(gen.usesAdaptiveThinking)
        }
    }

    /// ⚠️ `xhigh` arrived with Opus 4.7 — offering it on a 4.6 model would 400.
    func testXHighEffortIsNotOfferedOn46() {
        XCTAssertFalse(
            AnthropicModelGeneration.classify(modelName: "claude-opus-4-6")
                .supportedEffortLevels.contains("xhigh"))
        XCTAssertTrue(
            AnthropicModelGeneration.classify(modelName: "claude-opus-4-7")
                .supportedEffortLevels.contains("xhigh"))
    }

    // MARK: - Legacy tier (budget_tokens, no effort)

    func testLegacyModelsKeepBudgetTokensAndRefuseEffort() {
        let legacy = [
            "claude-opus-4-5", "claude-opus-4-1", "claude-opus-4-0",
            "claude-sonnet-4-5", "claude-sonnet-4-0", "claude-haiku-4-5",
            "claude-3-5-sonnet-20241022", "claude-3-opus-20240229", "claude-2.1",
        ]
        for model in legacy {
            let gen = AnthropicModelGeneration.classify(modelName: model)
            XCTAssertEqual(gen, .legacyBudget, "\(model)")
            XCTAssertFalse(gen.usesAdaptiveThinking, "\(model) still takes budget_tokens")
            XCTAssertFalse(gen.acceptsEffort, "effort errors on Sonnet 4.5 / Haiku 4.5")
        }
    }

    // MARK: - Id shapes

    /// ⚠️ The whole point of the two-digit cut in `parseVersion`. Without it the trailing date
    /// parses as a minor version, `claude-opus-4-5-20251101` classifies as adaptive, and the
    /// provider silently strips sampling parameters that model still accepts.
    func testDatedSnapshotDoesNotParseItsDateAsAVersion() {
        XCTAssertEqual(AnthropicModelGeneration.classify(modelName: "claude-opus-4-5-20251101"), .legacyBudget)
        XCTAssertEqual(AnthropicModelGeneration.classify(modelName: "claude-haiku-4-5-20251001"), .legacyBudget)
        XCTAssertEqual(AnthropicModelGeneration.classify(modelName: "claude-sonnet-4-20250514"), .legacyBudget)
    }

    func testBedrockPrefixAndVertexSuffixAreStripped() {
        XCTAssertEqual(AnthropicModelGeneration.classify(modelName: "anthropic.claude-opus-5"), .adaptive)
        XCTAssertEqual(AnthropicModelGeneration.classify(modelName: "claude-opus-4-5@20251101"), .legacyBudget)
    }

    func testCasingAndWhitespaceAreTolerated() {
        XCTAssertEqual(AnthropicModelGeneration.classify(modelName: "  Claude-Opus-5  "), .adaptive)
    }

    /// An id this table has never seen is newer than the table, not older — see the type's
    /// header note. Guessing "old" would 400 every request to a just-released model. And of the
    /// adaptive shapes, only always-on cannot 400 anywhere: it never sends `disabled` or
    /// `between_tools`.
    func testUnknownIdsDefaultToTheNewestContract() {
        for model in ["claude-something-new", "", "gpt-4"] {
            XCTAssertEqual(AnthropicModelGeneration.classify(modelName: model), .adaptiveAlwaysOn, "\(model)")
        }
    }
}

final class AnthropicRequestBodyTests: XCTestCase {

    /// Builds a provider whose only meaningful inputs are the model and its advanced config.
    private func provider(
        model: String,
        thinking: Bool = false,
        effort: String? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        maxTokens: Int = 4096,
        budget: Int = 10000
    ) -> ClaudeLLMProvider {
        var options: [String: JSONValue] = [
            "maxTokens": .number(Double(maxTokens)),
            "extendedThinking": .bool(thinking),
            "thinkingBudgetTokens": .number(Double(budget)),
        ]
        if let effort { options["thinkingEffort"] = .string(effort) }
        if let temperature { options["temperature"] = .number(temperature) }
        if let topP { options["topP"] = .number(topP) }
        if let topK { options["topK"] = .number(Double(topK)) }

        return ClaudeLLMProvider(config: LLMProviderConfig(
            apiKey: "test-key",
            baseURL: URL(string: "https://api.anthropic.com/v1")!,
            modelName: model,
            options: options
        ))
    }

    /// Renders the body of the agent (cognitive-step) builder without issuing a request.
    private func body(for provider: ClaudeLLMProvider) -> [String: Any] {
        provider.debugRequestBody(messages: [["role": "user", "content": "hi"]], tools: nil)
    }

    // MARK: - A20: the version header

    func testVersionHeaderIsAlwaysTheSupportedValue() {
        // ⚠️ The defect: "2025-04-14" whenever thinking was on. That is not a version the API
        // recognises, so the whole profile 400d — thinking or not.
        for thinking in [true, false] {
            let request = provider(model: "claude-opus-5", thinking: thinking).debugMakeRequest()
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01",
                           "thinking=\(thinking)")
        }
    }

    // MARK: - A21: the thinking shape

    func testAdaptiveModelSendsAdaptiveThinkingNotBudgetTokens() throws {
        let body = body(for: provider(model: "claude-opus-5", thinking: true))
        let thinking = try XCTUnwrap(body["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "adaptive")
        XCTAssertNil(thinking["budget_tokens"], "budget_tokens returns 400 on this model")
    }

    func testLegacyModelKeepsBudgetTokens() throws {
        let body = body(for: provider(model: "claude-sonnet-4-5", thinking: true, budget: 8000))
        let thinking = try XCTUnwrap(body["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "enabled")
        XCTAssertEqual(thinking["budget_tokens"] as? Int, 8000)
        XCTAssertNil(body["output_config"], "effort errors on this tier")
    }

    /// ⚠️ Thinking is ON BY DEFAULT on Opus 5 / Sonnet 5, so the toggle only works if "off" is
    /// sent explicitly. Omitting the key would hand the user thinking they just switched off.
    func testThinkingOffIsSentExplicitlyOnAdaptiveModels() throws {
        let body = body(for: provider(model: "claude-opus-5", thinking: false, effort: "xhigh"))
        let thinking = try XCTUnwrap(body["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "disabled")
        // ⚠️ An effort IS configured here on purpose. The rule under test is that `output_config`
        // is suppressed *because* thinking is disabled — with `effort: nil` the assertion passes
        // whether or not the suppression exists, which is how it read before.
        XCTAssertNil(body["output_config"],
                     "effort xhigh/max is rejected alongside disabled thinking — send nothing")
    }

    /// ⚠️ THE Fable-5 regression guard. `{"type": "disabled"}` is rejected with a 400 at any
    /// effort on Fable 5 / Mythos 5 — thinking cannot be switched off there. Since
    /// `AnthropicAdvancedConfig.default()` ships `extendedThinking: false`, sending the disabled
    /// shape meant a freshly created Fable profile 400d on every request from all five builders,
    /// before the user touched a control.
    func testFableNeverReceivesDisabledThinkingEvenWhenTheToggleIsOff() throws {
        for model in ["claude-fable-5", "claude-mythos-5"] {
            let body = body(for: provider(model: model, thinking: false))
            let thinking = try XCTUnwrap(body["thinking"] as? [String: Any], model)
            XCTAssertNotEqual(thinking["type"] as? String, "disabled",
                              "\(model) returns 400 for disabled thinking")
            XCTAssertEqual(thinking["type"] as? String, "adaptive",
                           "\(model) is always-on; adaptive is the documented equivalent of omitting the key")
            XCTAssertNil(thinking["budget_tokens"], "\(model)")
        }
    }

    /// Effort is the only depth control on an always-on model, so unlike the disabled-thinking
    /// path it must still be forwarded when the toggle is off.
    func testFableStillSendsEffortWithTheToggleOff() throws {
        let body = body(for: provider(model: "claude-fable-5", thinking: false, effort: "xhigh"))
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "xhigh")
    }

    func testFableWithThinkingOnIsUnchanged() throws {
        let body = body(for: provider(model: "claude-fable-5", thinking: true, temperature: 0.5))
        let thinking = try XCTUnwrap(body["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "adaptive")
        XCTAssertNil(body["temperature"], "sampling params are removed on this generation")
        XCTAssertNil(body["top_p"])
    }

    // MARK: - CR-1: the 5.5 thinking-off shapes

    /// ⚠️ THE CR-1 REGRESSION GUARD, through the shipped builders. A new profile ships
    /// `extendedThinking: false`, so this is the body every fresh Opus 5.5 profile sends.
    func testOpus55NeverReceivesDisabledThinking() throws {
        for thinking in [false, true] {
            let agentBody = body(for: provider(model: "claude-opus-5-5", thinking: thinking, effort: "low"))
            let streamBody = provider(model: "claude-opus-5-5", thinking: thinking, effort: "low")
                .debugStreamingRequestBody(messages: [["role": "user", "content": "hi"]])
            for (path, b) in [("agent", agentBody), ("stream", streamBody)] {
                let thinkingField = try XCTUnwrap(b["thinking"] as? [String: Any], "\(path) thinking=\(thinking)")
                XCTAssertEqual(thinkingField["type"] as? String, "adaptive",
                               "\(path) thinking=\(thinking): Opus 5.5 400s on disabled at every effort")
                // Effort is the only control left, so it must survive the toggle being off.
                XCTAssertEqual((b["output_config"] as? [String: Any])?["effort"] as? String, "low",
                               "\(path) thinking=\(thinking)")
            }
        }
    }

    /// ⚠️ Sonnet 5.5's off is `between_tools`, sent BARE: `display` beside it is a 400 (and the agent
    /// path asks for a summary), and effort `xhigh`/`max` is a 400 with it (so no effort at all).
    func testSonnet55ThinkingOffIsBareBetweenToolsOnEveryBuilder() throws {
        let agentBody = body(for: provider(model: "claude-sonnet-5-5", thinking: false, effort: "xhigh"))
        let streamBody = provider(model: "claude-sonnet-5-5", thinking: false, effort: "xhigh")
            .debugStreamingRequestBody(messages: [["role": "user", "content": "hi"]])
        for (path, b) in [("agent", agentBody), ("stream", streamBody)] {
            let thinkingField = try XCTUnwrap(b["thinking"] as? [String: Any], path)
            XCTAssertEqual(thinkingField as NSDictionary, ["type": "between_tools"] as NSDictionary,
                           "\(path): between_tools takes no other field")
            XCTAssertNil(b["output_config"], "\(path): xhigh/max are rejected with between_tools — send no effort")
        }
    }

    func testSonnet55WithThinkingOnIsAdaptiveWithEffort() throws {
        let b = body(for: provider(model: "claude-sonnet-5-5", thinking: true, effort: "xhigh"))
        XCTAssertEqual((b["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        XCTAssertEqual((b["output_config"] as? [String: Any])?["effort"] as? String, "xhigh")
    }

    /// The control for the split: Haiku 5.5 is a 5.5 that still takes `disabled`.
    func testHaiku55StillSendsDisabledWithNoEffort() throws {
        let b = body(for: provider(model: "claude-haiku-5-5", thinking: false, effort: "max"))
        XCTAssertEqual((b["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertNil(b["output_config"], "disabled is accepted only at effort high or below — send none")
    }

    func testEffortIsSentWhenSupportedAndDroppedWhenNot() throws {
        let supported = body(for: provider(model: "claude-opus-5", thinking: true, effort: "xhigh"))
        XCTAssertEqual((supported["output_config"] as? [String: Any])?["effort"] as? String, "xhigh")

        // xhigh does not exist on 4.6 — must be dropped rather than forwarded into a 400.
        let unsupported = body(for: provider(model: "claude-opus-4-6", thinking: true, effort: "xhigh"))
        XCTAssertNil(unsupported["output_config"])
    }

    // MARK: - A22: thinking reaches every builder

    /// The defect: `body["thinking"]` was set only inside `generateCognitiveStep`, so a Bot
    /// profile with the toggle on got no thinking while still losing its temperature control.
    func testThinkingIsAppliedOnTheStreamingChatPath() throws {
        let body = provider(model: "claude-opus-5", thinking: true)
            .debugStreamingRequestBody(messages: [["role": "user", "content": "hi"]])
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    // MARK: - A23: sampling parameters

    func testSamplingParamsAreOmittedOnModelsThatRemovedThem() throws {
        let body = body(for: provider(
            model: "claude-opus-5", temperature: 0.7, topP: 0.9, topK: 40))
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["top_p"])
        XCTAssertNil(body["top_k"], "top_k was unconditional in the shipped code — the actual bug")
    }

    func testSamplingParamsSurviveOnModelsThatStillAcceptThem() throws {
        let body = body(for: provider(model: "claude-sonnet-4-5", temperature: 0.7, topK: 40))
        XCTAssertEqual(body["temperature"] as? Double, 0.7)
        XCTAssertEqual(body["top_k"] as? Int, 40)
    }

    /// Claude 4+ rejects temperature and top_p together; temperature wins.
    func testTemperatureAndTopPAreNeverSentTogether() throws {
        let body = body(for: provider(model: "claude-sonnet-4-5", temperature: 0.7, topP: 0.9))
        XCTAssertEqual(body["temperature"] as? Double, 0.7)
        XCTAssertNil(body["top_p"])
    }

    func testThinkingSuppressesSamplingOnLegacyModels() throws {
        let body = body(for: provider(
            model: "claude-sonnet-4-5", thinking: true, temperature: 0.7, topP: 0.9, topK: 40))
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["top_p"])
        XCTAssertNil(body["top_k"])
    }

    // MARK: - max_tokens interaction

    /// The API requires max_tokens > budget_tokens, so a 4096/10000 profile must be raised.
    func testLegacyThinkingRaisesMaxTokensAboveTheBudget() throws {
        let body = body(for: provider(
            model: "claude-sonnet-4-5", thinking: true, maxTokens: 4096, budget: 10000))
        XCTAssertEqual(body["max_tokens"] as? Int, 11024)
    }

    /// Adaptive models carry no budget, so the user's configured value is sent verbatim —
    /// silently inflating it would change what they are billed.
    func testAdaptiveThinkingDoesNotInflateMaxTokens() throws {
        let body = body(for: provider(
            model: "claude-opus-5", thinking: true, maxTokens: 4096, budget: 10000))
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
    }
}

final class AnthropicAdvancedConfigCodableTests: XCTestCase {

    /// ⚠️ Every profile saved before this fix has no `thinkingEffort` key. The blob decoder must
    /// tolerate that rather than failing the whole advanced config — a decode failure here is
    /// silently answered with `.default()`, which would wipe the user's other settings.
    func testDecodingAProfileWrittenBeforeEffortExisted() throws {
        let legacyJSON = """
        {"maxTokens":8192,"temperature":0.7,"extendedThinking":true,"thinkingBudgetTokens":12000}
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AnthropicAdvancedConfig.self, from: legacyJSON)
        XCTAssertEqual(config.maxTokens, 8192)
        XCTAssertEqual(config.temperature, 0.7)
        XCTAssertTrue(config.extendedThinking)
        XCTAssertEqual(config.thinkingBudgetTokens, 12000)
        XCTAssertNil(config.thinkingEffort)
    }

    func testEffortSurvivesARoundTrip() throws {
        var config = AnthropicAdvancedConfig.default()
        config.thinkingEffort = "xhigh"
        let decoded = try JSONDecoder().decode(
            AnthropicAdvancedConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.thinkingEffort, "xhigh")
    }
}
