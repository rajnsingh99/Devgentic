// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WhisperModelCatalog.swift
//  Devgentic
//
//  Shared catalog of available WhisperKit speech recognition models.
//

import Foundation

/// Describes a single WhisperKit model variant with its display metadata.
struct WhisperModelInfo: Identifiable {
    let id: String           // e.g. "base.en"
    let displayName: String  // e.g. "Base (English)"
    let size: String         // e.g. "~142 MB"

    /// Approximate total bytes on disk after download. Used by
    /// `DownloadCoordinator` to pre-seed `DownloadRecord.fileSizeBytes`
    /// so the download-speed sampler has a real byte total to work with —
    /// WhisperKit's `Progress` callback reports file counts (not bytes),
    /// which rounds to ~0 B/s when fed straight into the sampler.
    let estimatedBytes: Int64

    var isEnglishOnly: Bool { id.hasSuffix(".en") }
}

/// Single source of truth for the list of available WhisperKit models.
enum WhisperModelCatalog {
    /// Base and above only. Tiny was withdrawn: its accuracy is too low to be worth offering.
    static let availableModels: [WhisperModelInfo] = [
        WhisperModelInfo(id: "base",       displayName: "Base (Multilingual)",    size: "~142 MB", estimatedBytes: 148_897_792),
        WhisperModelInfo(id: "base.en",    displayName: "Base (English)",         size: "~142 MB", estimatedBytes: 148_897_792),
        WhisperModelInfo(id: "small",      displayName: "Small (Multilingual)",   size: "~466 MB", estimatedBytes: 488_636_416),
        WhisperModelInfo(id: "small.en",   displayName: "Small (English)",        size: "~466 MB", estimatedBytes: 488_636_416),
        WhisperModelInfo(id: "medium",     displayName: "Medium (Multilingual)",  size: "~1.5 GB", estimatedBytes: 1_610_612_736),
        WhisperModelInfo(id: "medium.en",  displayName: "Medium (English)",       size: "~1.5 GB", estimatedBytes: 1_610_612_736),
        WhisperModelInfo(id: "large-v3",   displayName: "Large v3 (Multilingual)", size: "~3 GB",  estimatedBytes: 3_221_225_472),
    ]

    /// Lookup helper for the coordinator's pre-seed path.
    static func estimatedBytes(for modelId: String) -> Int64? {
        availableModels.first { $0.id == modelId }?.estimatedBytes
    }
}
