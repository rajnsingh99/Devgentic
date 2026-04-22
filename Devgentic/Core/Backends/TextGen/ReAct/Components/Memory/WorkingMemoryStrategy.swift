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
    mutating func recordObservation(stepId: Int, toolCallId: String, toolName: String, result: String, artifacts: [MediaArtifact])

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

    /// Applies the strategy's per-entry cap to a raw tool output string. Used by the
    /// native-turn path, which serializes tool results directly into provider messages
    /// and needs the same budget policy as `recordObservation`'s stored results —
    /// without going through the full scratchpad compile pipeline.
    ///
    /// Default implementation returns the input unchanged (strategies without a cap
    /// concept). `WindowedLinearMemory` overrides to apply its `perEntryCap`.
    func truncatedResult(for raw: String) -> String

    /// Resets the memory.
    mutating func clear()
}

extension WorkingMemoryStrategy {
    /// Default: no truncation. Strategies that track a budget should override.
    func truncatedResult(for raw: String) -> String { raw }
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

    /// Derives a budget configuration from the model's context window and tier.
    ///
    /// Budget allocation by tier (as percentage of context window tokens, converted to chars at ~4 chars/token):
    /// - tiny/small (2-14B): 8% — leaves room in constrained context windows
    /// - medium (30-40B): 10%
    /// - large/ultra (70B+): 15% — generous allocation, context is plentiful
    ///
    /// Per-entry cap is derived as `totalBudget / maxIterations`, floored at 200 chars.
    static func derive(contextWindow: Int, tier: ModelTier, maxIterations: Int = 15) -> MemoryBudgetConfig {
        // Guard against corrupted metadata: floor contextWindow at 2048 tokens.
        let safeContextWindow = max(2048, contextWindow)
        let safeMaxIterations = max(1, maxIterations)

        let budgetFraction: Double = switch tier {
        case .tiny, .small: 0.08
        case .medium:       0.10
        case .large, .ultra: 0.15
        }

        // Convert token budget to approximate character budget (~4 chars per token).
        let tokenBudget = Int(Double(safeContextWindow) * budgetFraction)
        let totalBudgetChars = tokenBudget * 4

        // Per-entry cap: divide total by expected iterations.
        // Floor at 200 chars so even tiny models get useful observation content.
        let perEntryCap = max(200, totalBudgetChars / safeMaxIterations)

        // Full-fidelity window: frontier models keep more recent entries intact.
        let fullFidelityWindow: Int = tier.isFrontier ? 5 : 3

        return MemoryBudgetConfig(
            totalBudgetChars: totalBudgetChars,
            perEntryCap: perEntryCap,
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
        // codebase_map) inflate the estimate to full-render size for every duplicate
        // and trigger false memory-pressure alerts while actual compile output stays small.
        var seenObsKeys: Set<String> = []

        for entry in entries {
            switch entry {
            case .observation(let rec):
                stepEntryCount += 1
                let key = "\(rec.toolName)|\(rec.result.hashValue)"
                if seenObsKeys.contains(key) {
                    // Later occurrence — compile will emit a ~100-char pointer line.
                    estimatedSize += 100
                } else {
                    seenObsKeys.insert(key)
                    if stepEntryCount > entries.count - config.fullFidelityWindow {
                        estimatedSize += rec.result.count + 40 // result + step/tool/id overhead
                    } else {
                        estimatedSize += min(120, rec.result.count) + 30 // compressed one-liner
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
                estimatedSize += msg.count + 20 // "[SYSTEM ALERT] " prefix
                estimatedSize += separatorLen
            }
        }

        return Double(estimatedSize) / Double(config.totalBudgetChars)
    }

    // MARK: - Protocol Conformance

    mutating func recordObservation(stepId: Int, toolCallId: String, toolName: String, result: String, artifacts: [MediaArtifact]) {
        // Truncate at recording time to bound per-entry storage cost.
        // Account for truncation suffix length so the total stored size stays within perEntryCap.
        let capped: String
        let suffixLen = Self.truncationSuffix.count
        if result.count > config.perEntryCap {
            let prefixLen = max(0, config.perEntryCap - suffixLen)
            capped = String(result.prefix(prefixLen)) + Self.truncationSuffix
        } else {
            capped = result
        }

        let record = ObservationRecord(
            stepId: stepId,
            toolCallId: toolCallId,
            toolName: toolName,
            result: capped,
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

        // Step 2: Cap system alerts to most recent N.
        let recentAlerts = Array(allAlerts.suffix(config.maxSystemAlerts))

        // Step 3: Partition step entries into "old" (compressed) and "recent" (full fidelity).
        // Reasoning and observations share the window — a step's reasoning + its observations
        // typically live together and age together.
        let splitIndex = max(0, stepEntries.count - config.fullFidelityWindow)
        let oldEntries = Array(stepEntries.prefix(splitIndex))
        let recentEntries = Array(stepEntries.suffix(from: splitIndex))

        // Step 4: Collapse consecutive identical errors in old observations.
        // Only applies to observations (reasoning never "repeats" as an error pattern).
        // This prevents error cascades from consuming budget and evicting useful history.
        enum CollapsedOld {
            case observation(firstStep: Int, lastStep: Int, toolName: String, result: String, count: Int)
            case reasoning(ReasoningRecord)
        }
        var collapsedOld: [CollapsedOld] = []

        for entry in oldEntries {
            switch entry {
            case .observation(let obs):
                let isError = obs.result.hasPrefix("System Error") || obs.result.hasPrefix("System Security")
                if isError,
                   case .observation(let fs, _, let tn, let res, let c) = collapsedOld.last,
                   tn == obs.toolName,
                   res == obs.result {
                    collapsedOld[collapsedOld.count - 1] = .observation(
                        firstStep: fs, lastStep: obs.stepId, toolName: tn, result: res, count: c + 1
                    )
                } else {
                    collapsedOld.append(.observation(
                        firstStep: obs.stepId, lastStep: obs.stepId, toolName: obs.toolName, result: obs.result, count: 1
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
        // each unique (toolName, resultHash) combination was rendered at full detail;
        // later occurrences become pointer lines ("IDENTICAL TO Step M") so the model
        // sees an explicit signal that it wasted a call, and so the scratchpad doesn't
        // spend budget re-rendering the same 8KB tree output twice.
        //
        // Keyed on (toolName | resultHash) — params aren't stored in ObservationRecord
        // so we can't key on arg hash, but (toolName, outputHash) identity is already a
        // strong practical match for the common "re-called same tool same path" case.
        // Hash collisions across genuinely-different outputs are vanishingly rare.
        var seenFirstStep: [String: Int] = [:]

        func dedupKey(toolName: String, result: String) -> String {
            return "\(toolName)|\(result.hashValue)"
        }

        // Render collapsed old entries as compressed one-liners.
        for group in collapsedOld {
            let line: String
            switch group {
            case .observation(let fs, let ls, let toolName, let result, let count):
                if count > 1 {
                    // Error-collapse group — keep existing "failed Nx" form.
                    // Seed the dedup tracker so a later identical output still points back here.
                    let key = dedupKey(toolName: toolName, result: result)
                    if seenFirstStep[key] == nil { seenFirstStep[key] = fs }
                    line = "- [Steps \(fs)-\(ls)] \(toolName) failed \(count)x \u{2192} \(compressSummary(result))"
                } else {
                    let key = dedupKey(toolName: toolName, result: result)
                    if let firstSeen = seenFirstStep[key] {
                        line = "- [Step \(fs)] \(toolName) \u{2192} IDENTICAL TO Step \(firstSeen) (redundant call)"
                    } else {
                        seenFirstStep[key] = fs
                        line = "- [Step \(fs)] \(toolName) \u{2192} \(compressSummary(result))"
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
        for entry in recentEntries {
            switch entry {
            case .observation(let obs):
                let key = dedupKey(toolName: obs.toolName, result: obs.result)
                if let firstSeen = seenFirstStep[key] {
                    // G10: This exact (tool, output) already appeared at Step `firstSeen`.
                    // Surface the redundancy explicitly instead of re-rendering the full output.
                    protectedLines.append("- [Step \(obs.stepId)] \(obs.toolName) (id: \(obs.toolCallId)) \u{2192} IDENTICAL TO Step \(firstSeen) (redundant call, output omitted)")
                } else {
                    seenFirstStep[key] = obs.stepId
                    let artifactNote = obs.artifactCount > 0 ? " [\(obs.artifactCount) artifact(s)]" : ""
                    protectedLines.append("- [Step \(obs.stepId)] \(obs.toolName) (id: \(obs.toolCallId)):\n\(obs.result)\(artifactNote)")
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
        // After eviction, the separator between old and recent may need to be re-evaluated.
        // If all old lines were evicted, drop the "--- Recent observations ---" separator
        // since there's no compressed section to separate from.
        var allParts: [String] = oldLines.map(\.line)

        if allParts.isEmpty {
            // All old lines evicted — skip the separator if it was the first protected line.
            let filteredProtected = protectedLines.filter { $0 != "--- Recent observations ---" }
            allParts.append(contentsOf: filteredProtected)
        } else {
            allParts.append(contentsOf: protectedLines)
        }

        return allParts.joined(separator: Self.lineSeparator)
    }

    mutating func clear() {
        entries.removeAll()
    }

    /// Applies the same per-entry cap logic used by `recordObservation`. Exposed so the
    /// native-turn path can truncate tool_result content consistently without going
    /// through `compileForPrompt`'s full render pipeline.
    func truncatedResult(for raw: String) -> String {
        let suffixLen = Self.truncationSuffix.count
        guard raw.count > config.perEntryCap else { return raw }
        let prefixLen = max(0, config.perEntryCap - suffixLen)
        return String(raw.prefix(prefixLen)) + Self.truncationSuffix
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
}
