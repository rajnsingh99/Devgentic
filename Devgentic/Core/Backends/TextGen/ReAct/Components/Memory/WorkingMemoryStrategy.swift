// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkingMemoryStrategy.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "WorkingMemory")

/// Defines how volatile working memory is recorded and compiled for the LLM prompt.
protocol WorkingMemoryStrategy: Sendable {
    /// Records a tool execution result with optional media artifacts.
    /// `params` is the serialised JSON arguments string, rendered into the scratchpad so the model can see which inputs
    /// produced each observation.
    mutating func recordObservation(stepId: Int, toolCallId: String, toolName: String, params: String, result: String, artifacts: [MediaArtifact])

    /// Records a system-level alert or error.
    mutating func recordSystemAlert(msg: String)

    /// Records the LLM's own reasoning for a step; it is persisted to the compiled scratchpad so later iterations see
    /// it.
    /// Empty or whitespace-only text is ignored.
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

    /// Derives the scratchpad budget: whatever room the prompt leaves, and one result may use all of it.
    /// The room is `PromptFitCheck.nativePayloadCharBudget` minus `reservedChars` (the parts fixed for a run).
    /// `perEntryCap == totalBudgetChars`; older entries compress to one line. The native path uses `ToolResultBudget`.
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

/// A budget-aware working memory strategy that adapts to the model's context window via `MemoryBudgetConfig`.
/// Results truncate on write, older observations compress to summaries, and the oldest are evicted over budget.
/// A value type: each executor or capability gets its own copy.
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

    /// Hard cap on stored params strings: large enough for paths and search terms, truncating content payloads.
    /// Independent of `perEntryCap`, since params only disambiguate calls.
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
        // Mirrors `compileForPrompt`'s dedup so the size estimate matches the rendered size and raises no false
        // memory-pressure alerts.
        var seenObsKeys: Set<String> = []
        var alertMessages: [String] = []

        for entry in entries {
            switch entry {
            case .observation(let rec):
                stepEntryCount += 1
                // The dedup key includes the params hash so different calls with an identical result do not collapse.
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
                // Not sized here: collected and sized after the loop through the same `renderableAlerts` as the compile path.
                alertMessages.append(msg)
            }
        }

        // Alerts are sized from what will render, not what was recorded, so phantom weight cannot push the estimate over
        // budget in a feedback loop.
        for rendered in Self.renderableAlerts(alertMessages, cap: config.maxSystemAlerts) {
            estimatedSize += rendered.count + 20 // "[SYSTEM ALERT] " prefix
            estimatedSize += separatorLen
        }

        return Double(estimatedSize) / Double(config.totalBudgetChars)
    }

    /// Chars of the newest `fullFidelityWindow - 1` step entries, which with the entry being recorded form the window
    /// `compileForPrompt` never evicts.
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

        // Cuts the middle with a note naming what was dropped; the limit is capped by the room left after recent entries
        // that cannot be evicted.
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

    // Why: keep the last occurrence and dedupe before the cap; matching is exact bytes, since normalising would merge
    // distinct hallucinated tool names.
    /// Returns the alert lines the prompt will carry: byte-identical alerts collapsed, repeat count preserved, then
    /// capped to the newest `cap`.
    /// Shared by `compileForPrompt` and `budgetUtilization` so the estimate cannot drift from the render.
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

        // Separates system alerts from step-linked entries; step entries keep insertion order so reasoning precedes its
        // observations.
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

        // Collapses byte-identical alerts then caps to the most recent N; the order of those two operations matters (see
        // `renderableAlerts`).
        let recentAlerts = Self.renderableAlerts(allAlerts, cap: config.maxSystemAlerts)

        // Partitions step entries into old (compressed) and recent (full fidelity); reasoning and observations age
        // together.
        let splitIndex = max(0, stepEntries.count - config.fullFidelityWindow)
        let oldEntries = Array(stepEntries.prefix(splitIndex))
        let recentEntries = Array(stepEntries.suffix(from: splitIndex))

        // Collapses consecutive identical errors in old observations; the same params are required, since different
        // arguments are distinct attempts.
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

        // Redundancy dedup across old and recent entries, keyed on (tool, params, result); repeats become "IDENTICAL TO
        // Step M" pointer lines.
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

        // Renders recent entries in full, without the toolCallId, which small models parrot into later tool-call content.
        for entry in recentEntries {
            switch entry {
            case .observation(let obs):
                let signature = renderToolSignature(toolName: obs.toolName, params: obs.params)
                let key = dedupKey(toolName: obs.toolName, params: obs.params, result: obs.result)
                if let firstSeen = seenFirstStep[key] {
                    // This exact (tool, params, output) already appeared at `firstSeen`; surfaces the redundancy instead of
                    // re-rendering the output.
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

        // Assembles the final output. No separator re-evaluation: the separator exists only when the compressed section
        // does, and eviction keeps it.
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

    /// Renders a tool name and serialised params as a compact call signature like
    /// `list_directory({"path":"/Users/alice"})`.
    /// Empty or `{}` params render as the bare tool name, so synthetic observations show no trailing empty parens.
    private func renderToolSignature(toolName: String, params: String) -> String {
        let trimmed = params.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "{}" {
            return toolName
        }
        return "\(toolName)(\(trimmed))"
    }
}
