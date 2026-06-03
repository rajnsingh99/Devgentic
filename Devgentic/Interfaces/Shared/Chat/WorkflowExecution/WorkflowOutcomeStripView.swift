//
//  WorkflowOutcomeStripView.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Horizontal pipeline view: agent cards interleaved with status-aware
//  connectors, terminating in the Final Outcome card. Each connector takes its
//  appearance from the *upstream* card's status (since upstream completion is
//  what unlocks the downstream input).
//
//  When the parent passes layout-aware display data, this view shows the entire
//  pipeline (including pending placeholder cards) on the very first frame —
//  matching the wireframe where Agent 1 + Final Outcome are visible before any
//  node has actually run.
//

import SwiftUI

struct WorkflowOutcomeStripView: View {
    let displayData: WorkflowRunDisplayData
    @Binding var selectedNodeID: UUID?
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(displayData.nodeResults.enumerated()), id: \.element.id) { index, nodeData in
                    if index > 0 {
                        WorkflowConnectorView(
                            upstreamStatus: displayData.nodeResults[index - 1].status
                        )
                    }
                    WorkflowOutcomeCardView(
                        nodeData: nodeData,
                        isSelected: selectedNodeID == nodeData.nodeID,
                        onTap: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedNodeID = nodeData.nodeID
                            }
                        }
                    )
                }

                if !displayData.nodeResults.isEmpty {
                    WorkflowConnectorView(
                        upstreamStatus: displayData.nodeResults.last?.status ?? .pending
                    )
                    WorkflowFinalOutcomeCardView(
                        displayData: displayData,
                        isSelected: selectedNodeID == nil,
                        onTap: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedNodeID = nil
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .frame(minHeight: 220, maxHeight: 240)
        .background(stripBackground)
    }

    /// Subtle dotted background matching the wireframe's "canvas-like" feel.
    private var stripBackground: some View {
        Rectangle()
            .fill(theme.secondaryBackground.opacity(0.35))
    }
}
