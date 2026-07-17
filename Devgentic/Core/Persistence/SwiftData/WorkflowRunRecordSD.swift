//
//  WorkflowRunRecordSD.swift
//  Devgentic
//
//  SwiftData @Model for `WorkflowRunRecord` persistence.
//  Replaces the UserDefaults-backed `WorkflowRunHistoryStore` (per-conversation JSON arrays).
//
//  One row per workflow execution run. Records are keyed by their own `id`
//  (unique) and back-reference `ConversationSD` via a SwiftData relationship so
//  deleting a conversation cascades to its runs.
//
//  Per-node results and per-run variables are stored as JSON blobs
//  (`nodeResultsData`, `variablesData`) — never queried, only rendered, so a
//  blob is the right granularity. Top-level fields needed for listing and
//  filtering (timestamp, status, duration, workflowProfileID, etc.) are
//  promoted to columns.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "WorkflowRunRecordSD")

@Model
final class WorkflowRunRecordSD {

    // MARK: - Persisted Properties

    @Attribute(.unique)
    var id: UUID

    /// Conversation this run belongs to. The inverse + cascade rule is declared
    /// on the to-many side (`ConversationSD.workflowRuns`), matching the
    /// `ChatMessageSD.conversation` / `ConversationSD.messages` pattern. Marking
    /// this side as a plain `@Relationship` keeps SwiftData from raising a
    /// duplicate-inverse warning.
    @Relationship
    var conversation: ConversationSD?

    /// Denormalized conversation FK for index-friendly queries.
    var conversationID: UUID

    var workflowProfileID: UUID
    var workflowName: String
    var timestamp: Date
    var duration: TimeInterval
    var userInput: String
    var finalOutput: String
    var errorMessage: String?

    /// Raw value of `WorkflowRunRecord.RunStatus` — used as a discriminator.
    var statusRaw: String

    // JSON blobs — never queried, only displayed.
    var nodeResultsData: Data
    var variablesData: Data

    // MARK: - Transient Cache

    @Transient
    private var _cachedRecord: WorkflowRunRecord?

    // MARK: - Computed Accessor

