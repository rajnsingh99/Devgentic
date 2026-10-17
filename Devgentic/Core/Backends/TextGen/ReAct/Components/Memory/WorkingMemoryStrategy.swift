// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkingMemoryStrategy.swift
//  Devgentic
//
//  Created by Raj Singh on 11/03/26.
//  Updated: Unified WindowedLinearMemory — budget-aware sliding window for all model tiers.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "WorkingMemory")

/// Defines how volatile working memory is recorded and compiled for the LLM prompt.
protocol WorkingMemoryStrategy: Sendable {
    /// Records a tool execution result with optional media artifacts.
    /// `params` is the serialised JSON arguments string the tool was invoked with —
    /// rendered into the scratchpad so the model can see WHICH inputs produced
    /// each observation, not just the tool name. Without this, two calls with
    /// different paths look identical in the scratchpad and the model retries
    /// the failed input because it can't see what it already attempted.
    mutating func recordObservation(stepId: Int, toolCallId: String, toolName: String, params: String, result: String, artifacts: [MediaArtifact])

    /// Records a system-level alert or error.
    mutating func recordSystemAlert(msg: String)

    /// Records the LLM's own reasoning for a step (step.reasoning). Persisted to
    /// the compiled scratchpad so the model sees its prior thought chain in
    /// subsequent iterations — fixes the "reasoning amnesia" where each iteration's
    /// monologue was previously only yielded to the UI.
    ///
    /// Empty / whitespace-only strings are ignored (no-op).
    mutating func recordReasoning(stepId: Int, text: String)

    /// Compiles the collected logs into a string for prompt injection.
    func compileForPrompt() -> String

    /// Returns the current budget utilization as a ratio (0.0 = empty, 1.0 = at budget, >1.0 = over budget).
    /// Strategies without a budget concept should return 0.0.
    var budgetUtilization: Double { get }

    /// The most characters one recorded result keeps. `Int.max` for strategies that never cut —
    /// the executor compares against it to report scratchpad-path cuts to `ContextCutLog`.
    var perResultLimit: Int { get }

    /// Resets the memory.
    mutating func clear()
}

extension WorkingMemoryStrategy {
    var perResultLimit: Int { Int.max }
}

// MARK: - Memory Budget Configuration

/// Encapsulates all budget parameters for the working memory scratchpad.
/// Created via `derive(contextWindow:tier:)` so callers only need model metadata.
struct MemoryBudgetConfig: Sendable {
    /// Total character budget for the compiled scratchpad.
    let totalBudgetChars: Int
    /// Max characters per single observation entry (truncated at record time).
    let perEntryCap: Int
    /// Number of most-recent observations kept at full fidelity (up to perEntryCap).
    let fullFidelityWindow: Int
    /// Max system alerts retained in compiled output.
    let maxSystemAlerts: Int

    /// Never size the scratchpad below this, even when the fixed prompt has already eaten the budget.
    static let minimumTotalChars = 2_000

    /// Derives the scratchpad budget: WHATEVER ROOM THE PROMPT LEAVES, and one result may use all of it.
    ///
    /// The room is the same payload budget the native path works to (`PromptFitCheck
    /// .nativePayloadCharBudget` — 75% of the window, the rest reserved for the reply) minus
    /// `reservedChars`, the prompt parts that do not change during a run: instructions, history,
    /// context blocks, tool text, the task. The scratchpad is the only part that grows.
    ///
    /// ⚠️⚠️ THIS WAS A FIXED 8–15% OF THE WINDOW until 2026-09-24, with a per-entry cap of that ÷
    /// `maxIterations` — 200 characters on an 8K model — on every MLX run in Chat, Code and
    /// workflows, whatever room was actually free. The user's rule since then: no limit below what
    /// fits. So `perEntryCap == totalBudgetChars`; when entries outgrow the total, older ones are
    /// compressed to one line (the scratchpad's equivalent of native compaction), not cut short.
    ///
    /// The native tool-call path is sized by `ToolResultBudget` instead.
    static func derive(contextWindow: Int, tier: ModelTier, reservedChars: Int = 0) -> MemoryBudgetConfig {
        // Guard against corrupted metadata: floor contextWindow at 2048 tokens.
        let safeContextWindow = max(2048, contextWindow)
        let room = PromptFitCheck.nativePayloadCharBudget(forContextWindow: safeContextWindow) - max(0, reservedChars)
        let totalBudgetChars = max(minimumTotalChars, room)

        // Full-fidelity window: frontier models keep more recent entries intact.
        let fullFidelityWindow: Int = tier.isFrontier ? 5 : 3

        return MemoryBudgetConfig(
            totalBudgetChars: totalBudgetChars,
            perEntryCap: totalBudgetChars,
            fullFidelityWindow: fullFidelityWindow,
            maxSystemAlerts: 3
        )
    }
}

