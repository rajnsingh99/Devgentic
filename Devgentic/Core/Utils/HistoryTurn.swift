// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  HistoryTurn.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// One prior user or assistant turn, as a list of typed parts.
struct HistoryTurn: Sendable, Equatable {

    enum Role: String, Sendable {
        case user
        case assistant
    }

    /// A single piece of a turn. Text and media are separate cases so that
    /// lowering to a text-only wire shape is an explicit, lossy-by-choice
    /// operation rather than an accident.
    enum Part: Sendable, Equatable {
        case text(String)
        /// A durable pointer to binary content — bytes are NOT inlined here.
        /// Resolution is deferred to request-build so a history turn that is
        /// about to be trimmed by the char budget never pays a decode.
        case media(kind: MediaKind, reference: MediaReference, label: String?)
    }

    var role: Role
    var parts: [Part]

    init(role: Role, parts: [Part]) {
        self.role = role
        self.parts = parts
    }

    /// Convenience for the overwhelmingly common text-only turn.
    init(role: Role, text: String) {
        self.init(role: role, parts: [.text(text)])
    }

    // MARK: - Projections

    /// The turn's text content. The converter emits exactly ONE text part per
    /// turn, so the separator is unreachable in practice — it exists so a future
    /// multi-part turn degrades to readable prose instead of run-together text.
    var text: String {
        parts.compactMap { part in
            if case .text(let value) = part { return value }
            return nil
        }
        .joined(separator: "\n\n")
    }

    /// Media parts in wire order. Empty for text-only turns (the common case).
    var media: [(kind: MediaKind, reference: MediaReference, label: String?)] {
        parts.compactMap { part in
            if case .media(let kind, let reference, let label) = part {
                return (kind, reference, label)
            }
            return nil
        }
    }

    /// Image media only — the one modality any provider adapter can serialize today.
    var imageMedia: [(reference: MediaReference, label: String?)] {
        media.compactMap { $0.kind == .image ? ($0.reference, $0.label) : nil }
    }

    var hasMedia: Bool {
        parts.contains { if case .media = $0 { return true }; return false }
    }

    // MARK: - Lowering

    // Why: two consumers forward these dicts wholesale (`ToolTurnAdapter`, `LLMProviders`); handle any new `Part` here.
    /// Lowers to the legacy canonical wire dict; media is dropped, as that path has no seam to carry an image.
    /// Images reach native providers via the executor's splice (`ReActAgentExecutor.spliceHistoryImages`).
    func asWireDict() -> [String: String] {
        ["role": role.rawValue, "content": text]
    }

    /// Character weight for the history char budget: text counts its length, each image a flat token-realistic equivalent.
    /// Weighing images at base64 size would let one screenshot evict an entire conversation.
    var budgetChars: Int {
        text.count + ImageTokenHeuristic.budgetChars(imageCount: imageMedia.count)
    }
}

extension Array where Element == HistoryTurn {
    /// Lowers a whole history to the legacy wire shape, preserving order.
    func asWireDicts() -> [[String: String]] {
        map { $0.asWireDict() }
    }

    var totalImageCount: Int {
        reduce(0) { $0 + $1.imageMedia.count }
    }
}
