// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ModelFitAdvisor.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation
import SwiftUI
import os

// MARK: - Assessment Types

/// The verdict on whether a model fits the current system.
/// ⚠️ `CaseIterable` so "every verdict answers X" tests iterate the real set. They previously
/// walked a hand-written array, which silently skipped any case added later — exactly the gap
/// that let `.unknown` ship without a localized title being checked.
enum ModelFitVerdict: String, Sendable, CaseIterable {
    /// Model uses < 50% of effective budget. Plenty of headroom.
    case comfortable = "Comfortable"
    /// Model uses 50-75% of budget. Works, but limited room for concurrent models.
    case tight = "Tight Fit"
    /// Model uses 75-95% of budget. May cause memory pressure and swapping.
    case risky = "Risky"
    /// Model uses > 95% of budget. Will likely fail or thrash.
    case incompatible = "Too Large"
    /// No size data was available, so no fit could be computed.
    ///
    /// ⚠️ This case exists because the absence of an answer used to be reported as
    /// `.comfortable`. A HuggingFace size fetch that failed (a 429 is the common case, not
    /// the rare one) left every card sizeless, and a sizeless card asserted a comfortable
    /// fit with `estimatedRuntimeRAM: 0` — hiding the badge too, so there was not even a
    /// visual clue. A safety advisory must never fail open; "unknown" is not "fine".
    case unknown = "Size Unknown"

    /// User-facing name. ⚠️ Separate from `rawValue` on purpose: `Text(x.rawValue)` binds to
    /// the non-localizing `StringProtocol` overload, so every rawValue-sourced label was
    /// invisible to the String Catalog extractor and would have shipped untranslated inside
    /// otherwise-translated chrome. `rawValue` stays for persistence and logging only.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .comfortable:   return "Comfortable"
        case .tight:         return "Tight Fit"
        case .risky:         return "Risky"
        case .incompatible:  return "Too Large"
        case .unknown:       return "Size Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .comfortable: return "checkmark.circle.fill"
        case .tight: return "exclamationmark.triangle.fill"
        case .risky: return "exclamationmark.octagon.fill"
        case .incompatible: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

/// The full assessment result for a single model against the system.
struct ModelFitAssessment: Sendable {
    /// The fit verdict.
    let verdict: ModelFitVerdict
    /// Estimated runtime RAM in bytes (weights + KV cache + overhead).
    let estimatedRuntimeRAM: UInt64
    /// Headroom = effectiveBudget - estimatedRuntimeRAM. Negative means oversubscribed.
    let headroom: Int64
    /// Short human-readable explanation.
    let explanation: String
    /// Optional suggestion (e.g. "Consider the 4-bit variant").
    let recommendation: String?

    /// Formatted estimated RAM string (e.g. "3.2 GB").
    var formattedEstimatedRAM: String {
        ByteCountFormatter.string(fromByteCount: Int64(estimatedRuntimeRAM), countStyle: .memory)
    }
}

// MARK: - Advisor

/// Estimates model runtime memory requirements and advises on system compatibility.
/// Provider-agnostic — works with any source (MLX, Ollama) via `ModelMetadata` or raw parameters.
struct ModelFitAdvisor {

    private static let logger = DGLogger(category: "ModelFitAdvisor")

    // MARK: - Primary API

