// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXPromptCache.swift
//  Devgentic
//
//  Keeps an MLX model's KV cache between the iterations of one agent run, so each iteration reads
//  only the part of the prompt that changed.
//
//  WHY (device run 2026-10-06, Qwen2.5-3B-Instruct-4bit). Every MLX iteration used to re-read the
//  whole 6-7k-token prompt from token 0: `MLXLMCommon.generate` was called without a cache, so one
//  was built and dropped per call. Prefill runs at ~800 tokens/s on that model, so each iteration
//  spent 7-11s re-reading text identical to the previous iteration's. That was 66s of T4's 111s
//  and 62s of T5's 119s. Ollama and cloud providers keep this cache server-side (G12); MLX runs
//  in-process, so the app keeps it.
//
//  HOW. A ledger records exactly which tokens the cache represents. Each call compares the new
//  prompt with the ledger, keeps the longest common prefix, rewinds the rest and feeds only the
//  suffix. After the call the cache is rewound to the prompt again: the legacy path never shows the
//  model its own output verbatim, so generated tokens are never reusable, and a rejected or failed
//  turn's output never lingers in the cache.
//
//  mlx-swift-lm has the same logic (`PromptCacheReusePolicy`), but it is internal and only its
//  `ChatSession` uses it, which renders its own chat template. The app renders its own tokens
//  (including the repaired Qwen template), so it applies the idea through the public cache API.
//

import Foundation
import MLX
import MLXLMCommon

private let logger = DGLogger(category: "MLXPromptCache")

// MARK: - Decision

/// How a new prompt is reconciled with what the cache holds.
enum MLXPromptCachePlan: Equatable {
    /// Keep the first `keep` cached tokens, rewind `trim` from the end, feed `prompt[keep...]`.
    case reuse(keep: Int, trim: Int)
    /// Start from an empty cache and feed the whole prompt.
    case rebuild(MLXPromptCacheRebuildReason)

    var reusedTokens: Int {
        if case .reuse(let keep, _) = self { return keep }
        return 0
    }
}

enum MLXPromptCacheRebuildReason: String, Equatable {
    case emptyLedger = "nothing cached yet"
    case shortCommonPrefix = "too little of the prompt matches the cache to be worth keeping"
    case untrimmable = "this model's cache cannot be rewound (recurrent layers or a wrapped sliding window)"
    case misaligned = "the cache and its ledger disagree, so its contents are unknown"
}

enum MLXPromptCache {

    /// Below this, keeping a prefix saves too little to justify the bookkeeping.
    static let defaultMinimumReuse = 256

    /// Hidden kill switch for A/B runs on device. On unless set to false.
    static let enabledDefaultsKey = "mlxPromptCacheEnabled"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// The decision table. Pure: no MLX, so every branch is unit-testable.
    ///
    /// - Parameters:
    ///   - cachedTokens: the ledger, exactly what the cache represents (empty: nothing usable).
    ///   - minimumSuffix: tokens that must be fed even when the prompt matches entirely. At least 1,
    ///     because the model needs a fed token to produce logits. With a repetition penalty it is
    ///     the penalty's context size: the penalty is primed from the last N tokens of the INPUT,
    ///     so feeding at least those keeps it identical to a full read.
    static func decide(
        cachedTokens: [Int],
        promptTokens: [Int],
        minimumSuffix: Int,
        isTrimmable: Bool,
        minimumReuse: Int = defaultMinimumReuse
    ) -> MLXPromptCachePlan {
        guard !cachedTokens.isEmpty else { return .rebuild(.emptyLedger) }
        let common = commonPrefixLength(cachedTokens, promptTokens)
        let keep = min(common, max(0, promptTokens.count - max(1, minimumSuffix)))
        guard keep >= max(1, minimumReuse) else { return .rebuild(.shortCommonPrefix) }
        let trim = cachedTokens.count - keep
        if trim > 0, !isTrimmable { return .rebuild(.untrimmable) }
        return .reuse(keep: keep, trim: trim)
    }