// MARK: - Unified Working Memory Implementation

/// A budget-aware working memory strategy that replaces the former `SummarizedLinearMemory`
/// and `HighContextLinearMemory` with a single adaptive implementation.
///
/// Behavior adapts to the model's context window via `MemoryBudgetConfig`:
/// - **Recording**: Each observation result is truncated to `perEntryCap` at write time.
/// - **Compilation**: Recent observations (last `fullFidelityWindow`) render at full detail;
///   older observations compress to one-line summaries. System alerts are capped.
/// - **Eviction**: If compiled output exceeds `totalBudgetChars`, oldest compressed entries
///   are dropped from the front with an eviction marker.
///
/// For frontier models (70B+, 128K context), the budget is large enough that truncation and
/// eviction rarely activate — matching the previous `HighContextLinearMemory` behavior.
/// For tiny models (< 4B, 4K context), aggressive caps and early eviction prevent context overflow.
///
/// **Thread safety**: This is a value type (struct). Each executor/capability receives its own
/// copy via Swift's value semantics. No shared mutable state across actor boundaries.
struct WindowedLinearMemory: WorkingMemoryStrategy {

    var perResultLimit: Int { config.perEntryCap }

    /// Which part of an oversized result is kept — the same policy the native path uses.
    var cutPolicy = ToolCutPolicy()

    // MARK: - Internal Types

    private enum Entry: Sendable {
        case observation(ObservationRecord)
        case systemAlert(String)
        case reasoning(ReasoningRecord)
    }

    private struct ObservationRecord: Sendable {
        let stepId: Int
        let toolCallId: String
        let toolName: String
        let params: String       // Serialised JSON args, stored pre-truncated to paramsCap
        let result: String       // Stored pre-truncated to perEntryCap
        let artifactCount: Int   // Metadata only — artifacts aren't injected into prompts
    }

    /// Model-authored reasoning for a step. Rendered into the scratchpad so the
    /// model sees its prior monologue across iterations — addresses the reasoning
    /// amnesia gap where each iteration started with no trace of the last one's thinking.
    private struct ReasoningRecord: Sendable {
        let stepId: Int
        let text: String         // Stored pre-truncated to perEntryCap
    }

    // MARK: - Constants

    /// Suffix appended to truncated results. Budget math accounts for this length.
    private static let truncationSuffix = "...[truncated]"

    /// Separator between compiled lines.
    private static let lineSeparator = "\n\n"

    /// Hard cap on stored params strings. Large enough for paths and search terms
    /// (the common case ~30-80 chars); truncates write_file-style content payloads
    /// that would otherwise dominate the per-entry budget. Independent of
    /// `perEntryCap` so growing the result budget doesn't proportionally bloat
    /// params storage — params are a disambiguator, not the primary signal.
    private static let paramsCap = 200

    // MARK: - State

    private let config: MemoryBudgetConfig
    private var entries: [Entry] = []

    init(config: MemoryBudgetConfig) {
        self.config = config
    }

    // MARK: - Budget Observability

