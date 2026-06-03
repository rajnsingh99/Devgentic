//
//  WorkflowRunDisplayData.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Unified view adapter that both live WorkflowExecutionState and frozen
//  WorkflowRunRecord can produce. All downstream views render from this
//  struct, eliminating live-vs-historical branching in views.
//
//  The live factory (`from(live:layout:)`) takes the workflow layout so it can
//  pre-populate placeholder cards for nodes that haven't started yet ("pending"
//  status) and derive each node's input from upstream node detail in the same
//  way `WorkflowRunRecord.freeze(...)` does. This lets the new card-strip UI
//  show the full pipeline shape from the very first frame, instead of revealing
//  cards one-by-one as nodes start.
//

import SwiftUI

struct WorkflowRunDisplayData {
    let isLive: Bool
    let isRunning: Bool
    let nodeResults: [NodeDisplayData]
    let finalOutput: String
    let variables: [String: String]
    let completedNodes: Int
    let totalNodes: Int
    let workflowError: String?
    let userInput: String
    let timestamp: Date
    let status: WorkflowRunRecord.RunStatus?
    /// Wall-clock duration of the run so the header can show "Total time X.Xs".
    /// For live runs, computed from `startedAt`; for historical, from the record.
    let duration: TimeInterval

    struct NodeDisplayData: Identifiable {
        let id: UUID
        let nodeID: UUID
        let profileName: String
        let status: NodeStatus
        let detail: String
        let duration: TimeInterval
        let input: String?
        let inputSourceLabel: String?
        let nodeTimeline: [TimelineEvent]
        let isStreaming: Bool

        enum NodeStatus: Sendable {
            case pending, running, completed, failed, skipped

            var icon: String {
                switch self {
                case .pending:   return "circle.dotted"
                case .running:   return "arrow.trianglehead.2.clockwise"
                case .completed: return "checkmark.circle.fill"
                case .failed:    return "xmark.circle.fill"
                case .skipped:   return "arrow.right.circle.fill"
                }
            }

            var color: Color {
                switch self {
                case .pending:   return .gray
                case .running:   return .blue
                case .completed: return .green
                case .failed:    return .red
                case .skipped:   return .gray
                }
            }

            var label: String {
                switch self {
                case .pending:   return "Waiting"
                case .running:   return "Running..."
                case .completed: return "Completed"
                case .failed:    return "Failed"
                case .skipped:   return "Skipped"
                }
            }
        }
    }

    // MARK: - Factory: Live Execution State

    /// Builds display data from a live execution state. When `layout` is provided,
    /// pending placeholder cards are pre-populated for layout nodes that haven't
    /// started yet, and per-node inputs are derived from upstream `detail` (or
    /// `state.userInput` for source nodes). When `layout` is nil, behaviour falls
    /// back to "started nodes only" — same as the previous implementation.
    static func from(live state: WorkflowExecutionState, layout: WorkflowLayout? = nil) -> WorkflowRunDisplayData {
        let nodes: [NodeDisplayData]
        if let layout, !layout.nodes.isEmpty {
            nodes = buildNodesFromLayout(state: state, layout: layout)
        } else {
            nodes = state.nodeResults.map { result in
                NodeDisplayData(
                    id: result.id,
                    nodeID: result.nodeID,
                    profileName: result.profileName,
                    status: mapLiveStatus(result.status),
                    detail: result.detail,
                    duration: result.duration,
                    input: nil,
                    inputSourceLabel: nil,
                    nodeTimeline: state.nodeTimelines[result.nodeID] ?? [],
                    isStreaming: result.status == .running
                )
            }
        }

        // Freeze the duration once the run reaches a terminal state. Without this,
        // every view re-render (selection change, hover, canvas toggle, etc.) would
        // recompute against `Date()` and the "Total time" string would tick up
        // indefinitely while the state lingers in memory.
        let endReference = state.completedAt ?? Date()
        let elapsed = endReference.timeIntervalSince(state.startedAt)

        return WorkflowRunDisplayData(
            isLive: true,
            isRunning: state.isRunning,
            nodeResults: nodes,
            finalOutput: state.finalOutput,
            variables: state.variables,
            completedNodes: state.completedNodes,
            totalNodes: state.totalNodes > 0 ? state.totalNodes : nodes.count,
            workflowError: state.workflowError,
            userInput: state.userInput,
            timestamp: state.startedAt,
            status: nil,
            duration: elapsed
        )
    }

