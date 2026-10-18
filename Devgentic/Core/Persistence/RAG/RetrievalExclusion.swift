// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RetrievalExclusion.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// What conversation-memory retrieval must NOT return for one turn — parents the model already
/// reads in full, the current turn's own attachments, and (on Redo/Resume) everything from the
/// regenerated reply onward.
///
/// Applied INSIDE the ranker, before a parent can claim one of the limit slots: post-filtering
/// after the cap once starved a turn to zero injected documents while an injectable chunk sat at
/// rank 4.
struct RetrievalExclusion: Sendable, Equatable {

    /// Message parents whose message rides this request in full. Matched only against MESSAGE
    /// parents — a file parent's `sourceMessageID` names the turn that carried it, and that turn
    /// being in the window does not put the file's content in the prompt.
    var messageIDs: Set<UUID> = []

    /// File parents (keyed by path) attached THIS turn. Their current content is delivered with
    /// the turn itself; the indexed copy is the previous version, and the replace-on-reindex runs
    /// only after retrieval.
    var sourceIdentifiers: Set<String> = []

    /// Redo/Resume: parents indexed at or after this instant belong to the reply being replaced
    /// or to turns that came after it — the rejected answer, and the conversation's "future".
    var indexedAtOrAfter: Date? = nil

    static let none = RetrievalExclusion()

    /// A message parent carries its own message id as `sourceIdentifier` — the grammar
    /// `RAGIndexingService.indexSingleMessage` writes. A file parent carries its path. `""` is a
    /// row written before `sourceIdentifier` existed; only message rows reach this path with it
    /// matching a history id, so it is treated as a message row.
    static func isMessageParent(sourceIdentifier: String, sourceMessageID: UUID) -> Bool {
        sourceIdentifier.isEmpty || sourceIdentifier == sourceMessageID.uuidString
    }

    func excludes(sourceMessageID: UUID, sourceIdentifier: String, timestamp: Date) -> Bool {
        if let cutoff = indexedAtOrAfter, timestamp >= cutoff { return true }
        if Self.isMessageParent(sourceIdentifier: sourceIdentifier, sourceMessageID: sourceMessageID) {
            return messageIDs.contains(sourceMessageID)
        }
        return sourceIdentifiers.contains(sourceIdentifier)
    }

    func excludes(_ parent: ParentDocumentEntity) -> Bool {
        excludes(sourceMessageID: parent.sourceMessageID,
                 sourceIdentifier: parent.sourceIdentifier,
                 timestamp: parent.timestamp)
    }

    func excludes(_ hit: RetrievedDocument) -> Bool {
        excludes(sourceMessageID: hit.sourceMessageID,
                 sourceIdentifier: hit.sourceIdentifier,
                 timestamp: hit.timestamp)
    }
}

/// The reply a Redo/Resume is regenerating — the point after which conversation memory is
/// treated as not-yet-happened.
struct RegenerationBoundary: Sendable, Equatable {
    let messageID: UUID
    let timestamp: Date
}
