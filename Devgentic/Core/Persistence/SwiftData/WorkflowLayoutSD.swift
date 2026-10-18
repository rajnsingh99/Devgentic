// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowLayoutSD.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "WorkflowLayoutSD")

/// SwiftData model persisting a workflow canvas: one row per workflow profile, keyed by unique
/// `workflowProfileID`. The full layout is a JSON blob in `layoutData`; denormalized node, edge and
/// annotation counts allow quick stats without decoding.
@Model
final class WorkflowLayoutSD {

    // MARK: - Persisted Properties

    /// Foreign key to `BackendProfile.id` for the workflow profile this layout belongs to.
    /// Marked unique so each workflow has exactly one layout row.
    @Attribute(.unique)
    var workflowProfileID: UUID

    var updatedAt: Date

    /// Denormalized for queries / listing without decoding the blob.
    var nodeCount: Int
    var edgeCount: Int
    var annotationCount: Int

    /// JSON-encoded `WorkflowLayout`. Single source of truth for nodes/edges/annotations.
    var layoutData: Data

    // MARK: - Transient Cache

    @Transient
    private var _cachedLayout: WorkflowLayout?

    /// True when `layoutData` could not be decoded and `_cachedLayout` is the `.empty` placeholder rather
    /// than the user's canvas. Stops a read failure becoming a write failure; stricter than the
    /// `BackendProfile` guard (see the setter).
    @Transient
    private var _layoutDecodeFailed: Bool = false

    /// Set by `primeDecodeState` when the blob's stamp exceeds `layoutBlobVersion`. Same transient
    /// discipline as `_layoutDecodeFailed`: never read raw without priming.
    @Transient
    private var _layoutFromNewerVersion: Bool = false

    // MARK: - Computed Accessor

    /// True when the stored canvas could not be read, so `layout` is a placeholder and writes are refused.
    /// Corroborated by the denormalized counts, which live outside the blob: nodes claimed but nothing
    /// decoded.
    var hasUnreadableLayout: Bool {
        primeDecodeState()
        return _layoutDecodeFailed
    }

    /// True when the stored blob was stamped by a newer build than this one.
    /// Writes are refused while true, since re-encoding would strip the newer fields; viewing and running
    /// stay allowed.
    var hasNewerVersionLayout: Bool {
        primeDecodeState()
        return _layoutFromNewerVersion
    }

    /// The blob's stamped version when it exceeds this build's — for the refusal message.
    var newerBlobVersion: Int? {
        primeDecodeState()
        return _layoutFromNewerVersion ? BlobVersioning.version(of: layoutData) : nil
    }

    /// True when the denormalized counts say this row once held content but the blob now decodes to
    /// nothing — out-of-blob evidence of corruption, independent of any decode attempt.
    var countsContradictStoredLayout: Bool {
        primeDecodeState()
        return (nodeCount > 0 || edgeCount > 0 || annotationCount > 0) && _layoutDecodeFailed
    }

    // Why: every accessor that reads `_layoutDecodeFailed` must call this first; the flag is @Transient and
    // false on fresh instances.
    /// Brings `_cachedLayout` / `_layoutDecodeFailed` into agreement with the current stored bytes.
    /// Idempotent and cheap: the decode runs at most once per instance.
    private func primeDecodeState() {
        guard _cachedLayout == nil else { return }
        let outcome = Self.decodeLayout(from: layoutData)
        _cachedLayout = outcome.layout
        _layoutDecodeFailed = outcome.didFail
        // The version probe is separate from decode success: a newer blob usually decodes fine, which makes
        // a downgrade silent; probing here lets every accessor see it regardless of access order.
        if let stamped = BlobVersioning.version(of: layoutData), stamped > Self.layoutBlobVersion {
            _layoutFromNewerVersion = true
            logger.notice(
                "[PERSISTENCE] Workflow layout for profile \(self.workflowProfileID) was saved by a "
                + "NEWER build (blob v\(stamped), this build understands v\(Self.layoutBlobVersion)). "
                + "CONSEQUENCE: the canvas is readable and runnable but READ-ONLY — saving here would "
                + "silently strip the newer version's fields on re-encode."
            )
        }
    }

    /// The decoded `WorkflowLayout`. Reading decodes from `layoutData` (cached);
    /// writing re-encodes and refreshes the denormalized counts + `updatedAt`.
    var layout: WorkflowLayout {
        get {
            primeDecodeState()
            return _cachedLayout ?? .empty
        }
        set {
            // Refuses every write while the stored canvas is unreadable, stricter than `BackendProfile`'s rule.
            // `.empty` is a legal user state, so a blank decode-failure canvas looks like an emptied one.
            primeDecodeState()
            guard !_layoutFromNewerVersion else {
                logger.error(
                    "[PERSISTENCE] Refusing to overwrite NEWER-VERSION workflow layout — profile "
                    + "\(workflowProfileID): the stored blob is v\(BlobVersioning.version(of: layoutData) ?? -1), "
                    + "this build writes v\(Self.layoutBlobVersion), and a re-encode would permanently strip "
                    + "every field this build does not understand. CONSEQUENCE: layoutData is left "
                    + "byte-intact; the canvas stays read-only on this build. Update Devgentic to edit it."
                )
                return
            }
            guard !_layoutDecodeFailed else {
                logger.error(
                    "[PERSISTENCE] Refusing to overwrite unreadable workflow layout — profile "
                    + "\(workflowProfileID): the stored canvas could not be decoded, so this save "
                    + "would replace \(nodeCount) node(s)/\(edgeCount) edge(s)/\(annotationCount) "
                    + "annotation(s) with a canvas the user could not see. CONSEQUENCE: layoutData is "
                    + "left byte-intact and the counts are preserved; the canvas stays read-only "
                    + "until an explicit repair."
                )
                return
            }
            applyLayout(newValue)
        }
    }

