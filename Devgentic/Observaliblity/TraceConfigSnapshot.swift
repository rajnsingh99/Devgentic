//
//  TraceConfigSnapshot.swift
//  Devgentic
//
//  Per-trace capture of the COMPLETE effective request configuration. This is the
//  single biggest missing piece for offline bug reproduction — without it, a trace
//  tells us "what happened" but not "in what context." With it, the Report Inspector
//  can show exactly which profile, model, tool set, capabilities, memory budget,
//  retry policy, and hardware were in effect when the bug occurred.
//
//  Captured at `TraceRecorder.beginTrace(...)` via `captureConfigSnapshot(...)` and
//  persisted to the `trace_configs` table (1 row per trace, FK cascade-deletes with
//  the parent trace).
//
//  Privacy:
//  - API keys / bot tokens NEVER captured (stripped at the ProviderConfig read).
//  - Instructions are full-text per product decision (diagnostic value > privacy
//    since this is on-device only).
//  - File paths sanitized via `TelemetrySanitizer.sanitizeFull(level: .standard)`
//    at the capture site.
//  - Full snapshot also passes through sanitizer when serialized.
//
//  Extensibility:
//  - Adding a new top-level field: add to the struct + `indexedFields` if it needs
//    its own column, otherwise it lives in `snapshot_json` for free.
//  - New indexed column: add to struct AND to the v3 migration AND to the snapshot
//    JSON encoding. Three places, ~3 lines each.
//

import Foundation
import GRDB
import CryptoKit

// MARK: - Sub-structs

/// Hardware profile captured at trace time. Small subset of `SystemHardwareProfile`
/// focusing on fields useful for diagnosing memory/performance issues.
struct HardwareSnapshot: Codable, Sendable {
    let totalRAMBytes: UInt64
    let availableRAMBytes: UInt64
    let chipFamily: String              // AppleSiliconChip.rawValue (e.g., "M4 Pro")
    let gpuCoreCount: Int
    let effectiveBudgetBytes: UInt64
}

/// Retry-policy summary — flat so it encodes to compact JSON.
struct RetryPolicySnapshot: Codable, Sendable {
    let maxRetries: Int
    let backoffStrategy: String         // "fixed" / "exponential"
}

/// Error-recovery policy summary.
struct ErrorRecoverySnapshot: Codable, Sendable {
    let onToolFailure: String           // "abort" / "skipAndContinue" / "fallbackPrompt"
    let onIterationExhaustion: String   // "synthesizeBestEffort" / "failHard"
    let hasCustomFallbackMessage: Bool
}

/// Attached-file summary — counts + types, never content.
struct AttachedFilesSummary: Codable, Sendable {
    let count: Int
    let totalBytes: Int64
    let fileTypes: [String]             // extensions, e.g. ["swift", "json"]
}

// MARK: - TraceConfigSnapshot

/// Full configuration snapshot taken at the start of a trace.
/// Keys grouped by concern; all grouped together in one struct for atomic persistence.
struct TraceConfigSnapshot: Codable, Sendable {

    // --- Identity ---
    let traceID: String
    let profileID: String               // UUID string
    let profileName: String
    let profileType: String             // bot/agent/workflow/imageGen/code

    // --- Provider + Model ---
    let provider: String                // "openai" / "anthropic" / "ollama" / "mlx" / "google"
    let modelName: String
    let modelTier: String?              // ModelTier.rawValue ("small", "medium", ...)
    let modelContextWindow: Int?
    let modelQuantization: String?      // "Q4_K_M", etc.
    let modelFamily: String?            // "llama3", "mistral", ...
    let modelParameterCount: String?    // "70B", "3B"
    let modelDialect: String            // nativeJSON / mistralXML / reactMarkdown / heuristicJson
    let modelCapability: String         // none / singleAction / parallelActions
    let chatTemplateSource: String      // embedded / extracted / familyFallback
    let stopSequences: [String]
    let thinkingEnabled: Bool
    let advancedConfig: [String: String]  // temperature, topP, maxTokens, etc. (serialized)