    /// Iterates layout nodes (in topological order when possible), merging in the
    /// matching live `WorkflowNodeResult` if present. Nodes that haven't started
    /// yet emit a `.pending` placeholder so the strip shows the full pipeline.
    private static func buildNodesFromLayout(
        state: WorkflowExecutionState,
        layout: WorkflowLayout
    ) -> [NodeDisplayData] {
        // Order: prefer topologicalSort; fall back to layout's intrinsic node order.
        let order: [UUID] = layout.topologicalSort() ?? layout.nodes.map(\.id)
        let nodeByID = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0) })
        let resultByNodeID = Dictionary(uniqueKeysWithValues: state.nodeResults.map { ($0.nodeID, $0) })

        return order.compactMap { nodeID -> NodeDisplayData? in
            guard let layoutNode = nodeByID[nodeID] else { return nil }

            // Compute "input": upstream nodes' detail joined; falls back to
            // user input for source nodes (no upstream edges).
            let upstreamIDs = layout.edges.filter { $0.targetNodeID == nodeID }.map(\.sourceNodeID)
            let upstreamResults = upstreamIDs.compactMap { resultByNodeID[$0] }
            let derivedInput: String? = {
                if !upstreamResults.isEmpty {
                    let combined = upstreamResults
                        .map(\.detail)
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n\n")
                    return combined.isEmpty ? nil : combined
                }
                return state.userInput.isEmpty ? nil : state.userInput
            }()
            let sourceLabel: String? = {
                if !upstreamResults.isEmpty {
                    return upstreamResults.map(\.profileName).joined(separator: ", ")
                }
                return state.userInput.isEmpty ? nil : "User input"
            }()

            if let result = resultByNodeID[nodeID] {
                return NodeDisplayData(
                    id: result.id,
                    nodeID: nodeID,
                    profileName: result.profileName,
                    status: mapLiveStatus(result.status),
                    detail: result.detail,
                    duration: result.duration,
                    input: derivedInput,
                    inputSourceLabel: sourceLabel,
                    nodeTimeline: state.nodeTimelines[nodeID] ?? [],
                    isStreaming: result.status == .running
                )
            }

            // Pending placeholder
            return NodeDisplayData(
                id: nodeID,
                nodeID: nodeID,
                profileName: layoutNode.displayName,
                status: .pending,
                detail: "",
                duration: 0,
                input: derivedInput,
                inputSourceLabel: sourceLabel,
                nodeTimeline: [],
                isStreaming: false
            )
        }
    }

    // MARK: - Factory: Frozen Run Record

    /// Builds display data from a persisted record. When `liveTimelines` is
    /// provided (typically by `WorkflowDedicatedView` when the in-memory
    /// `WorkflowExecutionState` still corresponds to this record), per-node
    /// timelines are pulled in from memory so the "Timeline" tab in
    /// `WorkflowOutputView` can render the agent's reasoning/tool-call trace
    /// even after the run has finalized. Timelines are NOT persisted to disk,
    /// so an app restart drops them and only the static `Output` view remains.
    static func from(record: WorkflowRunRecord,
                     liveTimelines: [UUID: [TimelineEvent]]? = nil) -> WorkflowRunDisplayData {
        let nodes = record.nodeResults.map { snapshot in
            let timeline = liveTimelines?[snapshot.nodeID] ?? []
            return NodeDisplayData(
                id: snapshot.id,
                nodeID: snapshot.nodeID,
                profileName: snapshot.profileName,
                status: mapRecordStatus(snapshot.status),
                detail: snapshot.detail,
                duration: snapshot.duration,
                input: snapshot.input,
                inputSourceLabel: snapshot.inputSourceLabel,
                nodeTimeline: timeline,
                isStreaming: false
            )
        }
        return WorkflowRunDisplayData(
            isLive: false,
            isRunning: false,
            nodeResults: nodes,
            finalOutput: record.finalOutput,
            variables: record.variables,
            completedNodes: record.nodeResults.count,
            totalNodes: record.nodeResults.count,
            workflowError: record.error,
            userInput: record.userInput,
            timestamp: record.timestamp,
            status: record.status,
            duration: record.duration
        )
    }

    // MARK: - Helpers

    private static func mapLiveStatus(_ s: WorkflowNodeResult.Status) -> NodeDisplayData.NodeStatus {
        switch s {
        case .running:   return .running
        case .completed: return .completed
        case .failed:    return .failed
        case .skipped:   return .skipped
        }
    }

    private static func mapRecordStatus(_ s: WorkflowRunRecord.WorkflowNodeResultSnapshot.NodeStatus) -> NodeDisplayData.NodeStatus {
        switch s {
        case .running:   return .running
        case .completed: return .completed
        case .failed:    return .failed
        case .skipped:   return .skipped
        }
    }
}