    /// The decoded `WorkflowRunRecord` value type. Reading decodes from the
    /// persisted columns + blobs (cached); writing re-encodes and updates all
    /// columns to match. Mirrors `BackendProfile.details`.
    var record: WorkflowRunRecord {
        get {
            if let cached = _cachedRecord { return cached }
            let decoded = decodeRecord()
            _cachedRecord = decoded
            return decoded
        }
        set {
            _cachedRecord = newValue
            applyRecord(newValue)
        }
    }

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
        self.nodeResultsData = resolved.nodeResults
        self.variablesData = resolved.variables
        self._cachedRecord = record
    }

    // MARK: - Off-main encoding

    /// Pre-encoded JSON blobs for a record. Lets the (potentially large) encode run
    /// OFF the main actor while the main-actor SwiftData write only assigns bytes.
    /// `Sendable` (Data is), so it crosses the actor hop safely.
    struct EncodedBlobs: Sendable {
        let nodeResults: Data
        let variables: Data
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
        _cachedRecord = newValue
        // `id` and `conversationID` are intentionally not re-assigned —
        // they're identity fields and should never change post-insert.
        workflowProfileID = newValue.workflowProfileID
        workflowName = newValue.workflowName
        timestamp = newValue.timestamp
        duration = newValue.duration
        userInput = newValue.userInput
        finalOutput = newValue.finalOutput
        errorMessage = newValue.error
        statusRaw = newValue.status.rawValue
        nodeResultsData = blobs.nodeResults
        variablesData = blobs.variables
    }

    // MARK: - Helpers

    private func decodeRecord() -> WorkflowRunRecord {
        let nodeResults = Self.decodeNodeResults(from: nodeResultsData)
        let variables = Self.decodeVariables(from: variablesData)
        let status = WorkflowRunRecord.RunStatus(rawValue: statusRaw) ?? .completed
        return WorkflowRunRecord(
            id: id,
            conversationID: conversationID,
            workflowProfileID: workflowProfileID,
            workflowName: workflowName,
            timestamp: timestamp,
            userInput: userInput,
            nodeResults: nodeResults,
            finalOutput: finalOutput,
            variables: variables,
            status: status,
            duration: duration,
            error: errorMessage
        )
    }

    /// Inline-encoding apply, used by the `record` setter. Prefer
    /// `apply(_:blobs:)` with off-main-encoded blobs on hot paths.
    private func applyRecord(_ newValue: WorkflowRunRecord) {
        apply(newValue, blobs: Self.encodeBlobs(for: newValue))
    }

    // MARK: - Encode / Decode (blobs)

    /// Current envelope version for the node-results blob. Bump when the on-disk
    /// shape changes so a future migration can branch on a known discriminator
    /// instead of guessing from structure.
    private static let nodeResultsBlobVersion = 1

    /// Versioned wrapper around the node snapshots. Records written before this
    /// existed store a bare `[WorkflowNodeResultSnapshot]`; `decodeNodeResults`
    /// falls back to that shape.
    private struct VersionedNodeResults: Codable {
        let version: Int
        let nodes: [WorkflowRunRecord.WorkflowNodeResultSnapshot]
    }

    private static func encodeNodeResults(_ results: [WorkflowRunRecord.WorkflowNodeResultSnapshot]) -> Data {
        do {
            return try JSONEncoder().encode(VersionedNodeResults(version: nodeResultsBlobVersion, nodes: results))
        } catch {
            logger.fault("Failed to encode node results: \(error.localizedDescription)")
            assertionFailure("Node results encoding should not fail for valid in-memory values.")
            return Data("{\"version\":\(nodeResultsBlobVersion),\"nodes\":[]}".utf8)
        }
    }

    private static func decodeNodeResults(from data: Data) -> [WorkflowRunRecord.WorkflowNodeResultSnapshot] {
        let decoder = JSONDecoder()
        // Current shape: versioned envelope.
        if let versioned = try? decoder.decode(VersionedNodeResults.self, from: data) {
            return versioned.nodes
        }
        // Legacy shape: bare array (records written before the envelope existed).
        if let bare = try? decoder.decode([WorkflowRunRecord.WorkflowNodeResultSnapshot].self, from: data) {
            return bare
        }
        // Resilient fallback: decode node-by-node so ONE undecodable node (e.g. a
        // structural change beyond the lossy nodeTimeline) drops only that node
        // instead of erasing the whole run's results.
        return decodeNodeResultsResiliently(from: data)
    }

    private static func decodeNodeResultsResiliently(from data: Data) -> [WorkflowRunRecord.WorkflowNodeResultSnapshot] {
        // Pull the raw node array whether the blob is a bare array or an envelope.
        let root = try? JSONSerialization.jsonObject(with: data)
        let rawNodes: [Any]
        if let array = root as? [Any] {
            rawNodes = array
        } else if let object = root as? [String: Any], let array = object["nodes"] as? [Any] {
            rawNodes = array
        } else {
            logger.error("Node results blob is neither an array nor a versioned envelope — returning [].")
            return []
        }

        let decoder = JSONDecoder()
        var survivors: [WorkflowRunRecord.WorkflowNodeResultSnapshot] = []
        var dropped = 0
        for element in rawNodes {
            guard let elementData = try? JSONSerialization.data(withJSONObject: element),
                  let snapshot = try? decoder.decode(WorkflowRunRecord.WorkflowNodeResultSnapshot.self, from: elementData) else {
                dropped += 1
                continue
            }
            survivors.append(snapshot)
        }
        if dropped > 0 {
            logger.error("Recovered \(survivors.count) node result(s); dropped \(dropped) undecodable node(s).")
        }
        return survivors
    }

    private static func encodeVariables(_ variables: [String: String]) -> Data {
        do {
            return try JSONEncoder().encode(variables)
        } catch {
            logger.fault("Failed to encode variables: \(error.localizedDescription)")
            assertionFailure("Variables encoding should not fail for valid in-memory values.")
            return Data("{}".utf8)
        }
    }

    private static func decodeVariables(from data: Data) -> [String: String] {
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            logger.error("Failed to decode variables: \(error.localizedDescription) — returning [:].")
            return [:]
        }
    }
}