    /// Assess a model's fit using its `ModelMetadata` (available from both MLX and Ollama pipelines).
    ///
    /// Each model is assessed in isolation — if parsing fails or any step returns an unexpected value,
    /// the method degrades gracefully (returns a neutral assessment) and logs the raw inputs so we
    /// can add explicit support for new formats later. One bad model never crashes the caller.
    /// - Parameter modelName: Optional model identifier (e.g. "kimi-k2.5:cloud") included in
    ///   diagnostic logs so we can identify which model produced an unusual format.
    /// - Parameter diskSizeBytes: the authoritative byte total when the caller has it.
    ///   Prefer this over `diskSizeString` — see `parseDiskSize` for why round-tripping a
    ///   formatted size through a string is lossy in comma-decimal locales.
    static func assess(
        metadata: ModelMetadata?,
        diskSizeString: String? = nil,
        diskSizeBytes: Int64? = nil,
        modelName: String? = nil
    ) -> ModelFitAssessment {
        let profile = SystemHardwareProfiler.shared.profile

        // Extract parameter count in billions
        let paramBillions = parseParameterCount(metadata?.parameterCount)

        // Extract quantization bits
        let quantBits = parseQuantizationBits(metadata?.quantization)

        // Emit diagnostic logs for any inputs we couldn't parse — used to add support for new formats later.
        logUnusualInputs(metadata: metadata, parsedBillions: paramBillions, modelName: modelName)

        // ⚠️ The formula outranks the byte total, and the ORDER here is the whole point of G5.
        // `assessFromDiskSize` is a flat `diskBytes × 1.2` proxy: it cannot see quantization
        // or context window, so a bf16 model reads as far cheaper than it runs. With the raw-
        // bytes short-circuit sitting above this branch, `MLXQuantization.fitMetadata` was
        // computed and thrown away on every card that had a size — i.e. nearly all of them —
        // and only cards whose size fetch had been rate-limited ever reached the real
        // formula. Verdicts flipped between `.risky` and `.tight` on a 24 GB machine as a
        // result. This does NOT undo A19: raw bytes still outrank the FORMATTED string below,
        // which was A19's actual concern (round-tripping through a comma-decimal locale).
        if let params = paramBillions {
            return assessWithFormula(
                paramBillions: params,
                quantBits: quantBits,
                contextWindow: metadata?.contextWindow,
                profile: profile
            )
        }

        // No parameter count: raw bytes are the next best evidence — no parsing, no locale,
        // no unit inference.
        if let diskSizeBytes, diskSizeBytes > 0 {
            return assessFromDiskSize(diskBytes: UInt64(diskSizeBytes), profile: profile)
        }

        // Fallback: estimate from disk size string (e.g. "2.4 GB")
        if let diskSize = diskSizeString, let diskBytes = parseDiskSize(diskSize) {
            return assessFromDiskSize(diskBytes: diskBytes, profile: profile)
        }

        // Fallback: estimate from model tier
        if let tier = metadata?.tier {
            return assessFromTier(tier: tier, profile: profile)
        }

        // Cannot assess — return a neutral result (graceful degradation)
        logger.warning("[FIT] Unable to assess RAM fit\(modelName.map { " for '\($0)'" } ?? "") — no parameter count, disk size or tier available (usually a failed HuggingFace size fetch). CONSEQUENCE: reporting .unknown, NOT .comfortable — the card shows \"size unavailable\" rather than implying the model fits.")
        return ModelFitAssessment(
            verdict: .unknown,
            estimatedRuntimeRAM: 0,
            headroom: Int64(profile.effectiveBudget),
            explanation: "Size unavailable — can't check whether this model fits in memory",
            recommendation: "Reload the store to retry, or check the model's size on HuggingFace."
        )
    }

