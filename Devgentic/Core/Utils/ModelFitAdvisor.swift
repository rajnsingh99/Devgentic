//
//  ModelFitAdvisor.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation
import os

// MARK: - Assessment Types

/// The verdict on whether a model fits the current system.
enum ModelFitVerdict: String, Sendable {
    /// Model uses < 50% of effective budget. Plenty of headroom.
    case comfortable = "Comfortable"
    /// Model uses 50-75% of budget. Works, but limited room for concurrent models.
    case tight = "Tight Fit"
    /// Model uses 75-95% of budget. May cause memory pressure and swapping.
    case risky = "Risky"
    /// Model uses > 95% of budget. Will likely fail or thrash.
    case incompatible = "Too Large"

    var systemImage: String {
        switch self {
        case .comfortable: return "checkmark.circle.fill"
        case .tight: return "exclamationmark.triangle.fill"
        case .risky: return "exclamationmark.octagon.fill"
        case .incompatible: return "xmark.octagon.fill"
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

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic", category: "ModelFitAdvisor")

    // MARK: - Primary API

    /// Assess a model's fit using its `ModelMetadata` (available from both MLX and Ollama pipelines).
    static func assess(metadata: ModelMetadata?, diskSizeString: String? = nil) -> ModelFitAssessment {
        let profile = SystemHardwareProfiler.shared.profile

        // Extract parameter count in billions
        let paramBillions = parseParameterCount(metadata?.parameterCount)

        // Extract quantization bits
        let quantBits = parseQuantizationBits(metadata?.quantization)

        // If we have parameter count, use the formula
        if let params = paramBillions {
            return assessWithFormula(
                paramBillions: params,
                quantBits: quantBits,
                contextWindow: metadata?.contextWindow,
                profile: profile
            )
        }

        // Fallback: estimate from disk size string (e.g. "2.4 GB")
        if let diskSize = diskSizeString, let diskBytes = parseDiskSize(diskSize) {
            return assessFromDiskSize(diskBytes: diskBytes, profile: profile)
        }

        // Fallback: estimate from model tier
        if let tier = metadata?.tier {
            return assessFromTier(tier: tier, profile: profile)
        }

        // Cannot assess — return a neutral result
        return ModelFitAssessment(
            verdict: .comfortable,
            estimatedRuntimeRAM: 0,
            headroom: Int64(profile.effectiveBudget),
            explanation: "Unable to estimate — no size data available",
            recommendation: nil
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
    static func estimateRuntimeRAM(metadata: ModelMetadata?, diskSizeString: String? = nil) -> UInt64 {
        let paramBillions = parseParameterCount(metadata?.parameterCount)
        let quantBits = parseQuantizationBits(metadata?.quantization)

        if let params = paramBillions {
            return calculateRuntimeRAM(paramBillions: params, quantBits: quantBits, contextWindow: metadata?.contextWindow)
        }

        if let diskSize = diskSizeString, let diskBytes = parseDiskSize(diskSize) {
            // Runtime ≈ 1.2x disk size (weights + KV cache + overhead)
            return UInt64(Double(diskBytes) * 1.2)
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
        let weightBytes = UInt64(paramBillions * 1_000_000_000 * Double(quantBits) / 8.0)

        // KV cache estimate (conservative, assumes active context of 4K tokens for local use)
        // Formula: 2 × numLayers × hiddenSize × contextTokens × 2 bytes (fp16 KV)
        // Simplified heuristic: ~0.5 GB per 7B params at 4K context
        let kvCacheBytes: UInt64 = UInt64(paramBillions / 7.0 * 500 * 1024 * 1024)

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
        }

        logger.info("Assessment: \(paramBillions, format: .fixed(precision: 1))B Q\(quantBits) → \(formatted) → \(verdict.rawValue)")

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
        let estimatedRAM = UInt64(Double(diskBytes) * 1.2)
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

    /// Parses parameter count strings like "7.2B", "3B", "70B" into billions.
    static func parseParameterCount(_ str: String?) -> Double? {
        guard let str = str else { return nil }
        let cleaned = str.trimmingCharacters(in: .whitespaces).lowercased()

        // Remove trailing "b" and parse
        let numberPart: String
        if cleaned.hasSuffix("b") {
            numberPart = String(cleaned.dropLast())
        } else {
            numberPart = cleaned
        }

        return Double(numberPart)
    }

    /// Parses quantization strings like "Q4_K_M", "Q8_0", "4bit", "8bit" into bits per weight.
    static func parseQuantizationBits(_ str: String?) -> Int {
        guard let str = str else { return 4 } // Default assumption: 4-bit
        let cleaned = str.lowercased()

        if cleaned.contains("q2") || cleaned.contains("2bit") || cleaned.contains("2-bit") { return 2 }
        if cleaned.contains("q3") || cleaned.contains("3bit") || cleaned.contains("3-bit") { return 3 }
        if cleaned.contains("q4") || cleaned.contains("4bit") || cleaned.contains("4-bit") { return 4 }
        if cleaned.contains("q5") || cleaned.contains("5bit") || cleaned.contains("5-bit") { return 5 }
        if cleaned.contains("q6") || cleaned.contains("6bit") || cleaned.contains("6-bit") { return 6 }
        if cleaned.contains("q8") || cleaned.contains("8bit") || cleaned.contains("8-bit") { return 8 }
        if cleaned.contains("fp16") || cleaned.contains("f16") || cleaned.contains("bf16") { return 16 }
        if cleaned.contains("fp32") || cleaned.contains("f32") { return 32 }

        return 4 // Safe default for quantized models
    }

    /// Parses disk size strings like "2.4 GB", "750 MB" into bytes.
    static func parseDiskSize(_ str: String) -> UInt64? {
        let cleaned = str.trimmingCharacters(in: .whitespaces).uppercased()
        let numberString = cleaned.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()
        guard let value = Double(numberString), value > 0 else { return nil }

        if cleaned.contains("GB") {
            return UInt64(value * 1024 * 1024 * 1024)
        } else if cleaned.contains("MB") {
            return UInt64(value * 1024 * 1024)
        } else if cleaned.contains("KB") {
            return UInt64(value * 1024)
        }

        // Assume MB if no unit
        return UInt64(value * 1024 * 1024)
    }

    // MARK: - Verdict Logic

    private static func verdictFromRatio(_ ratio: Double) -> ModelFitVerdict {
        switch ratio {
        case ..<0.50: return .comfortable
        case 0.50..<0.75: return .tight
        case 0.75..<0.95: return .risky
        default: return .incompatible
        }
    }
}
