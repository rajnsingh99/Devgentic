// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowRunRecordSD.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "WorkflowRunRecordSD")

/// SwiftData model for one persisted workflow execution run, back-referencing its `ConversationSD` so deleting a
/// conversation cascades to its runs. Per-node results and variables are stored as JSON blobs; fields needed for
/// listing and filtering are columns.
@Model
final class WorkflowRunRecordSD {

    // MARK: - Persisted Properties

    @Attribute(.unique)
    var id: UUID

    /// Conversation this run belongs to. The inverse and cascade rule is declared on the to-many side
    /// (`ConversationSD.workflowRuns`); this side is a plain `@Relationship` to avoid a duplicate-inverse warning.
    @Relationship
    var conversation: ConversationSD?

    /// Denormalized conversation FK for index-friendly queries.
    var conversationID: UUID

    // Why: existing stores do not gain an index added later (see `ChatMessageSD`'s `#Index`).
    /// Composite index for the only read pattern: this conversation's runs by time.
    #Index<WorkflowRunRecordSD>([\.conversationID, \.timestamp])

    var workflowProfileID: UUID
    var workflowName: String
    var timestamp: Date
    var duration: TimeInterval
    var userInput: String
    var finalOutput: String
    var errorMessage: String?

    /// Raw value of `WorkflowRunRecord.RunStatus` — used as a discriminator.
    var statusRaw: String

    /// Observability join key to `traces.sqlite` `traces.traceID`. Optional: older rows have none and the two stores
    /// keep independent retention, so a nil or dangling value is normal.
    var traceID: String?

    // JSON blobs — never queried, only displayed.
    var nodeResultsData: Data
    var variablesData: Data

    // MARK: - Transient Cache

    @Transient
    private var _cachedRecord: WorkflowRunRecord?

    // MARK: - No `record` accessor

    // No mutable `record` accessor: the decode is lossy, so a round-trip would make losses permanent. Write via
    // `apply(_:blobs:)`; read via `rowSnapshot` and `decodeRecord(from:)`.

    // MARK: - Initializer

    /// - Parameter blobs: Pre-encoded JSON blobs (see `encodeBlobs(for:)`). Pass them
    ///   to keep a large encode off the main actor; omit to encode inline.
    init(record: WorkflowRunRecord, conversation: ConversationSD? = nil, blobs: EncodedBlobs? = nil) {
        let resolved = blobs ?? Self.encodeBlobs(for: record)
        self.id = record.id
        self.conversation = conversation
        self.conversationID = record.conversationID
        self.workflowProfileID = record.workflowProfileID
        self.workflowName = record.workflowName
        self.timestamp = record.timestamp
        self.duration = record.duration
        self.userInput = record.userInput
        self.finalOutput = record.finalOutput
        self.errorMessage = record.error
        self.statusRaw = record.status.rawValue
        self.traceID = record.traceID
        // On insert there are no prior bytes to protect, so write markers that cannot decode as any accepted shape; the
        // decoders then log and flag the row instead of reporting an empty run.
        self.nodeResultsData = resolved.nodeResults ?? Data("NODE_RESULTS_ENCODE_FAILED".utf8)
        self.variablesData = resolved.variables ?? Data("VARIABLES_ENCODE_FAILED".utf8)
        // Like `apply`, the insert path does not park a full copy of the record on the row, except when a blob was refused
        // and the in-memory record is the only readable copy.
        self._cachedRecord = Self.retainsInMemoryRecord(resolved) ? record : nil
        if resolved.nodeResults == nil || resolved.variables == nil {
            logger.fault(
                "[PERSISTENCE] Workflow run \(record.id) ('\(record.workflowName)') was inserted with "
                + "an unencodable blob (nodeResults: \(resolved.nodeResults == nil ? "FAILED" : "ok"), "
                + "variables: \(resolved.variables == nil ? "FAILED" : "ok")). CONSEQUENCE: the row is "
                + "stored with a deliberately-unreadable marker so the history entry reports itself as "
                + "damaged, instead of silently claiming the run had no nodes or no variables."
            )
        }
    }

    // MARK: - Off-main encoding

