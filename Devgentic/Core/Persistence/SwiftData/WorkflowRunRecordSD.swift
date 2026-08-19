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
    /// ⚠️ DECODE-ONLY, deliberately. There is no setter.
    ///
    /// `decodeRecord()` is LOSSY BY DESIGN: `nodeTimeline` nils on a container mismatch, and
    /// `decodeNodeResultsResiliently` drops nodes it cannot read. A `row.record = mutated`
    /// round-trip would therefore re-encode those losses over the surviving bytes and make them
    /// permanent — the same read-modify-write hazard that required a write-refusal guard on the
    /// chat timeline.
    ///
    /// The setter previously existed with ZERO call sites, so removing it costs nothing today and
    /// closes the trap before someone reaches for the convenient-looking assignment. Every write
    /// goes through `apply(_:blobs:)` with a record built fresh in memory — see
    /// `WorkflowRunHistoryStore.write(_:forConversation:blobs:)`. A future feature that wants to
    /// edit one field must construct the whole record explicitly, which forces the author to
    /// confront where the other values came from.
    var record: WorkflowRunRecord {
        if let cached = _cachedRecord { return cached }
        let decoded = decodeRecord()
        _cachedRecord = decoded
        return decoded
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
        // ⚠️ On INSERT there are no prior bytes to protect, so refusal is not available — but the
        // stored value must not be a valid-looking empty one. These markers cannot decode as any of
        // the three accepted shapes, so `decodeNodeResults`/`decodeVariables` log and flag the row
        // rather than silently reporting "this run had no nodes".
        self.nodeResultsData = resolved.nodeResults ?? Data("NODE_RESULTS_ENCODE_FAILED".utf8)
        self.variablesData = resolved.variables ?? Data("VARIABLES_ENCODE_FAILED".utf8)
        if resolved.nodeResults == nil || resolved.variables == nil {
            logger.fault(
                "[PERSISTENCE] Workflow run \(record.id) ('\(record.workflowName)') was inserted with "
                + "an unencodable blob (nodeResults: \(resolved.nodeResults == nil ? "FAILED" : "ok"), "
                + "variables: \(resolved.variables == nil ? "FAILED" : "ok")). CONSEQUENCE: the row is "
                + "stored with a deliberately-unreadable marker so the history entry reports itself as "
                + "damaged, instead of silently claiming the run had no nodes or no variables."
            )
        }
        self._cachedRecord = record
    }

    // MARK: - Off-main encoding

    /// Pre-encoded JSON blobs for a record. Lets the (potentially large) encode run
    /// OFF the main actor while the main-actor SwiftData write only assigns bytes.
    /// `Sendable` (Data is), so it crosses the actor hop safely.
    /// ⚠️ Optional on purpose: `nil` means the encoder REFUSED rather than produced empty bytes.
    /// `apply(_:blobs:)` skips a nil column so the stored value survives. A non-optional field here
    /// is what forced the old "return a well-formed empty payload" fallback, which decoded cleanly
    /// and made the loss permanent and undetectable.
    struct EncodedBlobs: Sendable {
        let nodeResults: Data?
        let variables: Data?
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
        // ⚠️ A nil blob means the encoder REFUSED (see `encodeNodeResults`). Skip the assignment so
        // the previously-stored bytes survive; overwriting them with an empty-but-valid payload is
        // exactly the silent loss this guard exists to prevent. Every other column above has already
        // been updated, so the row is momentarily mixed — that is deliberate: the scalar columns are
        // recoverable from the run, the blob is not.
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
    }

    // MARK: - Helpers

    // MARK: - Off-main decode (WF-UI6 ≡ WF-PE7)

    /// A Sendable copy of everything decode needs, taken on the main actor so the DECODE itself
    /// can leave it.
    ///
    /// ⚠️ Why this exists: `load(forConversation:)` decoded every run's full node-timeline blob —
    /// up to 400 events per node, tool events carrying whole outputs — synchronously on
    /// `@MainActor`, on first visit to a conversation, for a list that shows only headline fields.
    /// SwiftData rows cannot cross actors, but their VALUE fields can; the write path
    /// (`upsertFinalized`) already moves its encode off-main for exactly this reason, and this is
    /// its mirror image.
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
    }

    /// Cheap on-main copy — references only; no decoding happens here. Rows written THIS session
    /// carry `_cachedRecord` and decode for free.
    var rowSnapshot: RowSnapshot {
        RowSnapshot(
            cached: _cachedRecord,
            id: id, conversationID: conversationID, workflowProfileID: workflowProfileID,
            workflowName: workflowName, timestamp: timestamp, userInput: userInput,
            finalOutput: finalOutput, statusRaw: statusRaw, duration: duration,
            errorMessage: errorMessage, nodeResultsData: nodeResultsData,
            variablesData: variablesData
        )
    }

    /// The same decode `decodeRecord()` performs, runnable off the main actor.
    nonisolated static func decodeRecord(from snapshot: RowSnapshot) -> WorkflowRunRecord {
        if let cached = snapshot.cached { return cached }
        let status = WorkflowRunRecord.RunStatus(rawValue: snapshot.statusRaw) ?? .other(snapshot.statusRaw)
        return WorkflowRunRecord(
            id: snapshot.id,
            conversationID: snapshot.conversationID,
            workflowProfileID: snapshot.workflowProfileID,
            workflowName: snapshot.workflowName,
            timestamp: snapshot.timestamp,
            userInput: snapshot.userInput,
            nodeResults: decodeNodeResults(from: snapshot.nodeResultsData),
            finalOutput: snapshot.finalOutput,
            variables: decodeVariables(from: snapshot.variablesData),
            status: status,
            duration: snapshot.duration,
            error: snapshot.errorMessage
        )
    }

    private func decodeRecord() -> WorkflowRunRecord {
        let nodeResults = Self.decodeNodeResults(from: nodeResultsData)
        let variables = Self.decodeVariables(from: variablesData)
        // ⚠️ No `?? .completed`. `RunStatus.init(rawValue:)` never returns nil now — an unrecognised
        // value becomes `.other(raw)` and is carried verbatim, so a run written by a newer build is
        // no longer asserted to have SUCCEEDED just because this build cannot classify it (G82).
        let status = WorkflowRunRecord.RunStatus(rawValue: statusRaw) ?? .other(statusRaw)
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

    /// ⚠️ Writes the SHARED `VersionedBlob` envelope, whose key is `schemaVersion`.
    ///
    /// This column had its own bespoke envelope (`VersionedNodeResults`, key `version`) months before
    /// the app-wide scheme existed. Two spellings of one concept meant `BlobVersioning.version(of:)`
    /// could not read this column at all — caught by `testEveryBlobColumnCarriesAVersion`, which is
    /// precisely why that guard exists. `decodeNodeResults` therefore reads THREE shapes now.
    private static func encodeNodeResults(_ results: [WorkflowRunRecord.WorkflowNodeResultSnapshot]) -> Data? {
        do {
            return try JSONEncoder().encode(
                VersionedBlob(schemaVersion: nodeResultsBlobVersion, payload: results)
            )
        } catch {
            // ⚠️ This used to return `{"schemaVersion":1,"payload":[]}` — a WELL-FORMED empty
            // envelope. That is the worst possible fallback for this column: it decodes CLEANLY, so
            // the read path has no error to catch and no way to ever flag it. A run's entire node
            // breakdown would be replaced by "this run had zero nodes", permanently and invisibly.
            // Returning nil lets the caller keep whatever is already stored.
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

    private static func decodeNodeResults(from data: Data) -> [WorkflowRunRecord.WorkflowNodeResultSnapshot] {
        let decoder = JSONDecoder()
        // ⚠️ THREE shapes, newest first — all three exist on real disks and none may be dropped:
        //   1. the shared `VersionedBlob` envelope (`schemaVersion`/`payload`), written since G19;
        //   2. the bespoke `VersionedNodeResults` envelope (`version`/`nodes`), this column's own
        //      earlier scheme;
        //   3. a bare array, from before any envelope existed.
        // A row only takes a new shape when its run is next written, so 2 and 3 persist indefinitely.
        if let shared = VersionedBlob<[WorkflowRunRecord.WorkflowNodeResultSnapshot]>
            .decode(from: data, decoder: decoder) {
            return shared.payload
        }
        if let versioned = try? decoder.decode(VersionedNodeResults.self, from: data) {
            return versioned.nodes
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

    /// Current persisted shape of `variablesData`.
    ///
    /// ⚠️ ENVELOPE, not an inline key — and this is the one column where that choice is not about
    /// the root shape. `variablesData` IS an object, so a sibling key would fit structurally. But its
    /// keys are workflow VARIABLE NAMES typed by the user, so a variable legitimately called
    /// "schemaVersion" would be indistinguishable from the discriminator: reading it would report a
    /// nonsense version, and writing would silently overwrite the user's variable. The envelope keeps
    /// the two namespaces apart (G19).
    static let variablesBlobVersion = 1

    private static func encodeVariables(_ variables: [String: String]) -> Data? {
        do {
            return try JSONEncoder().encode(
                VersionedBlob(schemaVersion: variablesBlobVersion, payload: variables)
            )
        } catch {
            // ⚠️ `Data("{}".utf8)` decoded cleanly as an EMPTY DICTIONARY via this column's
            // bare-dictionary fallback, so the loss was undetectable forever. Same reasoning as
            // `encodeNodeResults` above: refuse, and keep what is on disk.
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
        // ⚠️ The bare-dictionary fallback is load-bearing: every row written before 2026-08-05 is
        // unwrapped, and a row is only rewritten when its run is touched — so unwrapped blobs persist
        // indefinitely. `VersionedBlob.decode` tries the envelope, then the bare payload.
        if let result = VersionedBlob<[String: String]>.decode(from: data) { return result.payload }
        logger.error(
            "[PERSISTENCE] Failed to decode workflow variables (\(data.count) bytes) as either the "
            + "versioned envelope or a bare dictionary. CONSEQUENCE: this run renders with NO "
            + "variables; the stored bytes are untouched and stay readable by a build that understands "
            + "them."
        )
        return [:]
    }
}