    /// Estimates budget utilization without full recompilation.
    /// Uses stored entry sizes for an O(n) lightweight estimate, avoiding the
    /// double-compilation cost of calling compileForPrompt().
    var budgetUtilization: Double {
        guard config.totalBudgetChars > 0 else { return 0.0 }

        var estimatedSize = 0
        var stepEntryCount = 0  // observations + reasonings share the fidelity window
        let separatorLen = Self.lineSeparator.count
        // G10: mirror compileForPrompt's dedup so the estimate matches the actual
        // rendered size. Without this, repeated tool calls (e.g. qwen-coder looping on
        // project_tree) inflate the estimate to full-render size for every duplicate
        // and trigger false memory-pressure alerts while actual compile output stays small.
        var seenObsKeys: Set<String> = []
        var alertMessages: [String] = []

        for entry in entries {
            switch entry {
            case .observation(let rec):
                stepEntryCount += 1
                // Dedup key now includes params hash so two calls with different
                // arguments don't false-positive collapse on a coincidentally
                // identical result (e.g. two empty-directory listings).
                let key = "\(rec.toolName)|\(rec.params.hashValue)|\(rec.result.hashValue)"
                if seenObsKeys.contains(key) {
                    // Later occurrence — compile will emit a pointer line carrying the
                    // tool signature with params, so size scales with params length.
                    estimatedSize += 100 + rec.params.count
                } else {
                    seenObsKeys.insert(key)
                    if stepEntryCount > entries.count - config.fullFidelityWindow {
                        estimatedSize += rec.result.count + rec.params.count + 40
                    } else {
                        estimatedSize += min(120, rec.result.count) + rec.params.count + 30
                    }
                }
                estimatedSize += separatorLen
            case .reasoning(let rec):
                stepEntryCount += 1
                if stepEntryCount > entries.count - config.fullFidelityWindow {
                    estimatedSize += rec.text.count + 25
                } else {
                    estimatedSize += min(120, rec.text.count) + 20 // compressed one-liner
                }
                estimatedSize += separatorLen
            case .systemAlert(let msg):
                // ⚠️ NOT sized here. Collected and sized after the loop through the same
                // `renderableAlerts` the compile path uses — see below.
                alertMessages.append(msg)
            }
        }

        // ⚠️ Alerts are sized from what will actually RENDER, not from what was recorded.
        // This arm previously added every stored alert's bytes while `compileForPrompt` emitted at
        // most `maxSystemAlerts` of them — so a run that recorded 11 alerts charged the budget for
        // 11 and rendered 3. That phantom weight is what drove a real 2026-09-13 run to report
        // "176% of scratchpad budget used": the estimate crossed 1.0, the executor's pressure
        // branch recorded ANOTHER alert, and that alert's bytes pushed the estimate higher still.
        // A self-reinforcing loop, powered entirely by lines the model never saw.
        //
        // This is the same obligation the G10 comment above states for observations, on the axis it
        // was never applied to. Sharing `renderableAlerts` with the compile path is what keeps the
        // two from drifting again.
        for rendered in Self.renderableAlerts(alertMessages, cap: config.maxSystemAlerts) {
            estimatedSize += rendered.count + 20 // "[SYSTEM ALERT] " prefix
            estimatedSize += separatorLen
        }

        return Double(estimatedSize) / Double(config.totalBudgetChars)
    }

    /// Chars of the newest `fullFidelityWindow − 1` step entries — the ones that, with the entry being
    /// recorded, form the full-fidelity window `compileForPrompt` never evicts (CR-12).
    private func unevictableRecentChars() -> Int {
        let keepPrior = max(0, config.fullFidelityWindow - 1)
        guard keepPrior > 0 else { return 0 }
        var total = 0
        var counted = 0
        for entry in entries.reversed() where counted < keepPrior {
            switch entry {
            case .observation(let rec): total += rec.result.count + rec.params.count; counted += 1
            case .reasoning(let rec): total += rec.text.count; counted += 1
            case .systemAlert: continue
            }
        }
        return total
    }

    // MARK: - Protocol Conformance

