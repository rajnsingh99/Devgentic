// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXModelDetail.swift
//  Devgentic
//
//  Created 2026-08-03 for G6 — the model detail sheet.
//
//  What a user needs before committing to a multi-gigabyte download: the licence (material for
//  anyone shipping commercial work), how big it is, how it was quantized, and what the
//  publisher says about it. The store previously showed name, org, download count, size and
//  heuristic capability badges — nothing else — and `MLXDisplayModel.description` was hardcoded
//  nil for every remote model.
//
//  The data is free: the detail endpoint was already being hit for size and its response
//  decoded into `HFModelDetail`, which discarded everything except sibling sizes.
//

import Foundation

/// Everything the store can tell a user about a model it has not downloaded yet.
struct MLXModelDetail: Sendable, Equatable {
    let repoId: String
    let author: String?
    let license: String?
    let licenseURL: URL?
    /// Stored tensor elements. ⚠️ NOT the logical parameter count for a quantized repo —
    /// packed weights inflate it — so the UI labels it honestly rather than calling it
    /// "parameters".
    let tensorElements: Int64?
    let quantizationBits: Int?
    let architecture: String?
    let totalBytes: Int64?
    let fileCount: Int
    let weightFileCount: Int
    let lastModified: Date?
    let downloads: Int?
    let likes: Int?
    let tags: [String]
    let baseModels: [String]
    /// True when HuggingFace requires an access token. The app has no token support yet
    /// (G4), so this is surfaced as a warning rather than a prompt.
    let isGated: Bool
    /// Model-card prose, front-matter stripped and truncated. Nil until fetched, or when the
    /// publisher shipped no README.
    var readme: String?

    /// ⚠️ Always nil, deliberately.
    ///
    /// Verified against the HuggingFace API across four MLX repos: the `config` block never
    /// includes `max_position_embeddings`. A model's real context window is only knowable
    /// after download, when `MLXTokenizerAnalyzer` reads its `config.json` — which is exactly
    /// why `MLXContextWindowHealer` exists. The field is kept so the UI can say "not
    /// published" rather than silently omitting a fact users look for.
    var contextWindow: Int? { nil }

    /// Human-readable quantization, falling back to the name when the API omits the config
    /// (which it does for roughly half of MLX repos).
    var quantizationSummary: String? {
        if let bits = quantizationBits { return "\(bits)-bit" }
        let lower = repoId.lowercased()
        for bits in [2, 3, 4, 5, 6, 8] where lower.contains("\(bits)bit") || lower.contains("\(bits)-bit") {
            return "\(bits)-bit (from the model name)"
        }
        if lower.contains("bf16") || lower.contains("fp16") { return "16-bit" }
        return nil
    }
}

extension MLXModelDetail {

    /// Builds the domain model from a decoded API response.
    init(repoId: String, response: HFModelDetail) {
        self.repoId = repoId
        self.author = response.author
        self.license = response.cardData?.license
        self.licenseURL = response.cardData?.license_link.flatMap(URL.init(string:))
        self.tensorElements = response.safetensors?.total
        self.quantizationBits = response.config?.quantization_config?.bits
        self.architecture = response.config?.architectures?.first ?? response.config?.model_type
        // `usedStorage` avoids needing `?blobs=true`; fall back to summing siblings when the
        // caller did pass it.
        let siblingTotal = response.siblings.compactMap(\.size).reduce(0, +)
        self.totalBytes = response.usedStorage ?? (siblingTotal > 0 ? Int64(siblingTotal) : nil)
        self.fileCount = response.siblings.count
        self.weightFileCount = response.siblings.filter {
            guard let name = $0.rfilename?.lowercased() else { return false }
            return name.hasSuffix(".safetensors") || name.hasSuffix(".npz")
                || name.hasSuffix(".bin") || name.hasSuffix(".gguf")
        }.count
        self.lastModified = response.lastModified.flatMap {
            ISO8601DateFormatter.hfFormatter.date(from: $0)
                ?? ISO8601DateFormatter.hfFractionalFormatter.date(from: $0)
        }
        self.downloads = response.downloads
        self.likes = response.likes
        self.tags = response.tags ?? []
        self.baseModels = response.cardData?.base_model?.values ?? []
        self.isGated = response.gated?.isGated ?? false
        self.readme = nil
    }
}

// MARK: - README

enum HFModelCard {

    /// Longest README excerpt shown. The sheet is a decision aid, not a document reader — a
    /// full card can run to tens of thousands of characters.
    static let excerptLimit = 4_000

    /// Strips the YAML front matter every HF model card opens with (it duplicates the
    /// structured fields already shown above the prose) and truncates on a line boundary.
    static func excerpt(from raw: String) -> String {
        var body = raw
        if body.hasPrefix("---") {
            // Front matter runs to the second `---` on its own line.
            let lines = body.components(separatedBy: .newlines)
            if let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                body = lines[(closing + 1)...].joined(separator: "\n")
            }
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count > excerptLimit else { return body }

        let clipped = body.prefix(excerptLimit)
        // Prefer a paragraph boundary so the excerpt doesn't end mid-sentence.
        if let lastBreak = clipped.range(of: "\n", options: .backwards) {
            return String(clipped[..<lastBreak.lowerBound]) + "\n\n…"
        }
        return String(clipped) + "…"
    }
}
