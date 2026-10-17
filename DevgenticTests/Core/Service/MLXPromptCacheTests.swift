// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXPromptCacheTests.swift
//  devgenticTests
//
//  Reusing the KV cache across agent iterations (see MLXPromptCache.swift). On the 2026-10-06
//  device run Qwen2.5-3B spent 7-11s per iteration re-reading a prompt that was ~90% unchanged.
//
//  Three things must hold, and each has a test that fails if it is cut:
//    - the decision table keeps only a prefix the new prompt really shares;
//    - a reused prefix reads EXACTLY like the whole prompt (same logits, same greedy text);
//    - the wiring: `streamChat` uses the slot only for a keyed call, reports the full prompt as
//      usage, and the executor names the conversation around an agent iteration's model call only.
//
//  The model is a 2-layer Qwen2 with random weights built in memory, and the tokenizer maps one
//  Unicode scalar to one token, so no model files are needed and every prompt's tokens are known.
//

import XCTest
import MLX
import MLXLMCommon
import MLXLLM
@testable import devgentic

// MARK: - Fixtures

/// One token per Unicode scalar, so a prompt's tokens follow directly from its text.
private struct ScalarTokenizer: MLXLMCommon.Tokenizer {
    let vocabularySize: Int

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        text.unicodeScalars.map { Int($0.value) % (vocabularySize - 1) + 1 }
    }
    // No `<`, so the framework's tool-call parser never mistakes output for a call opener.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { "t\($0) " }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { "t\(id)" }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        encode(text: Self.render(messages), addSpecialTokens: false)
    }

    static func render(_ messages: [[String: any Sendable]]) -> String {
        messages.map { "\($0["role"] as? String ?? ""):\($0["content"] as? String ?? "")|" }.joined()
    }
}

private struct UnusedInputProcessor: UserInputProcessor {
    struct Unused: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw Unused() }
}

private final class UsageBox: @unchecked Sendable {
    var value: TokenUsage?
}

private enum TinyModel {
    static let vocabularySize = 256