    /// Assess whether two models can coexist (e.g. agent model + Intelligence Core).
    /// The `primary` model is assumed to be loaded; `secondary` briefly loads alongside it.
    static func assessDualModel(
        primary: ModelMetadata?,
        primaryDiskSize: String? = nil,
        secondary: ModelMetadata?,
        secondaryDiskSize: String? = nil
    ) -> ModelFitAssessment {
        let profile = SystemHardwareProfiler.shared.profile

        let primaryRAM = estimateRuntimeRAM(metadata: primary, diskSizeString: primaryDiskSize)
        let secondaryRAM = estimateRuntimeRAM(metadata: secondary, diskSizeString: secondaryDiskSize)
        let combinedRAM = primaryRAM + secondaryRAM
        let budget = profile.effectiveBudget
        let headroom = Int64(budget) - Int64(combinedRAM)
        let ratio = Double(combinedRAM) / Double(budget)

        let verdict = verdictFromRatio(ratio)
        let primaryFormatted = ByteCountFormatter.string(fromByteCount: Int64(primaryRAM), countStyle: .memory)
        let secondaryFormatted = ByteCountFormatter.string(fromByteCount: Int64(secondaryRAM), countStyle: .memory)

        let explanation: String
        let recommendation: String?

        switch verdict {
        case .comfortable:
            explanation = "Both models fit comfortably (\(primaryFormatted) + \(secondaryFormatted))"
            recommendation = nil
        case .tight:
            explanation = "Combined usage (\(primaryFormatted) + \(secondaryFormatted)) leaves limited headroom"
            recommendation = "Performance may dip briefly when both models are loaded"
        case .risky:
            explanation = "Combined usage (\(primaryFormatted) + \(secondaryFormatted)) exceeds safe limits"
            recommendation = "Consider a smaller Intelligence Core model to avoid memory pressure"
        case .incompatible:
            explanation = "Combined usage (\(primaryFormatted) + \(secondaryFormatted)) exceeds system capacity"
            recommendation = "Choose a smaller model for either the agent or the Intelligence Core"
        case .unknown:
            // Unreachable: `verdict` here is derived from a computed RAM total. Spelled out
            // rather than defaulted so adding a future verdict fails the build instead of
            // silently borrowing this branch's copy.
            explanation = "Combined memory usage could not be estimated"
            recommendation = "Model sizes are unavailable — reload and try again"
        }

        return ModelFitAssessment(
            verdict: verdict,
            estimatedRuntimeRAM: combinedRAM,
            headroom: headroom,
            explanation: explanation,
            recommendation: recommendation
        )
    }

    // MARK: - Estimation Engine

    /// Estimate runtime RAM from metadata (returns bytes). Used internally and for dual-model checks.
    /// ⚠️ The priority order MIRRORS `assess`: formula → raw bytes → formatted string → tier.
    /// Keep them in step — `verdict` below is only interchangeable with `assess(…).verdict`
    /// while they agree, and the agreement test exists to catch the day they stop.
    static func estimateRuntimeRAM(
        metadata: ModelMetadata?,
        diskSizeString: String? = nil,
        diskSizeBytes: Int64? = nil
    ) -> UInt64 {
        let paramBillions = parseParameterCount(metadata?.parameterCount)
        let quantBits = parseQuantizationBits(metadata?.quantization)

        if let params = paramBillions {
            return calculateRuntimeRAM(paramBillions: params, quantBits: quantBits, contextWindow: metadata?.contextWindow)
        }

        // Raw bytes BEFORE the formatted string: round-tripping a `ByteCountFormatter` string
        // back through `parseDiskSize` is lossy in comma-decimal locales.
        if let diskSizeBytes, diskSizeBytes > 0 {
            return safeUInt64(Double(diskSizeBytes) * 1.2)
        }

        if let diskSize = diskSizeString, let diskBytes = parseDiskSize(diskSize) {
            // Runtime ≈ 1.2x disk size (weights + KV cache + overhead)
            return safeUInt64(Double(diskBytes) * 1.2)
        }

        if let tier = metadata?.tier {
            return estimateFromTier(tier)
        }

        return 0
    }

    // MARK: - Formula-Based Assessment

    /// Core estimation: paramCount × bitsPerWeight / 8 + KV cache + overhead.
    private static func calculateRuntimeRAM(paramBillions: Double, quantBits: Int, contextWindow: Int?) -> UInt64 {
        // Weight memory: params × bits / 8
        let weightBytes = safeUInt64(paramBillions * 1_000_000_000 * Double(quantBits) / 8.0)

        // KV cache estimate (conservative, assumes active context of 4K tokens for local use)
        // Formula: 2 × numLayers × hiddenSize × contextTokens × 2 bytes (fp16 KV)
        // Simplified heuristic: ~0.5 GB per 7B params at 4K context
        let kvCacheBytes = safeUInt64(paramBillions / 7.0 * 500 * 1024 * 1024)

        // Runtime overhead (MLX framework, tokenizer, buffers)
        let overheadBytes: UInt64 = 300 * 1024 * 1024 // ~300 MB

        return weightBytes + kvCacheBytes + overheadBytes
    }