    // --- Agent-specific (nil for Bot / ImageGen / Workflow at this layer) ---
    let toolsEnabled: [String]          // tool names (schemas elided)
    let toolsRequireConfirmation: [String]
    let capabilitiesEnabled: [String]   // "planning", "selfReflection", "agentDelegation"
    let instructions: String?           // full text per product decision Q3
    let instructionsLength: Int
    let instructionsHash: String?       // SHA256, truncated — fast equality checks
    let maxIterations: Int?
    let executionTimeoutSec: Double?
    let retryPolicy: RetryPolicySnapshot?
    let errorRecovery: ErrorRecoverySnapshot?
    let historyStrategy: String?        // recentHistory / fullHistory / pointer / hybrid

    // --- Code-mode-specific (nil otherwise) ---
    let codeProjectPath: String?        // sanitized via TelemetrySanitizer
    let codeMemoryLength: Int?          // chars of .devgentic/context.md
    let codeMemoryHash: String?

    // --- Request-time context ---
    let historyTurnCount: Int           // prior message count passed to executor
    let attachedFiles: AttachedFilesSummary

    // --- Environment ---
    let hardware: HardwareSnapshot
    let appVersion: String              // Bundle.main CFBundleShortVersionString
    let appBuildNumber: String
    let osVersion: String               // ProcessInfo operatingSystemVersionString
    let featureFlags: [String: Bool]    // curated list of ciFeature* + structural flags
    let capturedAt: Date

    // MARK: - Factory

