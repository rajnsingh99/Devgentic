// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  HistoryTurn.swift
//  Devgentic
//
//  Neutral, modality-agnostic representation of ONE prior conversation turn
//  fed back to the model as native history.
//
//  Replaces the previous `[String: String]` turn dicts. A String→String dict
//  cannot carry image data, which is why prior-turn images were structurally
//  unrepresentable: a user could attach an image, have the model describe it,
//  then ask a follow-up one turn later and be told "no image was provided".
//
//  Adding a modality is now a new `Part` case, not a plumbing rewrite.
//
//  LIFECYCLE: ephemeral. Built per-request by `NativeHistoryConverter`, carried
//  on `AgentInput`/`SemanticContext`, consumed at request-build. NEVER persisted
//  — there is no store migration behind this type, and it deliberately does not
//  conform to `Codable`.
//
//  BYTE-PARITY CONTRACT: `asWireDict()` is the single lowering back to the
//  legacy `["role": …, "content": …]` shape. For a text-only turn it MUST
//  reproduce exactly what the converter used to emit inline, or every existing
//  conversation's KV-cache prefix shifts. See `HistoryTurnTests` for the pin.
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

    /// Lowers to the legacy canonical wire dict.
    ///
    /// ⚠️ BYTE-PARITY SURFACE. Two consumers forward these dicts WHOLESALE rather
    /// than by field — `ToolTurnAdapter.normalizeCanonical` (`message as [String: Any]`)
    /// and the key-enumerating coercion in `LLMProviders`. Neither raises a compile
    /// error if this type gains a part that the lowering forgets, so any new `Part`
    /// case must be handled here deliberately.
    ///
    /// Media is intentionally DROPPED: the prompt-builder path (`[[String: String]]`)
    /// has no seam that can carry an image. Images reach native providers via the
    /// executor's splice, which reads `imageMedia` directly. See
    /// `ReActAgentExecutor.spliceHistoryImages`.
    func asWireDict() -> [String: String] {
        ["role": role.rawValue, "content": text]
    }

    /// Character weight for the history char budget.
    ///
    /// Text counts its real length; each image counts a flat token-realistic
    /// equivalent rather than its base64 length. Weighing images at base64 size
    /// would let one screenshot evict an entire conversation.
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
