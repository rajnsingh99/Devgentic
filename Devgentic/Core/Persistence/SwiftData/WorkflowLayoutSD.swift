//
//  WorkflowLayoutSD.swift
//  Devgentic
//
//  SwiftData @Model for `WorkflowLayout` persistence.
//  Replaces the UserDefaults-backed `WorkflowLayoutStore` (sidecar JSON blob).
//
//  One row per workflow profile, keyed by `workflowProfileID` (unique).
//  The full layout (nodes/edges/annotations) is stored as a JSON blob in
//  `layoutData` — mirrors the `BackendProfile.configData` pattern. Reads are
//  always whole-layout (canvas load, executor pre-flight), writes are atomic
//  on "Save Changes", so a single blob is the right granularity.
//
//  Denormalized counts (`nodeCount`, `edgeCount`, `annotationCount`) are kept
//  on the row so listing screens can show quick stats without decoding.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "WorkflowLayoutSD")

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

    // MARK: - Computed Accessor

    /// The decoded `WorkflowLayout`. Reading decodes from `layoutData` (cached);
    /// writing re-encodes and refreshes the denormalized counts + `updatedAt`.
    var layout: WorkflowLayout {
        get {
            if let cached = _cachedLayout { return cached }
            let decoded = Self.decodeLayout(from: layoutData)
            _cachedLayout = decoded
            return decoded
        }
        set {
            _cachedLayout = newValue
            layoutData = Self.encodeLayout(newValue)
            nodeCount = newValue.nodes.count
            edgeCount = newValue.edges.count
            annotationCount = newValue.annotations.count
            updatedAt = Date()
        }
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

    /// Encodes `WorkflowLayout` to JSON. Asserts on failure rather than writing a
    /// corrupt blob — a valid in-memory layout should always encode cleanly.
    private static func encodeLayout(_ layout: WorkflowLayout) -> Data {
        do {
            return try JSONEncoder().encode(layout)
        } catch {
            logger.fault("Failed to encode WorkflowLayout — refusing to persist corrupt data: \(error.localizedDescription)")
            assertionFailure("WorkflowLayout encoding should never fail for a valid in-memory value.")
            // Last-resort empty layout; prevents SwiftData auto-save from silently writing garbage.
            return (try? JSONEncoder().encode(WorkflowLayout.empty)) ?? Data()
        }
    }

    /// Decodes `WorkflowLayout` from JSON. Falls back to `.empty` on decode failure
    /// so a corrupted row never crashes the canvas.
    private static func decodeLayout(from data: Data) -> WorkflowLayout {
        do {
            return try JSONDecoder().decode(WorkflowLayout.self, from: data)
        } catch {
            logger.error("Failed to decode WorkflowLayout: \(error.localizedDescription) — returning .empty.")
            return .empty
        }
    }
}
