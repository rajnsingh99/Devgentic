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
            case running, completed, failed, skipped

            var icon: String {
                switch self {
                case .running:   return "arrow.trianglehead.2.clockwise"
                case .completed: return "checkmark.circle.fill"
                case .failed:    return "xmark.circle.fill"
                case .skipped:   return "arrow.right.circle.fill"
                }
            }

            var color: Color {
                switch self {
                case .running:   return .blue
                case .completed: return .green
                case .failed:    return .red
                case .skipped:   return .gray
                }
            }

            var label: String {
                switch self {
                case .running:   return "Running..."
                case .completed: return "Completed"
                case .failed:    return "Failed"
                case .skipped:   return "Skipped"
                }
            }
        }
    }

    // MARK: - Factory: Live Execution State

    static func from(live state: WorkflowExecutionState) -> WorkflowRunDisplayData {
        let nodes = state.nodeResults.map { result in
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
        return WorkflowRunDisplayData(
            isLive: true,
            isRunning: state.isRunning,
            nodeResults: nodes,
            finalOutput: state.finalOutput,
            variables: state.variables,
            completedNodes: state.completedNodes,
            totalNodes: state.totalNodes,
            workflowError: state.workflowError,
            userInput: "",
            timestamp: Date(),
            status: nil
        )
    }

    // MARK: - Factory: Frozen Run Record

    static func from(record: WorkflowRunRecord) -> WorkflowRunDisplayData {
        let nodes = record.nodeResults.map { snapshot in
            NodeDisplayData(
                id: snapshot.id,
                nodeID: snapshot.nodeID,
                profileName: snapshot.profileName,
                status: mapRecordStatus(snapshot.status),
                detail: snapshot.detail,
                duration: snapshot.duration,
                input: snapshot.input,
                inputSourceLabel: snapshot.inputSourceLabel,
                nodeTimeline: [],
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
            status: record.status
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
