//
//  WorkflowOutcomeStripView.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Horizontal scrollable strip of workflow node cards + a Final Outcome card.
//  Header and run picker are handled by the parent title bar.
//  Tapping a card selects it and renders its full detail in the output area below.
//

import SwiftUI

struct WorkflowOutcomeStripView: View {
    let displayData: WorkflowRunDisplayData
    @Binding var selectedNodeID: UUID?
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                // Node cards
                ForEach(displayData.nodeResults) { nodeData in
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

                // Running placeholder for nodes not yet started
                if displayData.isLive && displayData.isRunning && displayData.completedNodes < displayData.totalNodes {
                    runningPlaceholder
                }

                // Final Outcome card
                if !displayData.nodeResults.isEmpty {
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minHeight: 200, maxHeight: 280)
    }

    // MARK: - Running Placeholder

    private var runningPlaceholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Running...")
                    .font(theme.fontCaption.weight(.medium))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.top, 10)
            .padding(.horizontal, 10)

            Spacer()

            RoundedRectangle(cornerRadius: 4)
                .fill(theme.surfaceOverlay)
                .frame(width: 100, height: 8)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .frame(width: 200)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.controlBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.surfaceOverlayStrong.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
        )
    }
}
