// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    /// The "index-friendly" queries above had no index to use (RAG-10 / CR-66): every read is
    /// this conversation's runs by time, so one composite serves predicate and sort.
    /// ⚠️ Existing stores do not gain it — see the note on `ChatMessageSD`'s `#Index`.
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

    /// Observability join key → traces.sqlite `traces.traceID` (Run-Report Phase 5).
    /// Optional: pre-V2 rows have none, and the two stores keep independent
    /// retention, so a nil or dangling value is normal and handled by readers.
    var traceID: String?

    // JSON blobs — never queried, only displayed.
    var nodeResultsData: Data
    var variablesData: Data

    // MARK: - Transient Cache

    @Transient
    private var _cachedRecord: WorkflowRunRecord?

    // MARK: - [CF-34] There is deliberately no `record` accessor

    // A `var record: WorkflowRunRecord` used to sit here: reading decoded the persisted columns +
    // blobs and CACHED the result, writing re-encoded and rewrote every column, mirroring
    // `BackendProfile.details`. Both halves are gone, and so is the private `decodeRecord()` that
    // only the getter ever called — `decodeRecord(from:)` below is now the app's single decode.
    //
    // ⚠️ THE SETTER went first. The decode is LOSSY BY DESIGN (the caveat now lives on
    // `decodeRecord(from:)`), so a `row.record = mutated` round-trip would re-encode those losses
    // over the surviving bytes and make them permanent — the same read-modify-write hazard that
    // required a write-refusal guard on the chat timeline. It had ZERO call sites, so removing it
    // cost nothing and closed the trap before someone reached for the convenient-looking
    // assignment. Every write goes through `apply(_:blobs:)` with a record built fresh in memory —
    // see `WorkflowRunHistoryStore.write(_:forConversation:blobs:)`. A future feature that wants to
    // edit one field must construct the whole record explicitly, which forces the author to
    // confront where the other values came from.
    //
    // ⚠️ THE GETTER went too, and deliberately. It was the ONLY thing that ever FILLED
    // `_cachedRecord` on a read, which is precisely the lifetime retention XUI-14 removed from the
    // write path: one main-actor decode parked a full record — node traces included — on a row
    // that stays reachable through `ConversationSD.workflowRuns` for the life of the process. Its
    // last caller was `WorkflowRunHistoryStore.load(forConversation:)`, which now decodes through
    // `rowSnapshot` + `decodeRecord(from:)` like every other read.
    //
    // `_cachedRecord` itself STAYS: `rowSnapshot` reads it (never fills it), and it is still
    // written by `init`/`apply` under `retainsInMemoryRecord` — the refused-blob case where the
    // in-memory record is the only readable copy. Removing that would turn a logged, recoverable
    // refusal into silent loss. Read-only cache, one filler, one reader.
    //
    // If you need a record from a row, use `rowSnapshot` and decode off the main actor:
    // `WorkflowRunRecordSD.decodeRecord(from: row.rowSnapshot)`.

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
        // ⚠️ On INSERT there are no prior bytes to protect, so refusal is not available — but the
        // stored value must not be a valid-looking empty one. These markers cannot decode as any of
        // the three accepted shapes, so `decodeNodeResults`/`decodeVariables` log and flag the row
        // rather than silently reporting "this run had no nodes".
        self.nodeResultsData = resolved.nodeResults ?? Data("NODE_RESULTS_ENCODE_FAILED".utf8)
        self.variablesData = resolved.variables ?? Data("VARIABLES_ENCODE_FAILED".utf8)
        // [XUI-14] Same rule as `apply`: the insert path does NOT park a full copy of the record
        // on the row. On INSERT a refusal writes a deliberately-unreadable MARKER rather than
        // stale bytes, so the in-memory record is the only readable copy and is kept.
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

    /// Whether the row must hold on to the in-memory record (register XUI-14).
    ///
    /// ⚠️ NORMALLY FALSE, and that is the row's whole point: parking a full record here kept a
    /// second copy of every run finalized in the session — traces included — alive for the app's
    /// lifetime, because the row stays reachable through `ConversationSD.workflowRuns` and nothing
    /// ever nils it. `XUI-11` dropped the traces from the view model's mirror and this quietly kept
    /// them, so for THIS session's runs that strip freed nothing.
    ///
    /// ⚠️ TRUE only when a blob was REFUSED, and then it is not an optimisation but the only
    /// readable copy of the truth: on update the bytes on disk are the PREVIOUS ones, and on insert
    /// they are a deliberately-unreadable marker. Dropping it there turns a logged, recoverable
    /// refusal into silent loss.
    ///
    /// Pure and `nonisolated` (WF-UI5) so the rule is one function rather than a condition repeated
    /// at the insert and update seams — a mutant flipping either one survived the first battery,
    /// because nothing could reach the rule to test it.
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
        // [XUI-14] ⚠️ The write path no longer PARKS the record here. It used to, and that made
        // this row hold a second full copy — every node's trace included — of every run finalized
        // in the session, for the app's lifetime: the row stays reachable through
        // `ConversationSD.workflowRuns`, and nothing ever nils this. `XUI-11` dropped the traces
        // from the view model's mirror and this quietly kept them, so for THIS session's runs the
        // strip freed nothing and only the disk-load path (cold cache) actually paid off.
        //
        // ⚠️ Retained ONLY when a blob was refused, below — then the bytes on disk are the
        // PREVIOUS ones and this is the only copy of the truth, so dropping it would turn a
        // logged, recoverable refusal into silent loss.
        //
        // Nothing reads a warm cache: `rowSnapshot` only ever READS `_cachedRecord` and never
        // fills it, and the filling accessor (`record`) has been REMOVED outright (CF-34).
        // A same-session re-read therefore decodes the blob off-main, exactly as a cold row does —
        // the path WF-UI6 already established does not hitch.
        _cachedRecord = nil
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
        traceID = newValue.traceID
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
        // [XUI-14] See `retainsInMemoryRecord`: kept ONLY when the bytes on disk no longer
        // represent the record.
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
        let traceID: String?
    }

    /// Cheap on-main copy — references only; no decoding happens here.
    ///
    /// ⚠️ `cached` is normally nil (register XUI-14): the write path deliberately stops parking a
    /// full record on the row, so a same-session re-read decodes the blob off-main like any other.
    /// It is non-nil only for a row whose blob encode was REFUSED, where the in-memory record is
    /// the only readable copy — and handing that back is exactly right.
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

    /// Turns a row's `RowSnapshot` back into a `WorkflowRunRecord`, off the main actor.
    ///
    /// ⚠️ [CF-34] THE app's ONE decode. The instance `record` getter and the private
    /// `decodeRecord()` it called are gone, so every read — `load(forConversation:)`,
    /// `loadFinalized`, `loadRecord`, the tests — lands here. A change to the decode rules belongs
    /// in this function and nowhere else.
    ///
    /// ⚠️ Returns `snapshot.cached` VERBATIM when it is non-nil, decoding nothing. That is normally
    /// nil (register XUI-14): the row is only left holding a record when a blob encode was REFUSED,
    /// and there the bytes in the snapshot are the PREVIOUS ones (update) or a deliberately
    /// unreadable marker (insert), so the in-memory record is the only readable copy of the truth.
    ///
    /// ⚠️ The blob path is LOSSY BY DESIGN: `WorkflowNodeResultSnapshot`'s decoder nils
    /// `nodeTimeline` on a container mismatch, and `decodeNodeResultsResiliently` drops nodes it
    /// cannot read. Both log what was lost. This is only safe because nothing re-saves a decoded
    /// record — every writer builds a fresh one in memory — so the losses stay in memory and the
    /// stored bytes remain recoverable by a build that understands them. Do not add a path that
    /// writes a decoded record back; that is exactly what the removed setter would have been.
    nonisolated static func decodeRecord(from snapshot: RowSnapshot) -> WorkflowRunRecord {
        if let cached = snapshot.cached { return cached }
        // ⚠️ No `?? .completed`. `RunStatus.init(rawValue:)` never returns nil now — an unrecognised
        // value becomes `.other(raw)` and is carried verbatim, so a run written by a newer build is
        // no longer asserted to have SUCCEEDED just because this build cannot classify it (G82).
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

    /// Versioned wrapper around the node snapshots. Records written before this
    /// existed store a bare `[WorkflowNodeResultSnapshot]`; `decodeNodeResults`
    /// falls back to that shape.
    /// ⚠️ Writes the SHARED `VersionedBlob` envelope, whose key is `schemaVersion`.
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

    private static func decodeNodeResults(
        from data: Data,
        runID: UUID,
        workflowName: String
    ) -> [WorkflowRunRecord.WorkflowNodeResultSnapshot] {
        let decoder = JSONDecoder()
        // The `VersionedBlob` envelope is the only shape read (2026-10-03 reset: the bespoke
        // `version`/`nodes` envelope and the bare array that preceded it are no longer accepted).
        if let shared = VersionedBlob<[WorkflowRunRecord.WorkflowNodeResultSnapshot]>
            .decode(from: data, decoder: decoder) {
            return shared.payload
        }
        // Resilient fallback: decode node-by-node so ONE undecodable node (e.g. a
        // structural change beyond the lossy nodeTimeline) drops only that node
        // instead of erasing the whole run's results.
        return decodeNodeResultsResiliently(from: data, runID: runID, workflowName: workflowName)
    }

    /// ⚠️ Takes the run identity so its two logs can name WHICH run lost nodes. Without it the
    /// only datum was a byte count, and a conversation decodes up to
    /// `WorkflowRunHistoryStore.maxRecordsPerConversation` records in one pass — so N identical
    /// id-less lines could not be told apart, and the diagnosis the logs exist to enable was
    /// impossible. Every sibling log in this file already threads it.
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
            // ⚠️ `.fragmentsAllowed` is load-bearing, not tidiness. Without it a SCALAR element (a
            // bare string or number where an object was expected) makes `JSONSerialization` RAISE
            // `NSInvalidArgumentException` — an Objective-C exception, which `try?` cannot catch, so
            // the recovery tier CRASHED the app instead of counting a drop. That is the opposite of
            // what this whole ladder exists for.
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

    /// The envelope key a persisted node array lives under — the shared `VersionedBlob` key.
    ///
    /// ⚠️ It must match the WRITER's key. A one-word mismatch here once made this whole last-resort
    /// recovery tier dead against every current blob.
    private static let nodeArrayEnvelopeKeys = ["payload"]

    /// The raw node array inside the `payload` envelope, or nil if this is not one.
    ///
    /// `nonisolated static` and pure so the envelope-key set is testable (WF-UI5) — the defect was a
    /// one-word mismatch between the encoder and this reader, which is precisely the kind of thing a
    /// round-trip test pins and a reading does not.
    nonisolated static func rawNodeArray(inBlob data: Data) -> [Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in nodeArrayEnvelopeKeys {
            if let array = object[key] as? [Any] { return array }
        }
        return nil
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
