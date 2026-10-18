// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXModelDetail.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Everything the store can tell a user about a model it has not downloaded yet.
struct MLXModelDetail: Sendable, Equatable {
    let repoId: String
    let author: String?
    let license: String?
    let licenseURL: URL?
    /// Stored tensor elements.
    /// Not the logical parameter count of a quantized repo (packed weights inflate it); the UI must not call it "parameters".
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
    /// HuggingFace's declared `pipeline_tag`, verbatim. Feeds `ModelSupportPolicy` — the pasted
    /// repo-ID path never passes through the search listing's pipeline filter.
    let pipelineTag: String?
    let baseModels: [String]
    /// True when HuggingFace requires an access token. The app has no token support yet
    /// (G4), so this is surfaced as a warning rather than a prompt.
    let isGated: Bool
    /// Model-card prose, front-matter stripped and truncated. Nil until fetched, or when the
    /// publisher shipped no README.
    var readme: String?

    /// Always nil: the HuggingFace API `config` block never includes `max_position_embeddings`.
    /// The real window is known only after download, when `MLXTokenizerAnalyzer` reads `config.json`.
    /// Kept so the UI can say "not published" rather than omit it.
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

    /// Why Devgentic can't run this repo, or nil when it can (or when nothing declares otherwise).
    var unsupportedReason: String? {
        ModelSupportPolicy.unsupportedReason(pipelineTag: pipelineTag, tags: tags)
    }

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
        self.pipelineTag = response.pipeline_tag
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
