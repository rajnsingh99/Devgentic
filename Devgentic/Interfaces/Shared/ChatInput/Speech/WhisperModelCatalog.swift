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

    var isEnglishOnly: Bool { id.hasSuffix(".en") }
}

/// Single source of truth for the list of available WhisperKit models.
enum WhisperModelCatalog {
    static let availableModels: [WhisperModelInfo] = [
        WhisperModelInfo(id: "tiny",       displayName: "Tiny (Multilingual)",    size: "~75 MB"),
        WhisperModelInfo(id: "tiny.en",    displayName: "Tiny (English)",         size: "~75 MB"),
        WhisperModelInfo(id: "base",       displayName: "Base (Multilingual)",    size: "~142 MB"),
        WhisperModelInfo(id: "base.en",    displayName: "Base (English)",         size: "~142 MB"),
        WhisperModelInfo(id: "small",      displayName: "Small (Multilingual)",   size: "~466 MB"),
        WhisperModelInfo(id: "small.en",   displayName: "Small (English)",        size: "~466 MB"),
        WhisperModelInfo(id: "medium",     displayName: "Medium (Multilingual)",  size: "~1.5 GB"),
        WhisperModelInfo(id: "medium.en",  displayName: "Medium (English)",       size: "~1.5 GB"),
        WhisperModelInfo(id: "large-v3",   displayName: "Large v3 (Multilingual)", size: "~3 GB"),
    ]
}