    static func commonPrefixLength(_ a: [Int], _ b: [Int]) -> Int {
        var index = 0
        let limit = min(a.count, b.count)
        while index < limit, a[index] == b[index] { index += 1 }
        return index
    }

    /// Minimum suffix for the given sampling settings — see `decide`.
    static func minimumSuffix(repetitionPenalty: Float?, repetitionContextSize: Int) -> Int {
        repetitionPenalty == nil ? 1 : max(1, repetitionContextSize)
    }

    // MARK: - Applying it

    /// What one call feeds the model, and what it reused.
    struct Preparation {
        let promptTokens: [Int]
        let inputTokens: [Int]
        let plan: MLXPromptCachePlan
        /// Where the new prompt first differs from the ledger (== the ledger length when it extends it).
        let firstDifference: Int
        let previousLedgerCount: Int
        /// The ledger's tokens around `firstDifference`, kept only for the content dump.
        let previousWindow: [Int]
    }

    /// Tokens either side of the first difference that the content dump decodes.
    static let dumpWindow = 24

    /// Readies `slot.cache` for `promptTokens` and returns the tokens to feed. The ledger is cleared
    /// until `settle` runs: while a generation is in flight the cache's contents are not yet known.
    static func prepare(
        slot: MLXPromptCacheSlot,
        promptTokens: [Int],
        model: any LanguageModel,
        parameters: GenerateParameters,
        minimumSuffix: Int,
        minimumReuse: Int = defaultMinimumReuse
    ) throws -> Preparation {
        let previous = slot.tokens
        var plan: MLXPromptCachePlan
        if let cache = slot.cache, cache.first?.offset != previous.count {
            plan = .rebuild(.misaligned)
        } else if let cache = slot.cache {
            plan = decide(cachedTokens: previous, promptTokens: promptTokens,
                          minimumSuffix: minimumSuffix, isTrimmable: canTrimPromptCache(cache),
                          minimumReuse: minimumReuse)
        } else {
            plan = .rebuild(.emptyLedger)
        }

        if case .reuse(let keep, let trim) = plan, let cache = slot.cache {
            let trimmed = trim > 0 ? trimPromptCache(cache, numTokens: trim) : 0
            if trimmed != trim || cache.first?.offset != keep {
                logger.warning("[MLX-CACHE] Rewinding the cache by \(trim) token(s) removed \(trimmed) and left it at \(cache.first?.offset ?? -1), not \(keep). CONSEQUENCE: the cache is rebuilt and this call reads the whole prompt.")
                plan = .rebuild(.misaligned)
            }
        }

        let inputTokens: [Int]
        switch plan {
        case .reuse(let keep, _):
            inputTokens = Array(promptTokens[keep...])
        case .rebuild:
            slot.cache = try makePromptCache(model: model, parameters: parameters)
            inputTokens = promptTokens
        }
        slot.tokens = []
        slot.pendingPromptTokens = promptTokens
        return Preparation(
            promptTokens: promptTokens,
            inputTokens: inputTokens,
            plan: plan,
            firstDifference: commonPrefixLength(previous, promptTokens),
            previousLedgerCount: previous.count,
            previousWindow: window(previous, around: commonPrefixLength(previous, promptTokens))
        )
    }

    static func window(_ tokens: [Int], around index: Int) -> [Int] {
        guard !tokens.isEmpty else { return [] }
        let lower = max(0, min(index, tokens.count) - dumpWindow)
        let upper = min(tokens.count, index + dumpWindow)
        return lower < upper ? Array(tokens[lower..<upper]) : []
    }