    mutating func recordObservation(stepId: Int, toolCallId: String, toolName: String, params: String, result: String, artifacts: [MediaArtifact]) {
        let suffixLen = Self.truncationSuffix.count

        // Same cut as the native path: the MIDDLE goes, with a note naming what was removed and how
        // to get it — a head-only cut dropped a build's final error.
        // ⚠️⚠️ NOT `perEntryCap` alone (readiness CR-12). That equals the WHOLE budget, while eviction
        // only ever removes OLD lines — the newest `fullFidelityWindow` entries are never evicted. So
        // three large results in a row each kept the whole budget and the scratchpad shipped at ~3×.
        // The room that is free is the budget minus the recent entries eviction cannot touch.
        let limit = min(config.perEntryCap,
                        ToolResultBudget.limit(payloadBudgetChars: config.totalBudgetChars,
                                               protectedChars: unevictableRecentChars(),
                                               resultsInBatch: 1))
        let cappedResult = ToolResultBudget.fit(result, limit: limit,
                                                strategy: cutPolicy.strategy(forTool: toolName))

        // Params get an independent, smaller cap. Large params (e.g. write_file
        // content) shouldn't crowd out the result they produced.
        let cappedParams: String
        if params.count > Self.paramsCap {
            let prefixLen = max(0, Self.paramsCap - suffixLen)
            cappedParams = String(params.prefix(prefixLen)) + Self.truncationSuffix
        } else {
            cappedParams = params
        }

        let record = ObservationRecord(
            stepId: stepId,
            toolCallId: toolCallId,
            toolName: toolName,
            params: cappedParams,
            result: cappedResult,
            artifactCount: artifacts.count
        )
        entries.append(.observation(record))
    }

    mutating func recordSystemAlert(msg: String) {
        entries.append(.systemAlert(msg))
    }

    mutating func recordReasoning(stepId: Int, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Truncate to the same perEntryCap used for observations so a single
        // verbose monologue can't monopolize the scratchpad budget.
        let capped: String
        let suffixLen = Self.truncationSuffix.count
        if trimmed.count > config.perEntryCap {
            let prefixLen = max(0, config.perEntryCap - suffixLen)
            capped = String(trimmed.prefix(prefixLen)) + Self.truncationSuffix
        } else {
            capped = trimmed
        }

        entries.append(.reasoning(ReasoningRecord(stepId: stepId, text: capped)))
    }

    /// Lightweight wrapper so reasoning and observations can share the old/recent
    /// windowing logic without duplicating control flow. Insertion order from
    /// `entries` is preserved.
    private enum StepEntry {
        case observation(ObservationRecord)
        case reasoning(ReasoningRecord)
    }

    /// The alert lines the prompt will actually carry: byte-identical alerts collapsed to one,
    /// then capped to the most recent `cap`.
    ///
    /// ⚠️ ONE definition, called by BOTH `compileForPrompt` and `budgetUtilization`. That is not
    /// tidiness — `:195-198` records that G10's observation dedup had to be mirrored into the
    /// estimator or it "trigger[ed] false memory-pressure alerts while actual compile output stays
    /// small". The alert arm had never mirrored even the existing cap, so a 14-iteration run
    /// counted ~11 alerts of phantom size against a budget that renders at most 3. Sharing the
    /// function makes that class of drift unrepresentable rather than merely discouraged.
    ///
    /// ⚠️ **Keep the LAST occurrence, and dedupe BEFORE the cap.** Both halves are load-bearing:
    ///   • Last, because alerts render at the very end of the prompt in insertion order, so a
    ///     re-raised alert must reclaim its recency slot rather than stay pinned behind staler
    ///     ones. The forward-iterating `Set` idiom keeps the FIRST occurrence, looks identical,
    ///     and silently drops the newest alert on a `[X, B, C, D, X]` shape.
    ///   • Before, because capping first spends slots on repeats: `[A, P, P, P, M]` with cap 3
    ///     yields `[P, M]` (2 distinct, `A` lost) if capped first, and `[A, P, M]` (3 distinct)
    ///     if deduped first. Same slots, never fewer distinct alerts.
    ///
    /// ⚠️ **The repeat COUNT is preserved, never dropped.** Both other collapses in this file keep
    /// their evidence — `failed \(count)x` at :400 and `IDENTICAL TO Step \(firstSeen)` at :404 —
    /// and an alert is the one channel carrying escalation ("this has now failed three times").
    /// Rendering `(repeated Nx)` makes the collapse losslessly compressive: it carries exactly what
    /// the duplicate lines carried, in fewer bytes. Without it this would be the first lossy
    /// collapse in the file, and it would flatten two real signals — the skip/fallback alerts,
    /// where the repeat IS the message, and denial alerts, which name the tool but not the
    /// arguments (`ReActAgentExecutor.swift:1040`) and so are byte-identical across genuinely
    /// different user decisions.
    ///
    /// ⚠️ Exact byte match only — no trimming, no casefolding. `unknownToolName` echoes the model's
    /// attempted spelling, so normalising would merge two different hallucinated names; matching a
    /// payload by shape rather than identity is this codebase's recidivist defect.
    static func renderableAlerts(_ all: [String], cap: Int) -> [String] {
        guard cap > 0, !all.isEmpty else { return [] }

        var occurrences: [String: Int] = [:]
        for alert in all { occurrences[alert, default: 0] += 1 }

        // Walk backwards so the FIRST thing seen is the LAST occurrence.
        var seen: Set<String> = []
        var newestFirst: [String] = []
        for alert in all.reversed() where seen.insert(alert).inserted {
            newestFirst.append(alert)
        }

        return newestFirst.prefix(cap).reversed().map { alert in
            let count = occurrences[alert] ?? 1
            return count > 1 ? "\(alert) (repeated \(count)x)" : alert
        }
    }

