//
//  WorkingMemoryStrategy.swift
//  Devgentic
//
//  Created by Raj Singh on 11/03/26.
//  Updated: Unified WindowedLinearMemory — budget-aware sliding window for all model tiers.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "WorkingMemory")

/// Defines how volatile working memory is recorded and compiled for the LLM prompt.
protocol WorkingMemoryStrategy: Sendable {
    /// Records a tool execution result with optional media artifacts.
    mutating func recordObservation(stepId: Int, toolCallId: String, toolName: String, result: String, artifacts: [MediaArtifact])

    /// Records a system-level alert or error.
    mutating func recordSystemAlert(msg: String)

    /// Compiles the collected logs into a string for prompt injection.
    func compileForPrompt() -> String

    /// Returns the current budget utilization as a ratio (0.0 = empty, 1.0 = at budget, >1.0 = over budget).
    /// Strategies without a budget concept should return 0.0.
    var budgetUtilization: Double { get }

    /// Resets the memory.
    mutating func clear()
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
    }

    private struct ObservationRecord: Sendable {
        let stepId: Int
        let toolCallId: String
        let toolName: String
        let result: String       // Stored pre-truncated to perEntryCap
        let artifactCount: Int   // Metadata only — artifacts aren't injected into prompts
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
        var observationCount = 0
        let separatorLen = Self.lineSeparator.count

        for entry in entries {
            switch entry {
            case .observation(let rec):
                observationCount += 1
                // Recent entries are rendered at full fidelity; older entries compressed to ~120 chars.
                if observationCount > entries.count - config.fullFidelityWindow {
                    estimatedSize += rec.result.count + 40 // result + step/tool/id overhead
                } else {
                    estimatedSize += min(120, rec.result.count) + 30 // compressed one-liner
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

    func compileForPrompt() -> String {
        guard !entries.isEmpty else { return "No actions taken yet." }

        // Step 1: Separate system alerts and observations.
        var allAlerts: [String] = []
        var observations: [ObservationRecord] = []

        for entry in entries {
            switch entry {
            case .observation(let rec):
                observations.append(rec)
            case .systemAlert(let msg):
                allAlerts.append(msg)
            }
        }

        // Step 2: Cap system alerts to most recent N.
        let recentAlerts = Array(allAlerts.suffix(config.maxSystemAlerts))

        // Step 3: Partition observations into "old" (compressed) and "recent" (full fidelity).
        let splitIndex = max(0, observations.count - config.fullFidelityWindow)
        let oldObservations = Array(observations.prefix(splitIndex))
        let recentObservations = Array(observations.suffix(from: splitIndex))

        // Step 4: Collapse consecutive identical errors in old observations.
        // This prevents error cascades (e.g., same hallucinated tool retried 5 times) from
        // consuming budget and evicting useful observations.
        var collapsedOld: [(firstStep: Int, lastStep: Int, toolName: String, result: String, count: Int)] = []

        for obs in oldObservations {
            let isError = obs.result.hasPrefix("System Error") || obs.result.hasPrefix("System Security")
            if isError,
               let last = collapsedOld.last,
               last.toolName == obs.toolName,
               last.result == obs.result {
                // Same tool + same error — merge into existing group.
                collapsedOld[collapsedOld.count - 1].lastStep = obs.stepId
                collapsedOld[collapsedOld.count - 1].count += 1
            } else {
                collapsedOld.append((obs.stepId, obs.stepId, obs.toolName, obs.result, 1))
            }
        }

        // Build output lines with tracked sizes for O(n) eviction.
        var oldLines: [(line: String, charCount: Int)] = []
        var protectedLines: [String] = []

        // Render collapsed old observations as compressed one-liners.
        for group in collapsedOld {
            let line: String
            if group.count > 1 {
                line = "- [Steps \(group.firstStep)-\(group.lastStep)] \(group.toolName) failed \(group.count)x \u{2192} \(compressSummary(group.result))"
            } else {
                line = "- [Step \(group.firstStep)] \(group.toolName) \u{2192} \(compressSummary(group.result))"
            }
            oldLines.append((line, line.count))
        }

        // Visual separator between compressed history and recent detail.
        if !oldObservations.isEmpty && !recentObservations.isEmpty {
            protectedLines.append("--- Recent observations ---")
        }

        // Render recent observations at full fidelity.
        for obs in recentObservations {
            let artifactNote = obs.artifactCount > 0 ? " [\(obs.artifactCount) artifact(s)]" : ""
            protectedLines.append("- [Step \(obs.stepId)] \(obs.toolName) (id: \(obs.toolCallId)):\n\(obs.result)\(artifactNote)")
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
