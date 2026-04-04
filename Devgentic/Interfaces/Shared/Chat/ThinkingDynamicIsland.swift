//
//  ThinkingDynamicIsland.swift
//  Devgentic
//
//  Created by Raj Singh on 21/02/26.
//
//  THEME: Migrated to centralized AppTheme via @Environment(\.appTheme).

import SwiftUI

// MARK: - Agent: Thinking Dynamic Island
struct ThinkingDynamicIsland: View {
    let thoughts: [AgentThought] // Using the new structured thought
    let currentHeadline: String?
    let agentState: AgentState
    let isStreaming: Bool
    @Binding var isExpanded: Bool

    @State private var gradientRotation: Double = 0
    @Environment(\.appTheme) private var theme

    /// Returns a static headline for states that shouldn't cycle (tool use, interactions, workflow, capabilities).
    /// Returns nil for generic thinking states, which triggers CyclingWordsView's animated word rotation.
    private var concreteHeadline: String? {
        switch agentState {
        case .acting(.tool(let name)):
            return "Using tool: \(name)"
        case .acting(.subtask):
            return currentHeadline // Capability: subtask progress or workflow node
        case .interaction(.permission(let tool)):
            return "Waiting for approval: \(tool)"
        case .interaction(.clarification):
            return "Asking you a question..."
        case .thinking(.planning):
            return currentHeadline // Capability: "Planned 3 subtasks"
        case .thinking(.reflecting):
            return currentHeadline // Capability: "Evaluating attempt 1..."
        default:
            // Check if the headline is a concrete status (workflow, media, delegation, etc.)
            if let headline = currentHeadline,
               headline.contains("/") || headline.contains("completed") || headline.contains("failed") ||
               headline.contains("%") || headline.contains("Delegating") || headline.contains("Subtask") ||
               headline.contains("Planned") || headline.contains("Retrying") || headline.contains("accepted") {
                return headline
            }
            return nil // Let CyclingWordsView animate
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { isExpanded.toggle() } }) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(isStreaming ? theme.streamingIndicator.opacity(0.1) : theme.secondaryText.opacity(0.1))
                            .frame(width: 24, height: 24)

                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 12))
                            .foregroundColor(isStreaming ? theme.streamingIndicator : theme.secondaryText)
                            .symbolEffect(.pulse, options: .repeating, value: isStreaming)
                    }

                    if isStreaming {
                        CyclingWordsView(
                            agentState: agentState,
                            overrideText: concreteHeadline
                        )
                    } else {
                        Text("Thought Process")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.secondaryText)

                        Text("• \(thoughts.count) steps")
                            .font(.caption)
                            .foregroundColor(theme.secondaryText.opacity(0.7))
                    }

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(
                            AngularGradient(gradient: Gradient(colors: isStreaming ? [theme.streamingIndicator, theme.accentColor, theme.streamingIndicator] : [.clear]), center: .center, angle: .degrees(gradientRotation)),
                            lineWidth: isStreaming ? 1.5 : 0.5
                        )
                        .foregroundColor(theme.primaryText.opacity(0.1))
                )
                .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .onAppear {
                if isStreaming {
                    withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                        gradientRotation = 360
                    }
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    // FIX: Iterating properly using Identifiable struct
                    ForEach(thoughts) { thought in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(theme.secondaryText.opacity(0.3)).frame(width: 4, height: 4).padding(.top, 6)
                            Text(thought.text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 12)
                .padding(.vertical, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
