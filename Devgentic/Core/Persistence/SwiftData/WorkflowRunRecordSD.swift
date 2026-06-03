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

    init(record: WorkflowRunRecord, conversation: ConversationSD? = nil) {
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
        self.nodeResultsData = Self.encodeNodeResults(record.nodeResults)
        self.variablesData = Self.encodeVariables(record.variables)
        self._cachedRecord = record
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

    private func applyRecord(_ newValue: WorkflowRunRecord) {
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
        nodeResultsData = Self.encodeNodeResults(newValue.nodeResults)
        variablesData = Self.encodeVariables(newValue.variables)
    }

    // MARK: - Encode / Decode (blobs)

    private static func encodeNodeResults(_ results: [WorkflowRunRecord.WorkflowNodeResultSnapshot]) -> Data {
        do {
            return try JSONEncoder().encode(results)
        } catch {
            logger.fault("Failed to encode node results: \(error.localizedDescription)")
            assertionFailure("Node results encoding should not fail for valid in-memory values.")
            return Data("[]".utf8)
        }
    }

    private static func decodeNodeResults(from data: Data) -> [WorkflowRunRecord.WorkflowNodeResultSnapshot] {
        do {
            return try JSONDecoder().decode([WorkflowRunRecord.WorkflowNodeResultSnapshot].self, from: data)
        } catch {
            logger.error("Failed to decode node results: \(error.localizedDescription) — returning [].")
            return []
        }
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