    private static func assessWithFormula(paramBillions: Double, quantBits: Int, contextWindow: Int?, profile: SystemHardwareProfile) -> ModelFitAssessment {
        let estimatedRAM = calculateRuntimeRAM(paramBillions: paramBillions, quantBits: quantBits, contextWindow: contextWindow)
        let budget = profile.effectiveBudget
        let headroom = Int64(budget) - Int64(estimatedRAM)
        let ratio = Double(estimatedRAM) / Double(budget)

        let verdict = verdictFromRatio(ratio)
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(estimatedRAM), countStyle: .memory)
        let budgetFormatted = profile.formattedEffectiveBudget

        let explanation: String
        let recommendation: String?

        switch verdict {
        case .comfortable:
            explanation = "~\(formatted) estimated · fits well within \(budgetFormatted) budget"
            recommendation = nil
        case .tight:
            explanation = "~\(formatted) estimated · uses most of the \(budgetFormatted) budget"
            recommendation = "Will work, but may limit concurrent operations"
        case .risky:
            explanation = "~\(formatted) estimated · exceeds safe threshold of \(budgetFormatted)"
            recommendation = "May cause memory swapping and degraded performance"
        case .incompatible:
            explanation = "~\(formatted) estimated · exceeds \(budgetFormatted) system budget"
            recommendation = "This model is too large for your system. Consider a smaller variant"
        case .unknown:
            // Unreachable: reached only with a computed `estimatedRAM`. See note above.
            explanation = "Memory usage could not be estimated"
            recommendation = "Model size is unavailable — reload and try again"
        }

        logger.info("Assessment: \(String(format: "%.1f", paramBillions))B Q\(quantBits) → \(formatted) → \(verdict.rawValue)")

        return ModelFitAssessment(
            verdict: verdict,
            estimatedRuntimeRAM: estimatedRAM,
            headroom: headroom,
            explanation: explanation,
            recommendation: recommendation
        )
    }

    // MARK: - Fallback Assessments

    private static func assessFromDiskSize(diskBytes: UInt64, profile: SystemHardwareProfile) -> ModelFitAssessment {
        // Runtime ≈ 1.2x disk (weights already quantized, add KV + overhead)
        let estimatedRAM = safeUInt64(Double(diskBytes) * 1.2)
        let budget = profile.effectiveBudget
        let headroom = Int64(budget) - Int64(estimatedRAM)
        let ratio = Double(estimatedRAM) / Double(budget)
        let verdict = verdictFromRatio(ratio)
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(estimatedRAM), countStyle: .memory)