    static func make() throws -> Qwen2Model {
        let json = #"""
        {"hidden_size": 64, "num_hidden_layers": 2, "intermediate_size": 128,
         "num_attention_heads": 4, "num_key_value_heads": 2, "rms_norm_eps": 1e-6,
         "vocab_size": 256}
        """#
        let configuration = try JSONDecoder().decode(Qwen2Configuration.self, from: Data(json.utf8))
        MLXRandom.seed(7)
        let model = Qwen2Model(configuration)
        model.train(false)
        return model
    }

    static func tokens(count: Int, seed: Int) -> [Int] {
        (0..<count).map { (($0 * 31 + seed * 17) % (vocabularySize - 1)) + 1 }
    }

    /// Feeds `tokens` into `cache` and returns the logits at the last position.
    static func forward(_ model: Qwen2Model, _ tokens: [Int], _ cache: [KVCache]) -> MLXArray {
        let logits = model(MLXArray(tokens.map(Int32.init)).reshaped(1, tokens.count), cache: cache)
        let last = logits[0, tokens.count - 1]
        eval(last)
        return last
    }
}

// MARK: - The decision table

final class MLXPromptCachePlanTests: XCTestCase {

    private let cached = Array(1...400)

    func testAPromptThatExtendsTheCacheFeedsOnlyItsNewTail() {
        let prompt = cached + Array(500...539)
        XCTAssertEqual(MLXPromptCache.decide(cachedTokens: cached, promptTokens: prompt, minimumSuffix: 1, isTrimmable: true),
                       .reuse(keep: 400, trim: 0))
    }

    func testAPromptThatDivergesRewindsToTheDivergence() {
        let prompt = Array(cached.prefix(350)) + Array(900...939)
        XCTAssertEqual(MLXPromptCache.decide(cachedTokens: cached, promptTokens: prompt, minimumSuffix: 1, isTrimmable: true),
                       .reuse(keep: 350, trim: 50))
    }

    /// The model needs at least one fed token to produce logits, and with a repetition penalty the
    /// last N fed tokens are its context. An identical prompt therefore still re-reads that tail.
    func testAnIdenticalPromptStillReadsTheMinimumSuffix() {
        XCTAssertEqual(MLXPromptCache.decide(cachedTokens: cached, promptTokens: cached, minimumSuffix: 30, isTrimmable: true),
                       .reuse(keep: 370, trim: 30))
        XCTAssertEqual(MLXPromptCache.minimumSuffix(repetitionPenalty: 1.3, repetitionContextSize: 30), 30)
        XCTAssertEqual(MLXPromptCache.minimumSuffix(repetitionPenalty: nil, repetitionContextSize: 30), 1)
    }

    /// A new user message today: the task is the first layer, so the prompts part almost at once.
    func testATinyCommonPrefixRebuilds() {
        let prompt = Array(cached.prefix(20)) + Array(900...1300)
        XCTAssertEqual(MLXPromptCache.decide(cachedTokens: cached, promptTokens: prompt, minimumSuffix: 1, isTrimmable: true),
                       .rebuild(.shortCommonPrefix))
    }

    /// A recurrent or wrapped cache cannot rewind, but it can still be EXTENDED.
    func testAnUntrimmableCacheCanBeExtendedButNotRewound() {
        XCTAssertEqual(MLXPromptCache.decide(cachedTokens: cached, promptTokens: cached + Array(500...539), minimumSuffix: 1, isTrimmable: false),
                       .reuse(keep: 400, trim: 0))
        XCTAssertEqual(MLXPromptCache.decide(cachedTokens: cached, promptTokens: Array(cached.prefix(350)) + Array(900...939), minimumSuffix: 1, isTrimmable: false),
                       .rebuild(.untrimmable))
    }

    func testAnEmptyLedgerRebuilds() {
        XCTAssertEqual(MLXPromptCache.decide(cachedTokens: [], promptTokens: cached, minimumSuffix: 1, isTrimmable: true),
                       .rebuild(.emptyLedger))
    }
}

// MARK: - Reading from the cache is reading the prompt

final class MLXPromptCacheEquivalenceTests: XCTestCase {

    private let parameters = GenerateParameters(maxTokens: 4, temperature: 0)

    func testACachedPrefixReadsExactlyLikeTheWholePrompt() throws {
        let model = try TinyModel.make()
        let first = TinyModel.tokens(count: 300, seed: 1)
        let second = Array(first.prefix(280)) + TinyModel.tokens(count: 40, seed: 2)
        let slot = MLXPromptCacheSlot(key: "conversation", modelDirectory: nil, epoch: 0)

        let one = try MLXPromptCache.prepare(slot: slot, promptTokens: first, model: model,
                                             parameters: parameters, minimumSuffix: 1, minimumReuse: 16)
        XCTAssertEqual(one.plan, .rebuild(.emptyLedger))
        _ = TinyModel.forward(model, one.inputTokens, try XCTUnwrap(slot.cache))
        _ = TinyModel.forward(model, [5, 6, 7], try XCTUnwrap(slot.cache))   // what a generation leaves behind
        XCTAssertEqual(MLXPromptCache.settle(slot: slot, succeeded: true), .kept(tokens: 300),
                       "the generated tokens must be rewound, leaving exactly the prompt")

        let two = try MLXPromptCache.prepare(slot: slot, promptTokens: second, model: model,
                                             parameters: parameters, minimumSuffix: 1, minimumReuse: 16)
        XCTAssertEqual(two.plan, .reuse(keep: 280, trim: 20))
        XCTAssertEqual(two.inputTokens, Array(second[280...]))

        let fromCache = TinyModel.forward(model, two.inputTokens, try XCTUnwrap(slot.cache))
        let fromScratch = TinyModel.forward(model, second, try makePromptCache(model: model, parameters: parameters))
        XCTAssertTrue(allClose(fromCache, fromScratch, atol: 1e-4).item(Bool.self),
                      "a reused prefix must read like the whole prompt; max difference \(abs(fromCache - fromScratch).max().item(Float.self))")
    }

    /// Cancelled mid-read: the cache holds part of the prompt, so nothing in it may be trusted.
    func testAPromptThatWasNotFullyReadIsDiscarded() throws {
        let model = try TinyModel.make()
        let prompt = TinyModel.tokens(count: 300, seed: 3)
        let slot = MLXPromptCacheSlot(key: "conversation", modelDirectory: nil, epoch: 0)
        let preparation = try MLXPromptCache.prepare(slot: slot, promptTokens: prompt, model: model,
                                                     parameters: parameters, minimumSuffix: 1, minimumReuse: 16)
        _ = TinyModel.forward(model, Array(preparation.inputTokens.prefix(120)), try XCTUnwrap(slot.cache))

        guard case .invalidated = MLXPromptCache.settle(slot: slot, succeeded: true) else {
            return XCTFail("a half-read prompt was kept")
        }
        XCTAssertNil(slot.cache)
        XCTAssertTrue(slot.tokens.isEmpty)
    }

    func testAFailedGenerationIsDiscarded() throws {
        let model = try TinyModel.make()
        let prompt = TinyModel.tokens(count: 300, seed: 4)
        let slot = MLXPromptCacheSlot(key: "conversation", modelDirectory: nil, epoch: 0)
        let preparation = try MLXPromptCache.prepare(slot: slot, promptTokens: prompt, model: model,
                                                     parameters: parameters, minimumSuffix: 1, minimumReuse: 16)
        _ = TinyModel.forward(model, preparation.inputTokens, try XCTUnwrap(slot.cache))

        guard case .invalidated = MLXPromptCache.settle(slot: slot, succeeded: false) else {
            return XCTFail("a failed generation's cache was kept")
        }
        XCTAssertNil(slot.cache)
    }

    /// The ledger and the cache disagree: the cache's contents are unknown, so it is not reused.
    func testACacheThatDisagreesWithItsLedgerIsRebuilt() throws {
        let model = try TinyModel.make()
        let prompt = TinyModel.tokens(count: 300, seed: 5)
        let slot = MLXPromptCacheSlot(key: "conversation", modelDirectory: nil, epoch: 0)
        slot.cache = try makePromptCache(model: model, parameters: parameters)
        _ = TinyModel.forward(model, Array(prompt.prefix(200)), try XCTUnwrap(slot.cache))
        slot.tokens = prompt   // claims 300; the cache holds 200

        let preparation = try MLXPromptCache.prepare(slot: slot, promptTokens: prompt, model: model,
                                                     parameters: parameters, minimumSuffix: 1, minimumReuse: 16)
        XCTAssertEqual(preparation.plan, .rebuild(.misaligned))
        XCTAssertEqual(preparation.inputTokens, prompt)
    }
}

// MARK: - The wiring

final class MLXPromptCacheWiringTests: XCTestCase {

    private let directory = URL(fileURLWithPath: "/tmp/devgentic-tests-tiny-qwen2")
    private let system = String(repeating: "You are a coding assistant working in a project. ", count: 12)

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: MLXPromptCache.enabledDefaultsKey)
        let context = ModelContext(
            configuration: ModelConfiguration(id: "tiny-qwen2"),
            model: try TinyModel.make(),
            processor: UnusedInputProcessor(),
            tokenizer: ScalarTokenizer(vocabularySize: TinyModel.vocabularySize))
        await MLXService.shared.installContainerForTesting(ModelContainer(context: context), directory: directory)
    }

    override func tearDown() async throws {
        await MLXService.shared.unloadModel()
    }

    private func messages(_ user: String) -> [[String: String]] {
        [["role": "system", "content": system], ["role": "user", "content": user]]
    }

    private func promptTokens(_ messages: [[String: String]]) -> [Int] {
        ScalarTokenizer(vocabularySize: TinyModel.vocabularySize)
            .encode(text: ScalarTokenizer.render(messages), addSpecialTokens: false)
    }

    private func run(_ messages: [[String: String]], key: String?) async throws -> (text: String, usage: TokenUsage?) {
        let usage = UsageBox()
        let directory = directory
        let body: @Sendable () async throws -> String = {
            let stream = await MLXService.shared.streamChat(
                expectedModelDirectory: directory, messages: messages, maxTokens: 6,
                temperature: 0, topP: 1, repetitionPenalty: nil,
                onUsage: { usage.value = $0 })
            var text = ""
            for try await chunk in stream { text += chunk }
            return text
        }
        let text = try await MLXPromptCacheScope.$key.withValue(key) { try await body() }
        return (text, usage.value)
    }

    func testAKeyedCallReusesItsConversationsPromptAndAnUnkeyedOneNeverTouchesIt() async throws {
        let first = messages("read a.py")
        let second = messages("read a.py and b.py, then compare them")

        _ = try await run(first, key: "conversation-A")
        let ledger1 = await MLXService.shared.promptCacheLedgerForTesting
        XCTAssertEqual(ledger1?.key, "conversation-A")
        XCTAssertEqual(ledger1?.tokens, promptTokens(first).count, "the cache must hold exactly the prompt")

        let cached = try await run(second, key: "conversation-A")
        let expectedReuse = MLXPromptCache.commonPrefixLength(promptTokens(first), promptTokens(second))
        let reuse = await MLXService.shared.promptCacheReuseForTesting
        XCTAssertEqual(reuse.suffix(2), [0, expectedReuse], "the second call must read only what changed")
        XCTAssertGreaterThan(expectedReuse, MLXPromptCache.defaultMinimumReuse)
        XCTAssertEqual(cached.usage?.inputTokens, promptTokens(second).count,
                       "usage must report the whole prompt, not just the part that was fed")

        // A planning or synthesis call carries no key: it runs cold and leaves the cache alone.
        let cold = try await run(second, key: nil)
        let ledger2 = await MLXService.shared.promptCacheLedgerForTesting
        XCTAssertEqual(ledger2?.key, "conversation-A")
        XCTAssertEqual(ledger2?.tokens, promptTokens(second).count)
        XCTAssertFalse(cached.text.isEmpty, "nothing was generated, so the comparison below proves nothing")
        XCTAssertEqual(cold.text, cached.text, "the cached call and a cold read of the same prompt must agree")
    }

    /// A consumer that stops early must stop the GENERATION, not only stop reading it. On the
    /// 2026-10-06 device run the repeated-call guard tripped at the third copy and the turn still
    /// took 50s: nobody read the stream, but its task decoded on to `maxTokens`. Every decoded
    /// token here contains "t", so the stop sequence ends the read at the first one.
    func testAnEarlyStopStopsTheGenerationItself() async throws {
        let directory = directory
        let maxTokens = 1000
        let body: @Sendable () async throws -> Void = {
            let stream = await MLXService.shared.streamChat(
                expectedModelDirectory: directory, messages: self.messages("read a.py"),
                maxTokens: maxTokens, temperature: 0, topP: 1, repetitionPenalty: nil,
                stopSequences: ["t"])
            for try await _ in stream {}
        }
        try await MLXPromptCacheScope.$key.withValue("conversation-A") { try await body() }
        let written = await MLXService.shared.generatedTokensAtSettleForTesting.last
        XCTAssertNotNil(written, "the keyed call never settled its cache")
        XCTAssertLessThan(written ?? .max, maxTokens / 2,
                          "the generation decoded \(written ?? -1) of \(maxTokens) tokens after the consumer stopped at the first")
    }

    func testTheKillSwitchTurnsTheCacheOff() async throws {
        UserDefaults.standard.set(false, forKey: MLXPromptCache.enabledDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: MLXPromptCache.enabledDefaultsKey) }
        _ = try await run(messages("read a.py"), key: "conversation-A")
        _ = try await run(messages("read a.py and b.py"), key: "conversation-A")
        let reuse = await MLXService.shared.promptCacheReuseForTesting
        XCTAssertEqual(reuse.suffix(2), [0, 0])
        let ledger = await MLXService.shared.promptCacheLedgerForTesting
        XCTAssertNil(ledger)
    }

    /// The executor names the conversation around an agent iteration's model call, which is what
    /// lets that run's iterations share the cache.
    func testAnAgentIterationsModelCallNamesItsConversation() async throws {
        let provider = MockLLMProvider(steps: [ModernCognitiveStep(reasoning: "Done.")])
        let input = TestAgentInputFactory.make(query: "Which file defines clamp?")
        _ = try await StreamCollector.collect(from: ReActAgentExecutor(maxIterations: 3).execute(model: provider, input: input) { _ in })
        XCTAssertEqual(provider.receivedPromptCacheKeys.first ?? nil, input.conversationID.uuidString)
    }
}

// MARK: - Residency (local inference coordinator, phase 3)

/// `unloadModel(unlessResidentIn:)` is the coordinator's MLX residency step: it must keep a model the
/// new holder uses and unload one it does not.
final class MLXResidencyUnloadTests: XCTestCase {

    private let directory = URL(fileURLWithPath: "/tmp/devgentic-tests-tiny-qwen2-residency")

    override func setUp() async throws {
        let context = ModelContext(
            configuration: ModelConfiguration(id: "tiny-qwen2"),
            model: try TinyModel.make(),
            processor: UnusedInputProcessor(),
            tokenizer: ScalarTokenizer(vocabularySize: TinyModel.vocabularySize))
        await MLXService.shared.installContainerForTesting(ModelContainer(context: context), directory: directory)
    }

    override func tearDown() async throws {
        await MLXService.shared.unloadModel()
    }

    func testAModelTheHolderUsesIsKept() async {
        let unloadedForKeeper = await MLXService.shared.unloadModel(unlessResidentIn: [URL(fileURLWithPath: directory.path + "/")], reason: "test")
        XCTAssertFalse(unloadedForKeeper, "the same directory (spelled with a trailing slash) is the holder's model")
        let unloadedForOther = await MLXService.shared.unloadModel(unlessResidentIn: [URL(fileURLWithPath: "/tmp/another-model")], reason: "test")
        XCTAssertTrue(unloadedForOther, "a model the holder does not use is unloaded")
        let unloadedAgain = await MLXService.shared.unloadModel(unlessResidentIn: [], reason: "test")
        XCTAssertFalse(unloadedAgain, "nothing is resident any more")
    }
}
