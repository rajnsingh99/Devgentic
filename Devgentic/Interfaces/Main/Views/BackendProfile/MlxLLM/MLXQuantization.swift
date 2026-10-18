// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXQuantization.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftUI

/// Bits-per-weight, parsed from a HuggingFace repo id.
enum MLXQuantization: Int, CaseIterable, Comparable, Hashable {
    case twoBit = 2
    case threeBit = 3
    case fourBit = 4
    case fiveBit = 5
    case sixBit = 6
    case eightBit = 8
    case sixteenBit = 16

    static func < (lhs: MLXQuantization, rhs: MLXQuantization) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .twoBit:     return "2-bit"
        case .threeBit:   return "3-bit"
        case .fourBit:    return "4-bit"
        case .fiveBit:    return "5-bit"
        case .sixBit:     return "6-bit"
        case .eightBit:   return "8-bit"
        case .sixteenBit: return "16-bit"
        }
    }

    /// Plain-language trade-off, shown as the badge's tooltip.
    var guidance: String {
        switch self {
        case .twoBit, .threeBit:
            return "Smallest and fastest, but noticeably lower quality. Useful when memory is tight."
        case .fourBit:
            return "The usual choice — close to full quality at roughly a quarter of the memory."
        case .fiveBit, .sixBit:
            return "A little more quality than 4-bit for a little more memory."
        case .eightBit:
            return "Near-original quality at about half the memory of the full model."
        case .sixteenBit:
            return "Unquantized. Best quality, and the largest by a wide margin."
        }
    }

    /// The string form `ModelFitAdvisor.parseQuantizationBits` understands, so the fit verdict
    /// can use real bits-per-weight instead of inferring from disk size.
    var advisorToken: String { "\(rawValue)bit" }

    // Why: not merged with `advisorToken`, which feeds `ModelFitAdvisor.parseQuantizationBits` and must keep saying "16bit".
    /// The token handed to HuggingFace's `search=` parameter so the server returns this quantization.
    /// `.sixteenBit` maps to "bf16", the name popular uploads use, not "16bit".
    var searchToken: String {
        self == .sixteenBit ? "bf16" : "\(rawValue)bit"
    }

    /// Parses the quantization a publisher encoded in the repo id (`-4bit`, `-8bit`, `-bf16`).
    /// The name is used because the API's `quantization_config` is present for only about half of MLX conversions.
    /// Matching is anchored to a digit boundary, so `24bit` and a parameter count like `8B` are not mistaken for it.
    static func parse(fromRepoId repoId: String) -> MLXQuantization? {
        let lower = repoId.lowercased()

        if lower.contains("bf16") || lower.contains("fp16") || lower.contains("float16") {
            return .sixteenBit
        }

        // Longest first so "16bit" is not shadowed by "6bit".
        for quant in MLXQuantization.allCases.sorted(by: >) {
            let bits = quant.rawValue
            for pattern in ["\(bits)bit", "\(bits)-bit", "\(bits)_bit"] {
                if let range = lower.range(of: pattern) {
                    // The digit must not be preceded by another digit, or "24bit" reads as
                    // "4bit" and a 240-billion-parameter name could read as a quantization.
                    let precedingIndex = range.lowerBound
                    if precedingIndex > lower.startIndex {
                        let previous = lower[lower.index(before: precedingIndex)]
                        if previous.isNumber { continue }
                    }
                    return quant
                }
            }
        }
        return nil
    }
}

// MARK: - Fit input

extension MLXQuantization {

    /// Synthesises just enough `ModelMetadata` for `ModelFitAdvisor` to use real bits-per-weight.
    /// Only quantization and parameter count are supplied; everything else stays nil so the advisor falls back.
    static func fitMetadata(forRepoId repoId: String) -> ModelMetadata? {
        // Requires a parameter count, not just a quantization: bits alone cannot drive the formula, so nil lets the disk-size
        // path answer.
        guard let params = parameterCount(fromRepoId: repoId) else { return nil }
        let quant = parse(fromRepoId: repoId)
        return ModelMetadata(
            tier: tier(forParameterCount: params),
            quantization: quant?.advisorToken,
            parameterCount: params
        )
    }

    /// Tier consistent with the parsed parameter count, so the value is honest even though
    /// the advisor only consults it when everything else is missing.
    private static func tier(forParameterCount params: String) -> ModelTier {
        let billions = Double(params.dropLast()) ?? 0
        switch billions {
        case ..<4:    return .tiny
        case ..<15:   return .small
        case ..<45:   return .medium
        case ..<100:  return .large
        default:      return .ultra
        }
    }

    // Why: compiled once: building the regex per call is a measurable cost on the per-card fit filter; `try?` degrades to nil.
    /// Extracts a parameter count like `7B` / `3.2B` / `30B` from the repo id, requiring a `B` suffix right after the
    /// number.
    /// Scans `<digits>[.<digits>]B` not glued to a preceding letter or digit run.
    private static let parameterCountRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9.])(\d{1,3}(?:\.\d)?)[bB](?![A-Za-z0-9])"#)
    }()

    static func parameterCount(fromRepoId repoId: String) -> String? {
        let name = repoId.components(separatedBy: "/").last ?? repoId
        guard let regex = Self.parameterCountRegex,
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else { return nil }
        return "\(name[range])B"
    }
}