        return ModelFitAssessment(
            verdict: verdict,
            estimatedRuntimeRAM: estimatedRAM,
            headroom: headroom,
            explanation: "~\(formatted) estimated from disk size",
            recommendation: verdict == .comfortable ? nil : "Estimate is approximate — actual usage may vary"
        )
    }

    private static func assessFromTier(tier: ModelTier, profile: SystemHardwareProfile) -> ModelFitAssessment {
        let estimatedRAM = estimateFromTier(tier)
        let budget = profile.effectiveBudget
        let headroom = Int64(budget) - Int64(estimatedRAM)
        let ratio = Double(estimatedRAM) / Double(budget)
        let verdict = verdictFromRatio(ratio)
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(estimatedRAM), countStyle: .memory)

        return ModelFitAssessment(
            verdict: verdict,
            estimatedRuntimeRAM: estimatedRAM,
            headroom: headroom,
            explanation: "~\(formatted) estimated for \(tier.rawValue) model",
            recommendation: verdict == .comfortable ? nil : "Consider a smaller model tier"
        )
    }

    /// Conservative RAM estimates per model tier (4-bit quantization assumed).
    private static func estimateFromTier(_ tier: ModelTier) -> UInt64 {
        let gb: UInt64 = 1024 * 1024 * 1024
        switch tier {
        case .tiny:   return 3 * gb    // <4B  → ~3 GB
        case .small:  return 6 * gb    // 7-14B → ~6 GB
        case .medium: return 20 * gb   // 30-40B → ~20 GB
        case .large:  return 42 * gb   // 70-80B → ~42 GB
        case .ultra:  return 65 * gb   // >100B → ~65 GB
        }
    }

    // MARK: - Parsing Helpers

    /// Parses parameter count strings like "7.2B", "3B", "70B", "751.63M", or raw counts like "1042000000000" into billions.
    static func parseParameterCount(_ str: String?) -> Double? {
        guard let str = str, !str.isEmpty else { return nil }
        let cleaned = str.trimmingCharacters(in: .whitespaces).lowercased()

        if cleaned.hasSuffix("b") {
            return Double(String(cleaned.dropLast()))
        }

        if cleaned.hasSuffix("m") {
            // "751.63M" → 0.75163 billion
            if let millions = Double(String(cleaned.dropLast())) {
                return millions / 1000.0
            }
            return nil
        }

        // Plain number — could be billions (e.g. "7") or a raw parameter count (e.g. "1042000000000")
        guard let value = Double(cleaned) else { return nil }
        if value > 1000 {
            // Raw parameter count — convert to billions
            return value / 1_000_000_000
        }
        return value
    }

    /// Parses quantization strings like "Q4_K_M", "Q8_0", "4bit", "INT4", "MXFP4", "BF16" into bits per weight.
    /// Unknown strings fall back to 4-bit; `isRecognizedQuantization` can be used to detect this case.
    static func parseQuantizationBits(_ str: String?) -> Int {
        guard let str = str else { return 4 } // Default assumption: 4-bit
        let cleaned = str.lowercased()

        // ⚠️ WIDE FORMATS FIRST, and the order here is load-bearing. These are substring
        // tests, and "16bit" contains "6bit" while "32bit" contains "2bit" — so with the
        // single-digit arms above them, a bf16 model parsed as 6-BIT. That is a ~2.7×
        // UNDER-estimate of runtime RAM, i.e. the unsafe direction: the model reads as
        // "it fits" and the user gets memory pressure instead of an advisory. Exactly the
        // collision invariant 28 exists for, in the one place that had not been swept.
        //
        // Live, not hypothetical: `MLXQuantization.advisorToken` renders `.sixteenBit` as
        // "16bit" and G5 feeds it straight into this function.
        if cleaned.contains("fp32") || cleaned.contains("f32") || cleaned.contains("32bit") || cleaned.contains("32-bit") { return 32 }
        if cleaned.contains("fp16") || cleaned.contains("f16") || cleaned.contains("bf16") || cleaned.contains("16bit") || cleaned.contains("16-bit") { return 16 }

        if cleaned.contains("q2") || cleaned.contains("2bit") || cleaned.contains("2-bit") || cleaned.contains("int2") { return 2 }
        if cleaned.contains("q3") || cleaned.contains("3bit") || cleaned.contains("3-bit") || cleaned.contains("int3") { return 3 }
        if cleaned.contains("q4") || cleaned.contains("4bit") || cleaned.contains("4-bit") || cleaned.contains("int4") || cleaned.contains("mxfp4") { return 4 }
        if cleaned.contains("q5") || cleaned.contains("5bit") || cleaned.contains("5-bit") { return 5 }
        if cleaned.contains("q6") || cleaned.contains("6bit") || cleaned.contains("6-bit") { return 6 }
        if cleaned.contains("q8") || cleaned.contains("8bit") || cleaned.contains("8-bit") || cleaned.contains("int8") { return 8 }

        return 4 // Safe default for quantized models
    }

    /// Parses disk size strings like "2.4 GB", "750 MB" into bytes.
    ///
    /// ⚠️ Lossy by nature — prefer `assess(diskSizeBytes:)` wherever the raw total is known.
    /// These strings come from a locale-aware `ByteCountFormatter`, which uses "," as the
    /// decimal separator across most of Europe. The old character filter kept only ASCII
    /// digits and ".", so the separator was STRIPPED rather than converted and "2,4 GB"
    /// parsed as 24 GB — a 10× overestimate that pushed compatible models past the RAM
    /// budget and into a "Model Too Large" gate. Both separators are normalised now.
    static func parseDiskSize(_ str: String) -> UInt64? {
        let cleaned = str.trimmingCharacters(in: .whitespaces).uppercased()
        let numberString = cleaned
            .components(separatedBy: CharacterSet(charactersIn: "0123456789.,").inverted)
            .joined()
            // `Double(_:)` is locale-invariant and only accepts ".".
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(numberString), value > 0 else { return nil }

        if cleaned.contains("GB") {
            return safeUInt64(value * 1024 * 1024 * 1024)
        } else if cleaned.contains("MB") {
            return safeUInt64(value * 1024 * 1024)
        } else if cleaned.contains("KB") {
            return safeUInt64(value * 1024)
        }

        // Assume MB if no unit
        return safeUInt64(value * 1024 * 1024)
    }

    // MARK: - Safe Conversion

    /// Converts a Double to UInt64, clamping to 0 / UInt64.max for out-of-range or non-finite values.
    private static func safeUInt64(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        guard value < Double(UInt64.max) else { return UInt64.max }
        return UInt64(value)
    }

    // MARK: - Diagnostic Logging

    /// Known quantization string fragments recognized by `parseQuantizationBits`.
    /// Kept in one place so `isRecognizedQuantization` and the parser can't drift apart.
    private static let recognizedQuantizationPatterns: [String] = [
        "q2", "2bit", "2-bit", "int2",
        "q3", "3bit", "3-bit", "int3",
        "q4", "4bit", "4-bit", "int4", "mxfp4",
        "q5", "5bit", "5-bit",
        "q6", "6bit", "6-bit",
        "q8", "8bit", "8-bit", "int8",
        "fp16", "f16", "bf16",
        "fp32", "f32"
    ]

    /// Returns true if the quantization string matches any known pattern.
    /// Used to decide whether to log a "please add support" diagnostic.
    static func isRecognizedQuantization(_ str: String) -> Bool {
        let cleaned = str.lowercased()
        return recognizedQuantizationPatterns.contains { cleaned.contains($0) }
    }

    /// Logs raw inputs that couldn't be parsed so we can prioritize adding support for them.
    /// Only logs non-empty values that we had to fall back on — avoids noise from missing metadata.
    private static func logUnusualInputs(metadata: ModelMetadata?, parsedBillions: Double?, modelName: String?) {
        guard let metadata = metadata else { return }
        let context = modelName.map { " [model: \($0)]" } ?? ""

        if let raw = metadata.parameterCount, !raw.isEmpty, parsedBillions == nil {
            logger.warning("ModelFitAdvisor\(context): unparseable parameterCount '\(raw)' — falling back to tier/disk estimation. Add explicit handling in parseParameterCount if this format becomes common.")
        }

        if let rawQuant = metadata.quantization, !rawQuant.isEmpty, !isRecognizedQuantization(rawQuant) {
            logger.warning("ModelFitAdvisor\(context): unrecognized quantization '\(rawQuant)' — defaulting to 4-bit. Add explicit handling in parseQuantizationBits if this format becomes common.")
        }
    }

    // MARK: - Verdict Logic

    /// The verdict alone, with NO diagnostic logging.
    ///
    /// ⚠️ Exists because `assess` emits a `logger.info` per model. That is right for a card that
    /// renders once and wrong for a list filter: `applyFilterAndSort` runs on every service
    /// observer tick — roughly one per size lookup that lands, ~30 per page — so assessing a
    /// page there would emit hundreds of lines per store load.
    ///
    /// Takes the same three inputs as `assess` so the two cannot diverge on input shape.
    static func verdict(
        metadata: ModelMetadata?,
        diskSizeString: String? = nil,
        diskSizeBytes: Int64? = nil
    ) -> ModelFitVerdict {
        let estimated = estimateRuntimeRAM(
            metadata: metadata,
            diskSizeString: diskSizeString,
            diskSizeBytes: diskSizeBytes
        )
        guard estimated > 0 else { return .unknown }
        let budget = SystemHardwareProfiler.shared.profile.effectiveBudget
        return verdictFromRatio(Double(estimated) / Double(budget))
    }

    private static func verdictFromRatio(_ ratio: Double) -> ModelFitVerdict {
        switch ratio {
        case ..<0.50: return .comfortable
        case 0.50..<0.75: return .tight
        case 0.75..<0.95: return .risky
        default: return .incompatible
        }
    }
}
