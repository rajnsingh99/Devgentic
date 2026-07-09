//
//  WorkflowRunRecord.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Persistable snapshot of a single workflow execution run.
//  Created by freezing a live WorkflowExecutionState when execution completes.
//  Separate from ChatMessage — workflow results have a fundamentally different
//  shape (DAG of node results) than chat messages (linear conversation).
//

import Foundation

/// Persistent record of a single workflow execution run.
struct WorkflowRunRecord: Identifiable, Codable, Sendable, Equatable {

    let id: UUID
    let conversationID: UUID
    let workflowProfileID: UUID
    let workflowName: String
    let timestamp: Date
    let userInput: String

    /// Per-node results snapshot.
    var nodeResults: [WorkflowNodeResultSnapshot]
    var finalOutput: String
    var variables: [String: String]
    var status: RunStatus
    var duration: TimeInterval
    var error: String?

    // MARK: - Run Status

    enum RunStatus: String, Codable, Sendable, Equatable {
        case running
        case completed
        case failed
        case cancelled
    }

    // MARK: - Node Result Snapshot (Codable-safe)

    /// Codable snapshot of a node result for persistence.
    /// Mirrors `WorkflowNodeResult` from WorkflowExecutionView but is fully Codable.
    struct WorkflowNodeResultSnapshot: Identifiable, Codable, Sendable, Equatable {
        let id: UUID
        let nodeID: UUID
        let profileName: String
        let status: NodeStatus
        let detail: String
        let duration: TimeInterval
        let input: String?
        let inputSourceLabel: String?
        /// The node's reasoning/tool-call trace, persisted so historical runs (esp. FAILED ones,
        /// where the trace is the debugging evidence) can still render the agent timeline after
        /// the in-memory `WorkflowExecutionState` is gone. Optional → old records decode as nil.
        let nodeTimeline: [TimelineEvent]?
        /// Degraded success (completed on a best-effort answer after an early stop).
        /// Optional → old records decode as nil (= no warnings).
        let hasWarnings: Bool?

        enum NodeStatus: String, Codable, Sendable, Equatable {
            case running, completed, failed, skipped
        }

        // Backward-compatible decoding (old records lack input fields / nodeTimeline)
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            nodeID = try c.decode(UUID.self, forKey: .nodeID)
            profileName = try c.decode(String.self, forKey: .profileName)
            status = try c.decode(NodeStatus.self, forKey: .status)
            detail = try c.decode(String.self, forKey: .detail)
            duration = try c.decode(TimeInterval.self, forKey: .duration)
            input = try c.decodeIfPresent(String.self, forKey: .input)
            inputSourceLabel = try c.decodeIfPresent(String.self, forKey: .inputSourceLabel)
            nodeTimeline = try c.decodeIfPresent([TimelineEvent].self, forKey: .nodeTimeline)
            hasWarnings = try c.decodeIfPresent(Bool.self, forKey: .hasWarnings)
        }

        init(id: UUID, nodeID: UUID, profileName: String, status: NodeStatus, detail: String, duration: TimeInterval, input: String? = nil, inputSourceLabel: String? = nil, nodeTimeline: [TimelineEvent]? = nil, hasWarnings: Bool? = nil) {
            self.id = id
            self.nodeID = nodeID
            self.profileName = profileName
            self.status = status
            self.detail = detail
            self.duration = duration
            self.input = input
            self.inputSourceLabel = inputSourceLabel
            self.nodeTimeline = nodeTimeline
            self.hasWarnings = hasWarnings
        }
    }

    // MARK: - Factory

    /// Freezes a live WorkflowExecutionState into a persistent record.
    static func freeze(
        from state: WorkflowExecutionState,
        conversationID: UUID,
        workflowProfileID: UUID,
        workflowName: String,
        userInput: String,
        timestamp: Date,
        layout: WorkflowLayout? = nil
    ) -> WorkflowRunRecord {
        let nodeSnapshots = state.nodeResults.map { result in
            // Compute per-node input from edge topology (Tier 2)
            var inputText: String? = nil
            var sourceLabel: String? = nil
            if let layout {
                let upstreamEdges = layout.edges.filter { $0.targetNodeID == result.nodeID }
                let upstreamNodeIDs = Set(upstreamEdges.map(\.sourceNodeID))
                let upstreamResults = state.nodeResults.filter { upstreamNodeIDs.contains($0.nodeID) }
                if !upstreamResults.isEmpty {
                    inputText = upstreamResults.map(\.detail).joined(separator: "\n\n")
                    sourceLabel = upstreamResults.map(\.profileName).joined(separator: ", ")
                }
            }

            return WorkflowNodeResultSnapshot(
                id: result.id,
                nodeID: result.nodeID,
                profileName: result.profileName,
                status: {
                    switch result.status {
                    case .running:   return .running
                    case .completed: return .completed
                    case .failed:    return .failed
                    case .skipped:   return .skipped
                    }
                }(),
                detail: result.detail,
                duration: result.duration,
                input: inputText,
                inputSourceLabel: sourceLabel,
                // Persist the trace (capped from the end — on failure the most recent
                // events are the diagnostic ones). Empty → nil keeps old-record parity.
                nodeTimeline: state.nodeTimelines[result.nodeID].flatMap { events in
                    events.isEmpty ? nil : Array(events.suffix(400))
                },
                hasWarnings: result.hasWarnings ? true : nil
            )
        }

        let status: RunStatus = {
            if let _ = state.workflowError { return .failed }
            if state.nodeResults.contains(where: { $0.status == .failed }) { return .failed }
            return .completed
        }()

        let totalDuration = state.nodeResults.reduce(0.0) { $0 + $1.duration }

        return WorkflowRunRecord(
            id: UUID(),
            conversationID: conversationID,
            workflowProfileID: workflowProfileID,
            workflowName: workflowName,
            timestamp: timestamp,
            userInput: userInput,
            nodeResults: nodeSnapshots,
            finalOutput: state.finalOutput,
            variables: state.variables,
            status: status,
            duration: totalDuration,
            error: state.workflowError
        )
    }
}
