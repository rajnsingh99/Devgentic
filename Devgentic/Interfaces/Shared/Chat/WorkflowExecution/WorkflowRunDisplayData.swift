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
        /// Degraded success: completed on a best-effort answer after an early stop
        /// (circuit breaker / iteration budget). Badged amber instead of green.
        var hasWarnings: Bool = false
        /// Whether this node kind produces a meaningful step-by-step timeline
        /// (agent reasoning + tool calls, or an Action node's tool invocation).
        /// Bots, image generators, and structural transform nodes are single-shot;
        /// their timeline holds only incidental events (e.g. model-load thoughts),
        /// so `WorkflowOutputView` hides the Timeline tab and shows Output directly.
        let supportsTimeline: Bool

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

            /// Theme-aware status color — single source of truth for node / connector / outcome cards.
            func color(_ theme: any Theme) -> Color {
                switch self {
                case .completed:          return theme.successColor
                case .failed:             return theme.errorColor
                case .running:            return theme.accentColor
                case .pending, .skipped:  return theme.secondaryText
                }
            }

            var label: String {
                switch self {
                case .pending:   return String(localized: "Waiting")
                case .running:   return String(localized: "Running...")
                case .completed: return String(localized: "Completed")
                case .failed:    return String(localized: "Failed")
                case .skipped:   return String(localized: "Skipped")
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
                    isStreaming: result.status == .running,
                    hasWarnings: result.hasWarnings,
                    // No layout available to resolve the node kind — preserve the
                    // prior behavior of showing the toggle whenever a timeline exists.
                    supportsTimeline: true
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
                    isStreaming: result.status == .running,
                    hasWarnings: result.hasWarnings,
                    supportsTimeline: kindSupportsTimeline(layoutNode.kind)
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
                isStreaming: false,
                supportsTimeline: kindSupportsTimeline(layoutNode.kind)
            )
        }
    }

    // MARK: - Factory: Frozen Run Record

    /// Builds display data from a persisted record. When `liveTimelines` is
    /// provided (typically by `WorkflowDedicatedView` when the in-memory
    /// `WorkflowExecutionState` still corresponds to this record), per-node
    /// timelines are pulled from memory; otherwise they fall back to the
    /// timeline persisted in the snapshot (`WorkflowNodeResultSnapshot.nodeTimeline`),
    /// so historical runs — especially FAILED ones, where the trace is the
    /// debugging evidence — still render the agent's reasoning/tool-call trace
    /// after a restart. Records predating timeline persistence fall back to
    /// the static `Output` view only.
    ///
    /// `layout` (the workflow's current layout) is used only to resolve each
    /// node's kind so the Timeline tab can be hidden for single-shot nodes
    /// (bots etc.). Node IDs are stable, so the live layout reliably classifies
    /// a historical run's nodes; if it's missing the tab simply isn't suppressed.
    static func from(record: WorkflowRunRecord,
                     liveTimelines: [UUID: [TimelineEvent]]? = nil,
                     layout: WorkflowLayout? = nil) -> WorkflowRunDisplayData {
        let nodes = record.nodeResults.map { snapshot in
            // Prefer the in-memory timeline (freshest); fall back to the persisted one.
            let timeline = liveTimelines?[snapshot.nodeID] ?? snapshot.nodeTimeline ?? []
            let supportsTimeline: Bool = {
                guard let layout else { return true }   // unknown layout → preserve prior behavior
                guard let node = layout.nodes.first(where: { $0.id == snapshot.nodeID }) else {
                    return false                        // node no longer in layout → treat as output-only
                }
                return kindSupportsTimeline(node.kind)
            }()
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
                isStreaming: false,
                hasWarnings: snapshot.hasWarnings ?? false,
                supportsTimeline: supportsTimeline
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

    /// Whether a node kind has a meaningful reasoning/tool-call timeline worth
    /// exposing via the Output/Timeline toggle. Agent profiles (including the
    /// agentic Code and nested Workflow profile types) and Action nodes do; bots,
    /// image generators, and structural transform nodes (condition/loop/code/gate/
    /// trigger) are single-shot output, so their Timeline tab is hidden.
    static func kindSupportsTimeline(_ kind: WorkflowNodeKind) -> Bool {
        switch kind {
        case .profile(_, let profileType):
            switch profileType {
            case .agent, .code, .workflow: return true
            case .bot, .imageGen:          return false
            }
        case .action:
            return true
        case .condition, .loop, .code, .gate, .trigger:
            return false
        }
    }

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

// MARK: - Run-level status vocabulary (single source of truth)

/// Canonical icon / color / label for a whole-run status, mirroring
/// `NodeDisplayData.NodeStatus`. The run history list and the dedicated view's
/// run picker delegate here instead of each re-deriving the mapping.
extension WorkflowRunRecord.RunStatus {
    var icon: String {
        switch self {
        case .running:   return "circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    func color(_ theme: any Theme) -> Color {
        switch self {
        case .completed: return theme.successColor
        case .failed:    return theme.errorColor
        case .cancelled: return theme.warningColor
        case .running:   return theme.accentColor
        }
    }

    var label: String {
        switch self {
        case .running:   return String(localized: "Running")
        case .completed: return String(localized: "Completed")
        case .failed:    return String(localized: "Failed")
        case .cancelled: return String(localized: "Cancelled")
        }
    }
}