    /// Constructs a snapshot from a live BackendRequestConfig + runtime context.
    /// All sensitive data (API keys, tokens) is omitted by design — this factory
    /// never reads those fields off `ProviderConfig`.
    ///
    /// - Parameters:
    ///   - traceID: the trace this snapshot belongs to
    ///   - config: the request config (profile + llmConfig)
    ///   - history: incoming conversation history (for turn count only)
    ///   - files: attached files (for summary only)
    ///   - codeMemory: Code mode's `.devgentic/context.md` content if active
    static func capture(
        traceID: String,
        config: BackendRequestConfig,
        historyTurnCount: Int,
        files: [FileSystemItem],
        codeMemoryContent: String?
    ) -> TraceConfigSnapshot {

        let profile = config.profile

        // --- Per-type extraction ---
        // Workflow profiles delegate to per-node profiles and have no single llmConfig.
        // For those traces we use placeholder "workflow" values — the individual node
        // traces will have their own full snapshots.
        let llmConfig: ProviderConfig?
        let toolsEnabled: [String]
        let toolsRequireConfirmation: [String]
        let capabilitiesEnabled: [String]
        let instructions: String?
        let maxIterations: Int?
        let executionTimeoutSec: Double?
        let retryPolicy: RetryPolicySnapshot?
        let errorRecovery: ErrorRecoverySnapshot?
        let historyStrategy: String?
        let codeProjectPath: String?

        switch profile.details {
        case .bot(let cfg):
            llmConfig = cfg.llmConfig
            toolsEnabled = []
            toolsRequireConfirmation = []
            capabilitiesEnabled = []
            instructions = cfg.instructions
            maxIterations = nil
            executionTimeoutSec = nil
            retryPolicy = nil
            errorRecovery = nil
            historyStrategy = nil
            codeProjectPath = nil

        case .agent(let cfg), .code(let cfg):
            llmConfig = cfg.llmConfig
            toolsEnabled = cfg.tools.filter(\.isEnabled).map(\.name)
            toolsRequireConfirmation = cfg.tools.filter { $0.isEnabled && $0.requiresConfirmation }.map(\.name)
            var caps: [String] = []
            if cfg.capabilities.planning != nil        { caps.append("planning") }
            if cfg.capabilities.selfReflection != nil  { caps.append("selfReflection") }
            if cfg.capabilities.agentDelegation != nil { caps.append("agentDelegation") }
            capabilitiesEnabled = caps
            instructions = cfg.instructions
            maxIterations = cfg.maxIterations
            executionTimeoutSec = cfg.executionTimeout
            retryPolicy = cfg.retryPolicy.map {
                RetryPolicySnapshot(maxRetries: $0.maxRetries, backoffStrategy: $0.backoffStrategy.rawValue)
            }
            errorRecovery = cfg.errorRecovery.map {
                ErrorRecoverySnapshot(
                    onToolFailure: $0.onToolFailure.rawValue,
                    onIterationExhaustion: $0.onIterationExhaustion.rawValue,
                    hasCustomFallbackMessage: $0.fallbackMessage != nil
                )
            }
            historyStrategy = cfg.historyStrategy?.rawValue
            codeProjectPath = cfg.projectPath.map {
                TelemetrySanitizer.sanitizeFull($0, level: .standard)
            }

        case .imageGen(let cfg):
            llmConfig = cfg.llmConfig
            toolsEnabled = []
            toolsRequireConfirmation = []
            capabilitiesEnabled = []
            instructions = nil
            maxIterations = nil
            executionTimeoutSec = nil
            retryPolicy = nil
            errorRecovery = nil
            historyStrategy = nil
            codeProjectPath = nil

        case .workflow:
            llmConfig = nil
            toolsEnabled = []
            toolsRequireConfirmation = []
            capabilitiesEnabled = []
            instructions = nil
            maxIterations = nil
            executionTimeoutSec = nil
            retryPolicy = nil
            errorRecovery = nil
            historyStrategy = nil
            codeProjectPath = nil
        }

        // --- Hardware ---
        let hw = SystemHardwareProfiler.shared.profile
        let hardware = HardwareSnapshot(
            totalRAMBytes: hw.totalRAM,
            availableRAMBytes: hw.availableRAM,
            chipFamily: hw.chipFamily.rawValue,
            gpuCoreCount: hw.gpuCoreCount,
            effectiveBudgetBytes: hw.effectiveBudget
        )

        // --- App / OS version ---
        let info = Bundle.main.infoDictionary ?? [:]
        let appVersion = (info["CFBundleShortVersionString"] as? String) ?? "unknown"
        let appBuild = (info["CFBundleVersion"] as? String) ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        // --- Feature flags (curated — only flags that affect agent behavior) ---
        let d = UserDefaults.standard
        let featureFlags: [String: Bool] = [
            "developerMode":             d.bool(forKey: AppSettings.developerModeKey),
            "intelligenceCore":          d.bool(forKey: AppSettings.isIntelligenceCoreEnabledKey),
            "historyCompaction":         d.object(forKey: AppSettings.ciFeatureHistoryCompactionKey) as? Bool ?? true,
            // Per-family Response Synthesis opt-in (default false — never automatic).
            "responseSynthesisMLX":      d.bool(forKey: AppSettings.ciFeatureResponseSynthesisMLXKey),
            "responseSynthesisOllama":   d.bool(forKey: AppSettings.ciFeatureResponseSynthesisOllamaKey),
            "responseSynthesisRemote":   d.bool(forKey: AppSettings.ciFeatureResponseSynthesisRemoteKey),
            "userPersonal":              d.bool(forKey: AppSettings.ciFeatureUserPersonalKey),
            "ragRewriting":              d.bool(forKey: AppSettings.ciFeatureRAGRewritingKey),
            "suggestion":                d.bool(forKey: AppSettings.ciFeatureSuggestionKey)
        ]

        // --- Instructions hash (short, for equality joins without full-text compare) ---
        let instructionsHash: String?
        let instructionsLength: Int
        if let instr = instructions {
            instructionsLength = instr.count
            instructionsHash = Self.shortHash(instr)
        } else {
            instructionsLength = 0
            instructionsHash = nil
        }

        // --- Code memory ---
        let codeMemoryLength = codeMemoryContent?.count
        let codeMemoryHash = codeMemoryContent.flatMap { Self.shortHash($0) }

        // --- Attached files summary (never content) ---
        // File sizes are pulled from URL resource values at capture time. `try?` so
        // unreadable / nonexistent files simply contribute 0 to the total, matching
        // what a user would expect — we're capturing a snapshot, not validating files.
        let totalBytes = files.reduce(Int64(0)) { sum, item in
            let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
            return sum + size
        }
        let filesSummary = AttachedFilesSummary(
            count: files.count,
            totalBytes: totalBytes,
            fileTypes: Array(Set(files.map { ($0.url.pathExtension).lowercased() }.filter { !$0.isEmpty })).sorted()
        )

        // --- Advanced config: serialize JSONValue → String (keys + stringified values) ---
        // Redacts common secret keys via TelemetrySanitizer.sanitizeJSONKeys at the
        // serialization level, so nothing sensitive leaks through advancedConfiguration.
        var advanced: [String: String] = [:]
        if let adv = llmConfig?.advancedConfiguration {
            for (key, value) in adv {
                advanced[key] = Self.stringify(value)
            }
        }

        return TraceConfigSnapshot(
            traceID: traceID,
            profileID: profile.id.uuidString,
            profileName: profile.displayName,
            profileType: profile.profileType.rawValue,

            provider: llmConfig?.apiProvider.rawValue ?? "workflow",
            modelName: llmConfig?.modelName ?? "(multiple — see per-node traces)",
            modelTier: llmConfig?.modelMetadata?.tier.rawValue,
            modelContextWindow: llmConfig?.modelMetadata?.contextWindow,
            modelQuantization: llmConfig?.modelMetadata?.quantization,
            modelFamily: llmConfig?.modelMetadata?.family,
            modelParameterCount: llmConfig?.modelMetadata?.parameterCount,
            modelDialect: llmConfig?.modelDialect.rawValue ?? "",
            modelCapability: llmConfig?.cognitiveCapability.rawValue ?? "",
            chatTemplateSource: llmConfig.map { Self.describe($0.chatTemplateSource) } ?? "",
            stopSequences: llmConfig?.stopSequences ?? [],
            thinkingEnabled: llmConfig?.thinkingEnabled ?? false,
            advancedConfig: advanced,

            toolsEnabled: toolsEnabled,
            toolsRequireConfirmation: toolsRequireConfirmation,
            capabilitiesEnabled: capabilitiesEnabled,
            instructions: instructions,
            instructionsLength: instructionsLength,
            instructionsHash: instructionsHash,
            maxIterations: maxIterations,
            executionTimeoutSec: executionTimeoutSec,
            retryPolicy: retryPolicy,
            errorRecovery: errorRecovery,
            historyStrategy: historyStrategy,

            codeProjectPath: codeProjectPath,
            codeMemoryLength: codeMemoryLength,
            codeMemoryHash: codeMemoryHash,

            historyTurnCount: historyTurnCount,
            attachedFiles: filesSummary,

            hardware: hardware,
            appVersion: appVersion,
            appBuildNumber: appBuild,
            osVersion: osVersion,
            featureFlags: featureFlags,
            capturedAt: Date()
        )
    }