    /// Pre-encoded JSON blobs for a record, so the (possibly large) encode runs off the main actor and the SwiftData
    /// write only assigns bytes. A nil field means the encoder refused; `apply(_:blobs:)` then skips that column so the
    /// stored value survives.
    struct EncodedBlobs: Sendable {
        let nodeResults: Data?
        let variables: Data?
    }

    /// Whether the row must keep the in-memory record: true only when a blob was refused, since then the in-memory
    /// record is the only readable copy. Normally false so the row does not retain a second full copy of every
    /// finalized run. Pure so the rule is shared by insert and update.
    nonisolated static func retainsInMemoryRecord(_ blobs: EncodedBlobs) -> Bool {
        blobs.nodeResults == nil || blobs.variables == nil
    }

    /// Encodes a record's blobs. Touches no instance state, so it is safe to call from
    /// any task — see `WorkflowRunHistoryStore.upsertFinalized(_:forConversation:)`.
    static func encodeBlobs(for record: WorkflowRunRecord) -> EncodedBlobs {
        EncodedBlobs(
            nodeResults: encodeNodeResults(record.nodeResults),
            variables: encodeVariables(record.variables)
        )
    }

    /// Rewrites every column from `newValue` using blobs encoded elsewhere, rather
    /// than re-encoding on the caller's thread.
    func apply(_ newValue: WorkflowRunRecord, blobs: EncodedBlobs) {
        // The write path does not park the record here, so the row holds no second copy of the run; it is retained only
        // when a blob is refused (below). A re-read therefore decodes the blob off the main actor, as for a cold row.
        _cachedRecord = nil
        // `id` and `conversationID` are identity fields and are never re-assigned after insert.
        workflowProfileID = newValue.workflowProfileID
        workflowName = newValue.workflowName
        timestamp = newValue.timestamp
        duration = newValue.duration
        userInput = newValue.userInput
        finalOutput = newValue.finalOutput
        errorMessage = newValue.error
        statusRaw = newValue.status.rawValue
        traceID = newValue.traceID
        // A nil blob means the encoder refused: skip the assignment so the stored bytes survive rather than overwrite them
        // with an empty-but-valid payload. The scalar columns are recoverable from the run; the blob is not.
        if let nodeResults = blobs.nodeResults {
            nodeResultsData = nodeResults
        } else {
            logger.error(
                "[PERSISTENCE] Workflow run \(id) ('\(workflowName)'): node-results blob was refused "
                + "by the encoder. CONSEQUENCE: the run's other fields are updated but its node "
                + "breakdown keeps the previously-stored value; the history entry may show a stale "
                + "node list rather than a wrong-but-plausible empty one."
            )
        }
        if let variables = blobs.variables {
            variablesData = variables
        } else {
            logger.error(
                "[PERSISTENCE] Workflow run \(id) ('\(workflowName)'): variables blob was refused by "
                + "the encoder. CONSEQUENCE: the run's other fields are updated but its variables keep "
                + "the previously-stored value."
            )
        }
        // Keep the in-memory record only when the bytes on disk do not represent it (see `retainsInMemoryRecord`).
        if Self.retainsInMemoryRecord(blobs) {
            _cachedRecord = newValue
            logger.notice(
                "[PERSISTENCE] Workflow run \(id) ('\(workflowName)'): retaining the in-memory record "
                + "because a blob was refused. CONSEQUENCE: this row holds the only complete copy of "
                + "the run until the app quits; a reader gets the truth rather than the stale bytes, "
                + "at the cost of that copy staying resident."
            )
        }
    }

    // MARK: - Helpers

    // MARK: - Off-main decode (WF-UI6 ≡ WF-PE7)

    /// A Sendable copy of everything decode needs, taken on the main actor so the decode itself can run elsewhere.
    /// SwiftData rows cannot cross actors but their value fields can.
    struct RowSnapshot: Sendable {
        let cached: WorkflowRunRecord?
        let id: UUID
        let conversationID: UUID
        let workflowProfileID: UUID
        let workflowName: String
        let timestamp: Date
        let userInput: String
        let finalOutput: String
        let statusRaw: String
        let duration: TimeInterval
        let errorMessage: String?
        let nodeResultsData: Data
        let variablesData: Data
        let traceID: String?
    }

