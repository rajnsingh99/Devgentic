//
//  WorkflowInteractionPanel.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Renders pending HITL interactions from workflow nodes as stacked cards.
//  Unlike ChatMessage.pendingInteraction (single), workflows can have multiple
//  concurrent interactions from parallel nodes. Each card shows node identity,
//  recent timeline context, upstream chain, and request-specific controls.
//

import SwiftUI

struct WorkflowInteractionPanel: View {
    let executionState: WorkflowExecutionState
    @Environment(MainApplicationViewModel.self) private var viewModel
    @Environment(\.appTheme) private var theme

    var body: some View {
        let interactions = Array(executionState.pendingInteractions.values)
            .sorted(by: { $0.timestamp < $1.timestamp })

        if !interactions.isEmpty {
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Text("\(interactions.count) node\(interactions.count == 1 ? "" : "s") awaiting input")
                        .font(theme.fontCaption.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(theme.secondaryBackground)

                Divider()

                ScrollView(.vertical) {
                    VStack(spacing: 10) {
                        ForEach(interactions) { request in
                            WorkflowInteractionCard(request: request, executionState: executionState)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: 300)
            }
        }
    }
}

// MARK: - Interaction Card

private struct WorkflowInteractionCard: View {
    let request: WorkflowInteractionRequest
    let executionState: WorkflowExecutionState
    @Environment(MainApplicationViewModel.self) private var viewModel
    @Environment(\.appTheme) private var theme
    @State private var userInputText: String = ""

    private var nodeColor: Color {
        switch request.nodeKind {
        case .profile(_, let pType):
            switch pType {
            case .bot: return .blue
            case .agent: return .green
            case .workflow: return .purple
            case .imageGen: return .orange
            }
        case .condition:  return .yellow
        case .loop:       return .orange
        case .code:       return .cyan
        case .gate:       return .red
        case .trigger:    return .gray
        }
    }

    private var nodeIcon: String {
        switch request.nodeKind {
        case .profile(_, let pType): return pType.iconName
        case .condition:  return "arrow.triangle.branch"
        case .loop:       return "arrow.trianglehead.2.clockwise"
        case .code:       return "chevron.left.forwardslash.chevron.right"
        case .gate:       return "hand.raised"
        case .trigger:    return "bolt"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Node identity row
            HStack(spacing: 8) {
                Image(systemName: nodeIcon)
                    .font(.system(size: 12))
                    .foregroundColor(nodeColor)
                Text(request.nodeName)
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Text(nodeKindLabel)
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.surfaceOverlay))
            }

            // Upstream chain
            if !request.upstreamNodeNames.isEmpty {
                HStack(spacing: 4) {
                    Text("Upstream:")
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                    Text(request.upstreamNodeNames.joined(separator: " → "))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }
            }

            // Recent timeline snippet
            if !request.recentTimeline.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(request.recentTimeline.suffix(3)) { event in
                        timelineSnippetRow(event: event)
                    }
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.surfaceOverlay.opacity(0.4))
                )
            }

            Divider()

            // Request-specific content + controls
            requestContent
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(nodeColor.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Request Content

    @ViewBuilder
    private var requestContent: some View {
        switch request.requestType {
        case .gate(let prompt, let options):
            VStack(alignment: .leading, spacing: 8) {
                Text(prompt)
                    .font(theme.fontBody)
                    .foregroundColor(theme.primaryText)
                HStack(spacing: 8) {
                    Spacer()
                    ForEach(options, id: \.self) { option in
                        Button(option) {
                            let approved = option == options.first
                            viewModel.submitToolApproval(operationID: request.id, approved: approved)
                            executionState.removePendingInteraction(operationID: request.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(option == options.first ? .green : .red)
                    }
                }
            }

        case .askUser(let question):
            VStack(alignment: .leading, spacing: 8) {
                Text(question)
                    .font(theme.fontBody)
                    .foregroundColor(theme.primaryText)
                HStack(spacing: 8) {
                    TextField("Your response...", text: $userInputText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Button("Skip") {
                        viewModel.submitClarificationResponse(operationID: request.id, response: nil)
                        executionState.removePendingInteraction(operationID: request.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Send") {
                        guard !userInputText.isEmpty else { return }
                        viewModel.submitClarificationResponse(operationID: request.id, response: userInputText)
                        executionState.removePendingInteraction(operationID: request.id)
                        userInputText = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(userInputText.isEmpty)
                }
            }

        case .toolConfirmation(let toolName, let params):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(toolName)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                }
                if !params.isEmpty && params != "{}" {
                    Text(String(params.prefix(200)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(3)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Deny") {
                        viewModel.submitToolApproval(operationID: request.id, approved: false)
                        executionState.removePendingInteraction(operationID: request.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    Button("Allow") {
                        viewModel.submitToolApproval(operationID: request.id, approved: true)
                        executionState.removePendingInteraction(operationID: request.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.green)
                }
            }
        }
    }

    // MARK: - Timeline Snippet

    private func timelineSnippetRow(event: TimelineEvent) -> some View {
        HStack(spacing: 6) {
            switch event {
            case .thought(_, let text):
                Image(systemName: "brain")
                    .font(.system(size: 8))
                    .foregroundColor(theme.tertiaryText)
                Text(String(text.prefix(60)))
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)

            case .toolExecution(let data):
                Image(systemName: data.isExecuting ? "arrow.trianglehead.2.clockwise" : (data.isSuccess == true ? "checkmark" : "xmark"))
                    .font(.system(size: 8))
                    .foregroundColor(data.isSuccess == true ? .green : (data.isSuccess == false ? .red : theme.tertiaryText))
                Text(data.name.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)

            default:
                EmptyView()
            }
            Spacer()
        }
    }

    private var nodeKindLabel: String {
        switch request.nodeKind {
        case .profile(_, let pType): return pType.rawValue
        case .condition: return "Condition"
        case .gate: return "Gate"
        case .code: return "Code"
        case .loop: return "Loop"
        case .trigger: return "Trigger"
        }
    }
}