    func compileForPrompt() -> String {
        guard !entries.isEmpty else { return "No actions taken yet." }

        // Step 1: Separate system alerts from step-linked entries (observations + reasonings).
        // Step entries keep their original insertion order so a step's reasoning renders
        // immediately before that step's tool observations in the final scratchpad.
        var allAlerts: [String] = []
        var stepEntries: [StepEntry] = []

        for entry in entries {
            switch entry {
            case .observation(let rec):
                stepEntries.append(.observation(rec))
            case .reasoning(let rec):
                stepEntries.append(.reasoning(rec))
            case .systemAlert(let msg):
                allAlerts.append(msg)
            }
        }

        // Step 2: Collapse byte-identical alerts (keeping the most recent occurrence and its
        // repeat count), then cap to the most recent N. See `renderableAlerts` for why the order
        // of those two operations is load-bearing.
        let recentAlerts = Self.renderableAlerts(allAlerts, cap: config.maxSystemAlerts)

        // Step 3: Partition step entries into "old" (compressed) and "recent" (full fidelity).
        // Reasoning and observations share the window — a step's reasoning + its observations
        // typically live together and age together.
        let splitIndex = max(0, stepEntries.count - config.fullFidelityWindow)
        let oldEntries = Array(stepEntries.prefix(splitIndex))
        let recentEntries = Array(stepEntries.suffix(from: splitIndex))

        // Step 4: Collapse consecutive identical errors in old observations.
        // Only applies to observations (reasoning never "repeats" as an error pattern).
        // This prevents error cascades from consuming budget and evicting useful history.
        // Error-collapse now requires SAME params too — two failures with different
        // arguments are distinct exploration attempts and should stay separate.
        enum CollapsedOld {
            case observation(firstStep: Int, lastStep: Int, toolName: String, params: String, result: String, count: Int)
            case reasoning(ReasoningRecord)
        }
        var collapsedOld: [CollapsedOld] = []

        for entry in oldEntries {
            switch entry {
            case .observation(let obs):
                let isError = obs.result.hasPrefix("System Error") || obs.result.hasPrefix("System Security")
                if isError,
                   case .observation(let fs, _, let tn, let tp, let res, let c) = collapsedOld.last,
                   tn == obs.toolName,
                   tp == obs.params,
                   res == obs.result {
                    collapsedOld[collapsedOld.count - 1] = .observation(
                        firstStep: fs, lastStep: obs.stepId, toolName: tn, params: tp, result: res, count: c + 1
                    )
                } else {
                    collapsedOld.append(.observation(
                        firstStep: obs.stepId, lastStep: obs.stepId, toolName: obs.toolName, params: obs.params, result: obs.result, count: 1
                    ))
                }
            case .reasoning(let rec):
                collapsedOld.append(.reasoning(rec))
            }
        }

        // Build output lines with tracked sizes for O(n) eviction.
        var oldLines: [(line: String, charCount: Int)] = []
        var protectedLines: [String] = []

        // G10: Redundancy dedup across old + recent. Tracks the first step at which
        // each unique (toolName, paramsHash, resultHash) combination was rendered at
        // full detail; later occurrences become pointer lines ("IDENTICAL TO Step M")
        // so the model sees an explicit signal that it wasted a call, and so the
        // scratchpad doesn't spend budget re-rendering the same 8KB tree output twice.
        //
        // Keying on params + result eliminates the false-positive collision where two
        // calls with different paths happen to produce identical output (e.g. two
        // empty directories). Without params in the key, the second call would be
        // mislabeled as redundant and the model loses signal that it's exploring
        // different inputs.
        var seenFirstStep: [String: Int] = [:]

        func dedupKey(toolName: String, params: String, result: String) -> String {
            return "\(toolName)|\(params.hashValue)|\(result.hashValue)"
        }

        // Render collapsed old entries as compressed one-liners.
        for group in collapsedOld {
            let line: String
            switch group {
            case .observation(let fs, let ls, let toolName, let params, let result, let count):
                let signature = renderToolSignature(toolName: toolName, params: params)
                if count > 1 {
                    // Error-collapse group — keep existing "failed Nx" form.
                    // Seed the dedup tracker so a later identical output still points back here.
                    let key = dedupKey(toolName: toolName, params: params, result: result)
                    if seenFirstStep[key] == nil { seenFirstStep[key] = fs }
                    line = "- [Steps \(fs)-\(ls)] \(signature) failed \(count)x \u{2192} \(compressSummary(result))"
                } else {
                    let key = dedupKey(toolName: toolName, params: params, result: result)
                    if let firstSeen = seenFirstStep[key] {
                        line = "- [Step \(fs)] \(signature) \u{2192} IDENTICAL TO Step \(firstSeen) (redundant call)"
                    } else {
                        seenFirstStep[key] = fs
                        line = "- [Step \(fs)] \(signature) \u{2192} \(compressSummary(result))"
                    }
                }
            case .reasoning(let rec):
                line = "- [Step \(rec.stepId) thought] \(compressSummary(rec.text))"
            }
            oldLines.append((line, line.count))
        }

        // Visual separator between compressed history and recent detail.
        if !oldEntries.isEmpty && !recentEntries.isEmpty {
            protectedLines.append("--- Recent observations ---")
        }

        // Render recent entries at full fidelity.
        //
        // Prompt-render DOES NOT include `(id: <UUID>)` — small-capacity models
        // (Q4 3B/8B) parrot the UUID into subsequent tool-call content, polluting
        // write_file args and other downstream operations. The toolCallId stays in
        // memory for log correlation and debugging; just not surfaced to the model.
        for entry in recentEntries {
            switch entry {
            case .observation(let obs):
                let signature = renderToolSignature(toolName: obs.toolName, params: obs.params)
                let key = dedupKey(toolName: obs.toolName, params: obs.params, result: obs.result)
                if let firstSeen = seenFirstStep[key] {
                    // G10: This exact (tool, params, output) already appeared at Step
                    // `firstSeen`. Surface the redundancy explicitly instead of
                    // re-rendering the full output.
                    protectedLines.append("- [Step \(obs.stepId)] \(signature) \u{2192} IDENTICAL TO Step \(firstSeen) (redundant call, output omitted)")
                } else {
                    seenFirstStep[key] = obs.stepId
                    let artifactNote = obs.artifactCount > 0 ? " [\(obs.artifactCount) artifact(s)]" : ""
                    protectedLines.append("- [Step \(obs.stepId)] \(signature):\n\(obs.result)\(artifactNote)")
                }
            case .reasoning(let rec):
                protectedLines.append("- [Step \(rec.stepId) thought]\n\(rec.text)")
            }
        }

        // Append system alerts at the end (high visibility for the LLM).
        for alert in recentAlerts {
            protectedLines.append("- [SYSTEM ALERT] \(alert)")
        }

        // Step 5: O(n) sliding window eviction on total budget.
        // Calculate total size: old lines + separators + protected block.
        let separatorLen = Self.lineSeparator.count
        let protectedBlock = protectedLines.joined(separator: Self.lineSeparator)
        let protectedSize = protectedBlock.count

        // Calculate total old lines size including separators between them.
        var totalOldSize = oldLines.reduce(0) { $0 + $1.charCount }
        if !oldLines.isEmpty {
            totalOldSize += (oldLines.count - 1) * separatorLen // separators between old lines
            totalOldSize += separatorLen // separator between old block and protected block
        }

        let totalSize = totalOldSize + protectedSize

        if totalSize > config.totalBudgetChars && !oldLines.isEmpty {
            // Evict from front (oldest) until under budget. O(n) — subtract sizes, no re-joining.
            var currentSize = totalSize
            var evicted = 0

            while evicted < oldLines.count && currentSize > config.totalBudgetChars {
                // Remove the oldest line + its separator
                currentSize -= oldLines[evicted].charCount
                currentSize -= separatorLen // the separator that followed/preceded this line
                evicted += 1
            }

            if evicted > 0 {
                oldLines = Array(oldLines.dropFirst(evicted))
                let marker = "[SYSTEM: \(evicted) earlier observation(s) evicted for memory efficiency]"
                oldLines.insert((marker, marker.count), at: 0)
                logger.debug("Evicted \(evicted) observation(s) from working memory. Budget: \(config.totalBudgetChars) chars.")
            }
        }

        // Step 6: Assemble final output.
        //
        // ⚠️ NO separator re-evaluation here, and that is load-bearing rather than an omission.
        // This used to branch on `allParts.isEmpty` and strip "--- Recent observations ---",
        // under the rationale "all old lines were evicted, so there's no compressed section to
        // separate from". Both halves of that were wrong:
        //
        //   1. The separator can never reach that branch. It is appended to `protectedLines` only
        //      when `!oldEntries.isEmpty && !recentEntries.isEmpty` (Step 3), and a non-empty
        //      `oldEntries` always yields at least one line in `oldLines` — so whenever the
        //      separator exists, `allParts` is non-empty and the branch is not taken. The branch
        //      DID run often (any run shorter than the full-fidelity window, where no separator was
        //      ever added), so the filter executed and removed nothing, every time.
        //   2. Even after a total eviction the separator is still CORRECT, because eviction does
        //      not empty the compressed section — it replaces it with the
        //      `[SYSTEM: N earlier observation(s) evicted…]` marker, which `oldLines.insert(at: 0)`
        //      puts exactly where the old lines were. The separator then separates that marker from
        //      the recent block, which is what a reader needs.
        //
        // Verified before removal: an `assert` placed inside the branch, asserting the filter
        // removed nothing, survived 1,547 Backends + Integration tests without tripping.
        // `testSeparator_AbsentWhenAllRecent` covers the short-run path this branch used to take,
        // and `testEviction_MarkerReplacesTheOldBlockAndRecentSurvives` covers the total-eviction
        // path it never took.
        var allParts: [String] = oldLines.map(\.line)
        allParts.append(contentsOf: protectedLines)

        return allParts.joined(separator: Self.lineSeparator)
    }

    mutating func clear() {
        entries.removeAll()
    }

    // MARK: - Helpers

    /// Compresses a full result string into a one-line summary (max ~120 chars).
    private func compressSummary(_ result: String) -> String {
        let oneLine = result.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if oneLine.count <= 120 {
            return oneLine
        }
        return String(oneLine.prefix(117)) + "..."
    }

    /// Renders a tool name + serialised params as a compact call signature like
    /// `list_directory({"path":"/Users/alice/Acme"})`. Empty / `{}` params render
    /// as just the bare tool name so synthetic observations seeded by capability
    /// decorators (Planning, Reflexion — which use `params: ""`) don't show
    /// trailing empty parens.
    private func renderToolSignature(toolName: String, params: String) -> String {
        let trimmed = params.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "{}" {
            return toolName
        }
        return "\(toolName)(\(trimmed))"
    }
}