    /// Cheap on-main copy of references; no decoding happens here. `cached` is non-nil only for a row whose blob encode
    /// was refused, where the in-memory record is the only readable copy.
    var rowSnapshot: RowSnapshot {
        RowSnapshot(
            cached: _cachedRecord,
            id: id, conversationID: conversationID, workflowProfileID: workflowProfileID,
            workflowName: workflowName, timestamp: timestamp, userInput: userInput,
            finalOutput: finalOutput, statusRaw: statusRaw, duration: duration,
            errorMessage: errorMessage, nodeResultsData: nodeResultsData,
            variablesData: variablesData, traceID: traceID
        )
    }

    /// Turns a row's `RowSnapshot` back into a `WorkflowRunRecord`, off the main actor; the app's single decode.
    /// Returns `snapshot.cached` verbatim when set. The blob path is lossy by design and logs what it drops, so never
    /// write a decoded record back.
    nonisolated static func decodeRecord(from snapshot: RowSnapshot) -> WorkflowRunRecord {
        if let cached = snapshot.cached { return cached }
        // No `?? .completed`: an unrecognised status is carried as `.other(raw)` so a run from a newer build is not
        // asserted to have succeeded.
        let status = WorkflowRunRecord.RunStatus(rawValue: snapshot.statusRaw) ?? .other(snapshot.statusRaw)
        return WorkflowRunRecord(
            id: snapshot.id,
            conversationID: snapshot.conversationID,
            workflowProfileID: snapshot.workflowProfileID,
            workflowName: snapshot.workflowName,
            timestamp: snapshot.timestamp,
            userInput: snapshot.userInput,
            nodeResults: decodeNodeResults(from: snapshot.nodeResultsData, runID: snapshot.id, workflowName: snapshot.workflowName),
            finalOutput: snapshot.finalOutput,
            variables: decodeVariables(from: snapshot.variablesData),
            status: status,
            duration: snapshot.duration,
            error: snapshot.errorMessage,
            traceID: snapshot.traceID
        )
    }

    // MARK: - Encode / Decode (blobs)

    /// Current envelope version for the node-results blob. Bump when the on-disk
    /// shape changes so a future migration can branch on a known discriminator
    /// instead of guessing from structure.
    private static let nodeResultsBlobVersion = 1

    /// Encodes node snapshots into the shared `VersionedBlob` envelope (key `schemaVersion`). Returns nil on failure so
    /// the caller keeps what is already stored.
    private static func encodeNodeResults(_ results: [WorkflowRunRecord.WorkflowNodeResultSnapshot]) -> Data? {
        do {
            return try JSONEncoder().encode(
                VersionedBlob(schemaVersion: nodeResultsBlobVersion, payload: results)
            )
        } catch {
            // Return nil rather than a well-formed empty envelope: that would decode cleanly and silently replace the run's
            // node breakdown with zero nodes.
            logger.fault(
                "[PERSISTENCE] Failed to ENCODE workflow node results (\(results.count) node(s)): "
                + "\(error). CONSEQUENCE: the write is refused and any previously-stored node results "
                + "are left intact; this run's node breakdown is not updated. Refusing beats writing "
                + "an empty payload, which would decode cleanly and be indistinguishable from a run "
                + "that genuinely had no nodes."
            )
            assertionFailure("Node results encoding should not fail for valid in-memory values.")
            return nil
        }
    }

    private static func decodeNodeResults(
        from data: Data,
        runID: UUID,
        workflowName: String
    ) -> [WorkflowRunRecord.WorkflowNodeResultSnapshot] {
        let decoder = JSONDecoder()
        // The `VersionedBlob` envelope is the only shape read.
        if let shared = VersionedBlob<[WorkflowRunRecord.WorkflowNodeResultSnapshot]>
            .decode(from: data, decoder: decoder) {
            return shared.payload
        }
        // Resilient fallback: decode node by node so one undecodable node drops only itself instead of the whole run's
        // results.
        return decodeNodeResultsResiliently(from: data, runID: runID, workflowName: workflowName)
    }