    /// One line per call: what was reused, and where the prompt stopped matching. The tokens around
    /// that point are decoded only in content-dump mode, because the prompt can carry file text.
    static func log(_ preparation: Preparation, key: String, tokenizer: any Tokenizer) {
        let total = preparation.promptTokens.count
        let conversation = key.prefix(8)
        switch preparation.plan {
        case .reuse(let keep, let trim):
            let percent = total > 0 ? keep * 100 / total : 0
            logger.info("[MLX-CACHE] \(conversation) reused \(keep)/\(total) prompt tokens (\(percent)%), reading \(total - keep). Rewound \(trim) of \(preparation.previousLedgerCount) cached; the prompt first differs at token \(preparation.firstDifference).")
        case .rebuild(let reason):
            logger.info("[MLX-CACHE] \(conversation) reading the whole \(total)-token prompt: \(reason.rawValue) (\(preparation.previousLedgerCount) cached, first difference at token \(preparation.firstDifference)). CONSEQUENCE: this call saves no prefill time.")
        }

        guard DGLogger.contentDumpsEnabled, preparation.previousLedgerCount > 0,
              preparation.firstDifference < total else { return }
        let before = tokenizer.decode(tokenIds: preparation.previousWindow, skipSpecialTokens: false)
        let after = tokenizer.decode(
            tokenIds: window(preparation.promptTokens, around: preparation.firstDifference),
            skipSpecialTokens: false)
        logger.dumpBlock(
            "[MLX-CACHE]",
            title: "first difference at token \(preparation.firstDifference) of \(total) — cached vs new",
            body: "--- cached ---\n\(before)\n--- new ---\n\(after)")
    }

    enum Settlement: Equatable {
        case kept(tokens: Int)
        case invalidated(String)
    }

    /// Rewinds the cache to the prompt after a generation, so the ledger is exactly the prompt.
    /// Call only once the generation task has ENDED: it mutates the same cache.
    @discardableResult
    static func settle(slot: MLXPromptCacheSlot, succeeded: Bool) -> Settlement {
        let prompt = slot.pendingPromptTokens
        slot.pendingPromptTokens = []
        guard succeeded else {
            slot.invalidate()
            return .invalidated("the generation failed, so the cache's contents are unknown")
        }
        guard let cache = slot.cache, let offset = cache.first?.offset, !prompt.isEmpty else {
            slot.invalidate()
            return .invalidated("no cache or prompt to settle")
        }
        guard offset >= prompt.count else {
            slot.invalidate()
            return .invalidated("the cache stopped at token \(offset) of a \(prompt.count)-token prompt, so the prompt was never fully read")
        }
        let excess = offset - prompt.count
        if excess > 0 {
            guard canTrimPromptCache(cache), trimPromptCache(cache, numTokens: excess) == excess,
                  cache.first?.offset == prompt.count else {
                slot.invalidate()
                return .invalidated("the \(excess) generated token(s) could not be rewound")
            }
        }
        slot.tokens = prompt
        return .kept(tokens: prompt.count)
    }
}

// MARK: - Slot

/// One reusable cache: the KV state plus the ledger of tokens it represents. Owned by one
/// generation at a time (`MLXService` checks it out and back in).
final class MLXPromptCacheSlot: @unchecked Sendable {
    let key: String
    let modelDirectory: URL?
    /// Bumped by `MLXService` on every unload; a slot from an older epoch is never checked back in.
    let epoch: Int
    var cache: [KVCache]?
    /// Exactly what `cache` represents. Empty means nothing in it may be reused.
    var tokens: [Int] = []
    /// The prompt of the generation in flight, settled into `tokens` when it ends.
    var pendingPromptTokens: [Int] = []

    init(key: String, modelDirectory: URL?, epoch: Int) {
        self.key = key
        self.modelDirectory = modelDirectory
        self.epoch = epoch
    }

    func invalidate() {
        cache = nil
        tokens = []
    }
}

// MARK: - Scope

/// Which conversation a model call belongs to. Set in exactly two places, each around ONE call:
/// the ReAct executor's legacy-path generation (an agent iteration) and `ChatExecutor`'s Bot
/// stream (not for workflow nodes). Planning, reflection, synthesis, titles and the memory
/// suggestion pass carry no key and can never evict or overwrite a conversation's cache.
enum MLXPromptCacheScope {
    @TaskLocal static var key: String?
}
