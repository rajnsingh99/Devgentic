// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXQuantization.swift
//  Devgentic
//
//  Created 2026-08-03 for G5.
//
//  Choosing a quantization is the single most important decision a local-model user makes, and
//  the store could not help: `MLXDisplayModel` had no quantization field, nothing parsed one
//  from the repo id, and there was no badge, filter or sort. The live top-30 lists
//  `gemma-4-E4B-it-MLX-4bit`, `-5bit`, `-6bit` and `-8bit` as four visually identical cards
//  distinguished only by a suffix buried in the title.
//
//  It also cost accuracy: `ModelFitAdvisor.assess` was called with `metadata: nil`, so
//  `parseQuantizationBits` — which already understood these suffixes — was dead code on the
//  pre-download path and the RAM verdict fell back to a crude `diskBytes × 1.2` proxy.
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

    // `shortLabel: String` lived here and computed the same text as `localizedTitle` below.
    // Its last caller was a VoiceOver label that consequently read an untranslated form of a
    // badge that renders translated; that site now uses `localizedTitle` and this is removed
    // rather than left as a second, silently-diverging source of the same string.

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

    /// The token handed to HuggingFace's `search=` parameter so the SERVER returns this
    /// quantization, instead of the client thinning an already-fetched mixed page.
    ///
    /// ⚠️ `.sixteenBit` is NOT "16bit". The popular uploads are named `…-bf16`
    /// (`lmstudio-community/Qwen3-1.7B-MLX-bf16`), while `16bit` matches almost nothing.
    /// `parse(fromRepoId:)` reads `bf16` as 16-bit, so the client-side check still agrees.
    ///
    /// ⚠️ Deliberately NOT merged with `advisorToken`, which feeds
    /// `ModelFitAdvisor.parseQuantizationBits` and must keep saying "16bit" there.
    var searchToken: String {
        self == .sixteenBit ? "bf16" : "\(rawValue)bit"
    }

    /// Parses the quantization a publisher encoded in the repo id.
    ///
    /// MLX conversions overwhelmingly put it in the name (`…-MLX-4bit`, `…-8bit`, `…-bf16`)
    /// because the HuggingFace API's `config.quantization_config` is present for only about
    /// half of them — verified across four live repos.
    ///
    /// ⚠️ Matching is anchored to a digit boundary. A naive `contains("4bit")` also fires on
    /// `…-24bit-something`, and a naive `contains("8")` matches any model with an 8 in its
    /// parameter count (`Llama-3.1-8B`), which is why the parameter size must not be mistaken
    /// for a quantization.
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
    ///
    /// Only quantization and parameter count are supplied; everything else stays nil so the
    /// advisor falls back exactly as before when they can't be parsed.
    static func fitMetadata(forRepoId repoId: String) -> ModelMetadata? {
        // ⚠️ Requires a parameter count, not just a quantization.
        //
        // `ModelFitAdvisor.assess` tries paramCount → diskSize → tier → `.unknown`. Bits alone
        // can't drive the formula (it needs a parameter count), so metadata carrying only a
        // quantization would add nothing — while the mandatory `tier` field could preempt the
        // honest `.unknown` verdict with a guess. Better to return nil and let the existing
        // disk-size path answer.
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

    /// Extracts a parameter count like `7B` / `3.2B` / `30B` from the repo id.
    ///
    /// ⚠️ Deliberately requires a `B` suffix immediately after the number. Without it,
    /// `Qwen2.5-3B` and `Qwen3-Coder-30B` are indistinguishable from version numbers and
    /// quantization suffixes.
    /// Scans for `<digits>[.<digits>]B` not glued to a preceding letter/digit run that would make
    /// it part of another token.
    ///
    /// ⚠️ COMPILED ONCE. This was built inside `parameterCount` on every call, and an
    /// `NSRegularExpression(pattern:)` is ~23 µs of ICU compilation — measured at 24.0 µs/id
    /// compiled-per-call against 1.2 µs/id cached, about two thirds of the whole RAM-fit pipeline.
    /// That was survivable while the only caller was a card rendering once, and stopped being so
    /// when the "Fits my Mac" filter began calling it per card per observer tick: sizes arrive one
    /// per model, so a 5-page grid paid ~4,500 compilations (~158 ms on the main actor) for the
    /// next page alone.
    ///
    /// `try?` at the top level rather than `try!`: a nil regex degrades `parameterCount` to nil,
    /// which the fit advisor already treats as "no parameter count" and falls back from.
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