    /// Takes the run identity so its logs can name which run lost nodes; a conversation decodes many records in one
    /// pass.
    private static func decodeNodeResultsResiliently(
        from data: Data,
        runID: UUID,
        workflowName: String
    ) -> [WorkflowRunRecord.WorkflowNodeResultSnapshot] {
        guard let rawNodes = Self.rawNodeArray(inBlob: data) else {
            logger.error(
                "[PERSISTENCE] Node-results blob for run \(runID) ('\(workflowName)') "
                + "(\(data.count) bytes) is not a recognised node array "
                + "— not a `payload` envelope. CONSEQUENCE: this run's "
                + "node breakdown renders EMPTY, so the run report shows no steps. The stored bytes "
                + "are NOT overwritten and stay readable by a build that understands the shape."
            )
            return []
        }

        let decoder = JSONDecoder()
        var survivors: [WorkflowRunRecord.WorkflowNodeResultSnapshot] = []
        var dropped = 0
        for element in rawNodes {
            // `.fragmentsAllowed` is load-bearing: without it a scalar element makes `JSONSerialization` raise an Objective-C
            // exception that `try?` cannot catch.
            guard let elementData = try? JSONSerialization.data(withJSONObject: element, options: .fragmentsAllowed),
                  let snapshot = try? decoder.decode(WorkflowRunRecord.WorkflowNodeResultSnapshot.self, from: elementData) else {
                dropped += 1
                continue
            }
            survivors.append(snapshot)
        }
        if dropped > 0 {
            logger.error(
                "[PERSISTENCE] Recovered \(survivors.count) of \(rawNodes.count) node result(s) for "
                + "run \(runID) ('\(workflowName)'); DROPPED \(dropped) that this build cannot decode. CONSEQUENCE: those "
                + "steps are missing from the run report and its node count is short by \(dropped); "
                + "every other node, and the run's final output, are intact. The stored bytes are not "
                + "overwritten, so a build that understands them recovers the full set."
            )
        }
        return survivors
    }

    /// The envelope key a persisted node array lives under (the shared `VersionedBlob` key); it must match the writer's
    /// key.
    private static let nodeArrayEnvelopeKeys = ["payload"]

    /// Returns the raw node array inside the `payload` envelope, or nil if the data is not one. Pure and `nonisolated`
    /// so the envelope-key set can be tested.
    nonisolated static func rawNodeArray(inBlob data: Data) -> [Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in nodeArrayEnvelopeKeys {
            if let array = object[key] as? [Any] { return array }
        }
        return nil
    }

    /// Current persisted shape of `variablesData`. An envelope, not an inline key: the keys are user-typed variable
    /// names, so a variable called "schemaVersion" would collide with the discriminator.
    static let variablesBlobVersion = 1

    private static func encodeVariables(_ variables: [String: String]) -> Data? {
        do {
            return try JSONEncoder().encode(
                VersionedBlob(schemaVersion: variablesBlobVersion, payload: variables)
            )
        } catch {
            // Refuse and keep what is on disk: `Data("{}".utf8)` would decode cleanly as an empty dictionary and hide the
            // loss, as in `encodeNodeResults`.
            logger.fault(
                "[PERSISTENCE] Failed to ENCODE workflow variables (\(variables.count) key(s)): "
                + "\(error). CONSEQUENCE: the write is refused and any previously-stored variables "
                + "are left intact; this run's variables are not updated. Refusing beats writing "
                + "`{}`, which decodes cleanly as \"no variables\" and could never be flagged."
            )
            assertionFailure("Variables encoding should not fail for valid in-memory values.")
            return nil
        }
    }

    private static func decodeVariables(from data: Data) -> [String: String] {
        if let result = VersionedBlob<[String: String]>.decode(from: data) { return result.payload }
        logger.error(
            "[PERSISTENCE] Failed to decode workflow variables (\(data.count) bytes) as the "
            + "versioned envelope. CONSEQUENCE: this run renders with NO "
            + "variables; the stored bytes are untouched and stay readable by a build that understands "
            + "them."
        )
        return [:]
    }
}