    /// Explicitly replaces a canvas that could not be read.
    /// The only sanctioned way past the setter's refusal; discarding an unreadable canvas is destructive
    /// and must not be reachable incidentally.
    func replaceUnreadableLayout(_ newValue: WorkflowLayout, reason: String) {
        logger.warning(
            "[PERSISTENCE] Replacing unreadable workflow layout — profile \(workflowProfileID), "
            + "reason: \(reason). Previous counts were \(nodeCount) node(s)/\(edgeCount) edge(s)/"
            + "\(annotationCount) annotation(s). CONSEQUENCE: the original bytes are overwritten and "
            + "are no longer recoverable."
        )
        _layoutDecodeFailed = false
        applyLayout(newValue)
    }

    /// The persisted fields as they stand, captured before a destructive write so a failed save can restore
    /// this row.
    struct StoredState {
        let layoutData: Data
        let nodeCount: Int
        let edgeCount: Int
        let annotationCount: Int
        let updatedAt: Date
    }

    var storedState: StoredState {
        StoredState(layoutData: layoutData, nodeCount: nodeCount, edgeCount: edgeCount,
                    annotationCount: annotationCount, updatedAt: updatedAt)
    }

    /// Restores what `storedState` captured after a failed save.
    /// The transient caches are cleared, not set, so an unreadable canvas is reported unreadable again.
    func restore(_ state: StoredState) {
        layoutData = state.layoutData
        nodeCount = state.nodeCount
        edgeCount = state.edgeCount
        annotationCount = state.annotationCount
        updatedAt = state.updatedAt
        _cachedLayout = nil
        _layoutDecodeFailed = false
        _layoutFromNewerVersion = false
    }

    /// The actual write. Never call this directly from a save path — go through `layout` so the
    /// refusal applies.
    private func applyLayout(_ newValue: WorkflowLayout) {
        _cachedLayout = newValue
        layoutData = Self.encodeLayout(newValue)
        nodeCount = newValue.nodes.count
        edgeCount = newValue.edges.count
        annotationCount = newValue.annotations.count
        updatedAt = Date()
    }

    // MARK: - Initializer

    init(workflowProfileID: UUID, layout: WorkflowLayout) {
        self.workflowProfileID = workflowProfileID
        self.updatedAt = Date()
        self.nodeCount = layout.nodes.count
        self.edgeCount = layout.edges.count
        self.annotationCount = layout.annotations.count
        self.layoutData = Self.encodeLayout(layout)
        self._cachedLayout = layout
    }

    // MARK: - Encode / Decode Helpers

    // Why: even an additive optional field needs a bump: older decoders drop unknown keys, and the stamp turns
    // that into a refused write.
    /// Encodes `WorkflowLayout` to JSON, asserting on failure rather than writing a corrupt blob.
    /// Current persisted shape of `layoutData`: the version rides as a sibling key; bump it on any change
    /// to nodes, edges or annotations (v1 is the baseline).
    static let layoutBlobVersion = 1

    private static func encodeLayout(_ layout: WorkflowLayout) -> Data {
        do {
            return BlobVersioning.stamped(try JSONEncoder().encode(layout), version: layoutBlobVersion)
        } catch {
            logger.fault(
                "[PERSISTENCE] Failed to encode WorkflowLayout (\(layout.nodes.count) node(s)): "
                + "\(error). CONSEQUENCE: an UNDECODABLE marker blob is written instead, so the next "
                + "read reports the canvas as unreadable and refuses further writes rather than "
                + "silently presenting an empty canvas."
            )
            assertionFailure("WorkflowLayout encoding should never fail for a valid in-memory value.")
            // Deliberately not an encoded `.empty`, which decodes cleanly and looks like a canvas the user
            // emptied. An undecodable blob is reported by `decodeLayout`, so the setter refuses writes.
            return Data(#"{"__devgentic_encode_failure__":true}"#.utf8)
        }
    }

    /// Decodes `WorkflowLayout` from JSON, returning the value and whether the decode failed.
    /// On failure the returned `.empty` is safe to display but must never be written back over
    /// `layoutData`.
    private static func decodeLayout(from data: Data) -> (layout: WorkflowLayout, didFail: Bool) {
        do {
            return (try JSONDecoder().decode(WorkflowLayout.self, from: data), false)
        } catch {
            logger.error(
                "[PERSISTENCE] Failed to decode WorkflowLayout (\(data.count) bytes): \(error). "
                + "CONSEQUENCE: an empty canvas is returned for display ONLY — the stored bytes are "
                + "not overwritten, and writes are refused until an explicit repair."
            )
            return (.empty, true)
        }
    }
}