    // MARK: - Helpers

    /// SHA-256 hash, first 8 bytes as 16 lowercase hex chars. Stable across launches
    /// (unlike Swift's `hashValue`, whose `Hasher` seed is randomized per process),
    /// so the cross-trace equality joins the partial index was built for actually work.
    /// Enough for equality checks; not a cryptographic commitment.
    static func shortHash(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Stringify a JSONValue for flat advancedConfig storage. Sensitive values
    /// (if the key happens to contain "key"/"token"/etc.) are redacted downstream
    /// when the full snapshot JSON passes through TelemetrySanitizer.
    private static func stringify(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .number(let n): return "\(n)"
        case .bool(let b):   return "\(b)"
        case .null:          return "null"
        case .array, .object:
            if let data = try? JSONEncoder().encode(value),
               let s = String(data: data, encoding: .utf8) { return s }
            return "[unserializable]"
        }
    }

    /// Flatten ChatTemplateSource enum to a stable string for the snapshot.
    private static func describe(_ source: ChatTemplateSource) -> String {
        switch source {
        case .embedded:                  return "embedded"
        case .extracted:                 return "extracted"
        case .familyFallback(let family): return "familyFallback(\(family.rawValue))"
        }
    }
}

// MARK: - GRDB Conformance

/// Persisted row — indexed fields live as columns, everything else rides in snapshotJSON.
/// New snapshot fields can be added without schema changes as long as they don't need
/// their own index.
struct TraceConfigRow: Codable, Sendable, FetchableRecord, PersistableRecord {
    static var databaseTableName: String { "trace_configs" }

    /// Foreign key to `traces.traceID`. Primary key here — one row per trace.
    let traceID: String

    // Indexed columns — must match the v3 migration below.
    let provider: String
    let modelName: String
    let profileType: String
    let appVersion: String
    let osVersion: String
    let toolsCount: Int
    let capabilitiesCount: Int
    let instructionsHash: String?
    let memoryBudgetBytes: Int64?
    let historyStrategy: String?
    let thinkingEnabled: Bool

    /// Full serialized snapshot. Sanitized before persistence.
    let snapshotJSON: String

    enum Columns: String, ColumnExpression {
        case traceID
        case provider, modelName, profileType, appVersion, osVersion
        case toolsCount, capabilitiesCount, instructionsHash
        case memoryBudgetBytes, historyStrategy, thinkingEnabled
        case snapshotJSON
    }
}
